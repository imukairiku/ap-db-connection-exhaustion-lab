# Phase 0 環境能力調査・障害注入方式選定設計

## 1. 目的とゲート

Phase 0 は、実行環境で実在する PostgreSQL TCP セッションを残留させられる障害注入方式を、実測により確定するためのフェーズである。方式は事前の推測やコマンドの存在だけでは確定しない。

Phase 1 へ進む条件は、優先順位 A から E の順に試験し、最初に本書の最低ラインを満たした方式が `SELECTED` になり、後片付けと事後検証も成功することである。`SELECTED` の根拠にできるのは、実際の Killercoda session 上で採取した実測だけである。開発者の local Docker 等での試行は probe、実装デバッグ、候補の予備評価には使えるが、方式選定の根拠や TEST-00 PASS には使わない。全方式が不合格の場合、選定結果は明示的に `UNSELECTED` とし、疑似接続や sleep による代替へ移行しない。

## 2. 候補方式と優先順位

| 優先順位 | 方式 | 注入手順 | 主な必要能力 |
|---|---|---|---|
| A | 通信 DROP 後にコンテナ pause | AP・DB 間の対象 TCP 通信を双方向 DROP し、AP コンテナを pause | iptables/nft、Docker pause |
| B | 通信 DROP 後に AP プロセス SIGSTOP | 双方向 DROP 後、対象 AP プロセスへ SIGSTOP | iptables/nft、PID 特定、signal 送信 |
| C | 事前 DROP 後に AP プロセス SIGKILL | 双方向 DROP を確認してから対象 AP プロセスを SIGKILL | iptables/nft、PID 特定、signal 送信 |
| D | network namespace/veth 隔離後に AP 停止 | AP の対象通信経路を隔離してから AP を停止 | namespace/veth 操作権限 |
| E | 経路上 packet loss 後に AP 停止 | 対象フローへ `tc/netem` 等で 100% loss を設定してから AP を停止 | tc、NET_ADMIN |

DROP、loss、link 操作は AP・DB 間の対象 IP、protocol、port に限定する。既存 firewall 全消去、Docker network 全体の切断、DB 停止は禁止する。

## 3. 方式選定の状態遷移

各方式の状態は次のいずれかとし、試行履歴を上書きしない。

```text
UNTESTED
  -> CAPABILITY_FAILED   必要コマンド、権限、対象解決のいずれかが不足
  -> CAPABLE             安全な限定操作を実試行できた
CAPABLE
  -> TRIAL_FAILED        注入失敗、観測不一致、最低ライン未達、cleanup失敗
  -> QUALIFIED           最低ラインとcleanup事後検証を満たした
QUALIFIED
  -> SELECTED            優先順位が最も高い合格方式
  -> NOT_SELECTED        Killercodaで実測済みかつQUALIFIEDだが、より上位方式がSELECTED
```

方式 A から逐次評価し、`SELECTED` が確定した時点で通常の探索を終了する。未試行の下位方式は `UNTESTED` のままにし、`NOT_SELECTED` に一括変更しない。`NOT_SELECTED` は、Killercodaで実際に最低ラインまで検証して `QUALIFIED` になった方式に限り、別の上位方式を採用する際に使う。診断目的で下位方式を試す場合も、確定済み方式を暗黙に変更しない。A〜E が `CAPABILITY_FAILED` または `TRIAL_FAILED` の場合、最終状態は `UNSELECTED` であり Phase 0 は FAIL とする。

## 4. 環境能力 probe

`scripts/probe-env.sh` は次を実測し、項目ごとに PASS / FAIL / UNKNOWN と根拠を記録する。

- docker、`docker compose` の存在、version、実行可否
- pause/unpause の実試行可否
- iptables/nft の存在と、一意なコメントまたは handle を持つ限定ルールの追加・削除可否
- コンテナ capability、privileged、NET_ADMIN の有無
- 対象 AP PID の特定と SIGSTOP/SIGCONT の実試行可否
- nsenter、network namespace、veth/link 操作可否
- tc/netem の限定的な追加・削除可否
- host または DB コンテナでの `ss`、補助観測として conntrack の利用可否
- PostgreSQL 起動、psql 疎通、`pg_stat_activity` 参照可否
- Docker network、コンテナ IP、AP・DB 間の実通信経路
- hostname、kernel、Docker、Compose、PostgreSQL の各 version

コマンドが存在するだけでは `CAPABLE` にしない。隔離した試験対象への追加と削除を実行し、終了状態を検証する。probe 自体は方式を `SELECTED` にしない。

## 5. 観測と接続同一性

### 5.1 PostgreSQL 側

注入直前に `application_name = 'ap-server-1'` を条件として、少なくとも次を保存する。

- `pid`
- `client_addr`, `client_port`
- `backend_start`, `state`
- `pg_postmaster_start_time()`

### 5.2 OS 側

DB 側 namespace で `ss -ntp` を採取し、TCP 状態、local address/port、peer address/port、利用可能なら process 情報を保存する。最低ラインの対象状態は `ESTAB` であり、TIME-WAIT 等は含めない。

### 5.3 canonical 4-tuple と照合

観測 tuple は常に DB 視点の次の向きへ正規化する。

```text
(db_address, db_port, client_address, client_port)
```

- `ss` の local endpoint が DB listen port、peer endpoint が AP 側であることを確認する。
- IPv4 は標準10進表記へ、IPv6 は圧縮済み小文字表記へ正規化する。
- IPv4-mapped IPv6 (`::ffff:a.b.c.d`) は IPv4 `a.b.c.d` として扱う。
- zone index、角括弧など表示上の装飾を除去する。
- wildcard/listen socket は照合対象にしない。
- Docker NAT がある場合、PostgreSQL が観測した `client_addr/client_port` と DB namespace の `ss` peer endpoint を正とする。host 側の変換前 tuple を直接同一視せず、conntrack 等の変換対応表を artifact に残してから canonical tuple へ写像する。
- NAT 対応を一意に解決できない接続は matched に数えない。

注入前後の PostgreSQL PID 集合と canonical tuple 集合の積を求める。PASSには、**相異なる複数の backend PID** が残り、それぞれが相異なる `ESTAB` tuple と一対一に対応し、`matched_count >= 2` であることが必要である。単なる合計件数、同一PIDの重複、新規に張り直された接続、片側だけで見える接続は不合格とする。

### 5.4 観測時点

最低限 `before`、`immediate_after`、`after_5s`、`after_15s` を採取する。各時点で接続情報と同時に `ap_stop_state` を取得しなければならない。状態はホストから Docker inspect、コンテナ state、対象 PID の `/proc` または `ps` 等、障害対象プロセスに依存しない経路で実測する。

- `before`: AP コンテナと対象プロセスが RUNNING
- A: 注入後の各時点でコンテナが PAUSED
- B: 注入後の各時点で対象PIDが STOPPED
- C: 注入後の各時点で記録済み対象PIDが EXITED/ABSENT
- D/E: 設計した停止手段に応じて PAUSED、STOPPED、または EXITED/ABSENT。方式定義と試行開始前に期待値を固定する

状態の取得不能、期待値との不一致、時点欠落は方式試行を FAIL にする。単に注入コマンドの終了コードが0であることを停止証拠にしない。15秒残留は Phase 0 における障害注入能力の証明であり、Phase 5 で TCP keepalive（idle 20秒、interval 5秒、count 3）の解放を約35秒の目安で測る試験とは目的も合否条件も異なる。

## 6. PostgreSQL 無再起動の保証

試行前後の `pg_postmaster_start_time()` は同値でなければならない。不一致または取得不能なら方式試行は FAIL とする。コンテナ runtime の restart count も補助証拠として before/after を保存するが、restart count が同じことだけで無再起動を証明してはならない。

## 7. 最低ラインと方式の合否

方式試行の PASS は次のすべてを満たす場合に限る。

1. 注入操作が対象へ限定して成功した。
2. `after_15s` まで相異なる複数の注入前 backend PID が残った。
3. 同じ接続が DB 側 `ss` の `ESTAB` tuple と照合され、`matched_count >= 2` である。
4. FIN/RSTによる正常切断や新規接続への入れ替わりではない。
5. `pg_postmaster_start_time()` が before/after で同値である。
6. 全観測時点の `ap_stop_state` が方式ごとの期待状態と一致する。
7. cleanup とその事後検証が成功した。

`pg_stat_activity` のみ、`ss` のみ、デモ出力、sleep、人工的なエラーメッセージは証拠にならない。

## 8. cleanup の所有権、順序、事後検証

cleanup は障害対象コンテナ内の trap に依存させず、**ホスト主体**の制御プロセスが所有する。ホスト側スクリプトは開始時に操作対象、元状態、追加した rule handle/qdisc/link 状態、対象 container/PID を台帳へ記録し、EXIT、INT、TERM trap から冪等 cleanup を呼ぶ。

基本順序は、障害注入の逆順である。

1. pause したコンテナを unpause、または SIGSTOP した生存プロセスへ SIGCONTする。既に終了している場合は記録して続行する。
2. 対象方式が追加した tc/qdisc、link/namespace隔離を、その方式が記録した元状態へ戻す。
3. 一意な comment/handle で追加した DROP rule のみ削除する。
4. 通信回復を確認し、試験用 AP/接続を正常終了させる。
5. 猶予時間内に自然解放されなかった場合だけ、試行前に記録した backend PID のうち、再照合時点でも同じ `backend_start`、`application_name = 'ap-server-1'`、client endpoint と一致するものに限定して `pg_terminate_backend(pid)` を実行する。
6. `pg_stat_activity` と `ss` を再照合し、記録済みPIDとtupleがtimeout内に双方から消えたことを確認する。

個々の方式で注入順序が異なる場合も、実際の操作台帳を逆順に処理する。cleanup は「対象が既に無い」を成功扱いにできるが、対象外ルールや既存qdiscを変更してはならない。

`pg_terminate_backend` は cleanup の最終解放手段であり、方式C/D/Eを含め、記録していないPID、再利用されたPID、他applicationのbackendへ実行してはならない。SQLは対象一覧を再照合したトランザクション内で構築し、実行対象と結果をartifactへ残す。規定timeoutまでに両観測から消えない場合、再照合不能、terminate失敗、対象外PIDへの作用があった場合は cleanup FAIL とする。PostgreSQLコンテナまたはpostmasterの再起動をcleanup手段として使用してはならない。

事後検証では次をすべて確認する。

- 対象コンテナが paused ではなく、SIGSTOP対象が停止状態でない。
- 追加した firewall rule、qdisc、namespace/link変更が残っていない。
- Docker network と DB 疎通が回復している。
- 試験で記録した backend PID と canonical tuple が双方の観測から消えている。
- PostgreSQL の `pg_postmaster_start_time()` が試行前と同値である。
- 最終解放に使ったPIDが試行前の記録・再照合条件と一致し、timeout内にpg/ss双方から消えている。

cleanup または事後検証失敗は方式の `TRIAL_FAILED` とし、Phase 0 をPASSさせない。

### 8.1 attempt 4 の一回限り承認

既知の連続FAILが3回に達したため、`docs/attempt4-authorization.json` に記録された
人間承認と既知原因fingerprintが `docs/phase0-test-state.json` と一致する場合に限り、
attempt 4を一回だけ許可する。最初の障害注入操作前に、O_EXCL相当の原子的作成で
`artifacts/phase0/attempt4-authorization-consumed.json` を生成する。消費済みmarkerが
存在する場合、attempt 4の再利用は禁止する。attempt 4の成功・失敗後はattempt 5へ
自動進行せず、再エスカレーションを必要とする。

## 9. JSON Lines ログ契約

人間向け要約とは別に機械判定可能な JSONL を保存する。全レコードに次のフィールドを必須とする。

- `ts`, `phase`, `test_id`, `event`, `status`, `rc`
- `environment`, `environment_id`, `hostname`, `kernel`
- `docker_version`, `compose_version`
- `attempt`, `command_id`, `artifact_path`

方式試行には `method`, `method_state`, `point`, `reason`, `ap_stop_state`, `ap_stop_state_expected`, `ap_stop_state_source` を追加する。接続観測には `pg_backend_pids`, `canonical_tuples`, `matched_pids`, `matched_tuples`, `matched_count`, `pg_postmaster_start_time` を追加する。各必須観測時点に `ap_stop_state` の証拠レコードがない場合、ログとして不完全でありPASSにしない。コマンドstdout/stderrは `artifact_path` の別artifactに保存し、DB password等の秘密情報は記録しない。

`environment_id` は同じ環境での一連の試行を相関できる不変ID、`attempt` は同一TEST-IDの試行番号、`command_id` はコマンドと結果を一意に結び付けるIDとする。

## 10. 成果物と Phase 0 報告

実装時の版管理対象は次を想定する。

- `scripts/probe-env.sh`: 能力調査
- `scripts/check-connections.sh`: pg/ss snapshot、正規化、相互照合
- 方式別の注入・cleanup処理
- TEST-00 自動判定
- 本設計書
- README の前提、実行方法、安全上の注意、復旧、ログの見方
- `config/selected-method.json`: 後続Phaseが参照する選定方式の単一設定点

`config/selected-method.json` のschemaは次とする。

`config/selected-method.json` を更新するすべてのプロセスは、run に依存しない
`config/.selected-method.lock` を `flock` で取得し、backup、commit、必須イベント
確定、rollback の全期間にわたり同じプロセスで保持する。`flock` が利用不能、
または lock を取得不能なら capability FAIL とする。新configのidentity・証拠pathと
必須イベント、counter resetを検証した後は、rollbackを先に解除して新configを正とする。
その後の旧backup削除失敗はwarning artifactへ記録し、検証済み新configをrollbackしない。

```json
{
  "schema_version": 1,
  "environment": "killercoda",
  "environment_id": "<session correlation id>",
  "method": "A",
  "selected_at": "<RFC 3339 timestamp>",
  "test_id": "TEST-00",
  "attempt": 1,
  "evidence_artifact": "artifacts/phase0/<environment-id>/result.jsonl",
  "matched_count": 2,
  "pg_postmaster_start_time": "<timestamp>"
}
```

このファイルは Killercoda session の方式が `QUALIFIED` となり、cleanup事後検証まで成功して `SELECTED` へ遷移する時だけ、検証済み結果から原子的に生成する。local実測、probe結果、途中状態、FAIL、`UNSELECTED` では生成または更新しない。既存ファイルがある状態で再試験に失敗した場合は、それを新しい選定結果として使わず、環境ID不一致として後続Phaseを停止する。後続Phaseは方式名をハードコードせず、このファイルのschema、`environment == "killercoda"`、environment ID、evidenceの存在を検証してから利用する。

実行artifactには能力調査、各方式の状態遷移、before/after観測、コマンド出力、cleanup台帳と事後検証を含める。Phase 0 報告には、確定方式と根拠、却下方式と理由、相異なるPID・tupleの対応、`matched_count`、postmaster時刻、残課題を記載する。

## 11. TEST-00 判定

TEST-00 は、環境調査が完了し、選定方式が最低ラインを満たし、ログ契約を満たす証拠が保存され、cleanup事後検証が成功した場合のみ PASS とする。同一 TEST-ID が連続3回 FAILした場合は自律修正ループを停止し、試行履歴と実測ログを添えて指示書のエスカレーション条件に従う。
