# TEST-01 Docker Compose起動 設計

## 1. 目的と作業範囲

TEST-01は、Killercoda上でPhase 1の最小構成をDocker Composeから起動できることを実測する独立した試験である。対象は次だけとする。

- `db-server`と`ap-server-1`の起動およびhealth確認
- PostgreSQLの`max_connections=20`確認
- PostgreSQL postmaster起動時刻とDB container restart countの取得
- `ap-server-1`から`db-server:5432`への実TCP接続確認
- `ap-server-2`が起動していないことの確認
- 試験所有resourceの安全なcleanup

TEST-02以降の業務処理、最大12並列、障害注入、接続残留観測は対象外であり、TEST-01 runnerから呼び出さない。方式AはPhase 0で確定済みだが、本試験ではfirewall変更、`docker pause`、backend terminationを一切行わない。

正本§5Aに従い、TEST-01が実測PASSしてcommit・進捗報告されるまでTEST-02へ進まない。

## 2. 前提条件と変更前検査

実行順序は「run非依存lock取得 → TEST-01 counter gate → collision-safeな診断artifact作成 → environment preflight → Phase 0固定manifest作成 → Compose検査・変更」に一本化する。順序を入れ替えない。

environment preflightでは次を全て確認する。失敗時はCompose resourceを変更せずTEST-01をFAILとする。

1. `/etc/killercoda/host`が存在し非空である。
2. hostname、`/proc/sys/kernel/random/boot_id`、Killercoda markerのSHA-256を取得できる。
3. Docker daemonへ接続できる。
4. Docker Compose pluginまたはstandalone `docker-compose`のいずれか一方を選択できる。
5. `docker-compose.yml`を解釈でき、対象serviceが一意である。
6. Phase 0 source設定が宣言するrun identityを読み取れる。

Phase 0の完了は、source設定が指す`result.jsonl`内に同じrun ID/environment IDを持つ`test_result: PASS`、方式Aの`method_qualified: PASS`、`method_selected: PASS`が各1件あり、参照された観測・cleanup artifactが存在することで確認する。TEST-00を再実行したり、新しいPhase 0証拠を生成したりしない。Phase 0と現在sessionは異なってよく、identityの同値を要求しない。

Killercoda marker不在でも診断artifactは既に作成済みとする。そのenvironment IDは`unqualified-<hostname>-<boot-idまたはunavailable>`とし、Killercodaを示すidentityとして扱わない。

## 3. 実行単位と所有権

各実行に次を生成する。

```text
environment_id = <hostname>-<boot_id>
run_id         = <UTC timestamp>-<PID>-<collision-safe suffix>
compose_project = test01-<run-idをCompose制約内へ正規化した値>
```

固定`container_name`は使用しない。project名、Compose fileの絶対path、起動したcontainer ID、service label、network ID、volume IDを試験開始時からledgerへ記録する。cleanupはこのrunが所有すると再検証できたresourceだけを対象とし、別projectやPhase 0 artifactを操作しない。

開始時に同じproject名のresourceが既に存在する場合は衝突として変更前FAILとする。曖昧な既存resourceを自動削除して続行しない。

## 4. 1コマンド実行インターフェース

実装する利用者向け入口はリポジトリrootからの次の1コマンドとする。

```bash
sudo bash tests/test-01.sh
```

runner自身がpreflight、build、up、検証、証跡保存、cleanup、counter更新を順番に実施する。追加の手作業や環境変数設定を利用者へ要求しない。終了コード0はcleanupを含むTEST-01 PASS、非0はFAILまたは3回停止状態を表す。

標準出力には現在工程と最終結果、environment ID、run ID、artifact pathを表示する。認証情報、Killercoda marker本文、DB passwordは表示しない。

## 5. 起動手順

1. execution contextとCompose capabilityをartifactへ保存する。
2. `docker compose config`相当で構成を検証し、解釈後のservice一覧を保存する。
3. 一意なproject名でimageをbuildする。
4. `db-server`と`ap-server-1`だけをservice名で明示してdetached起動する。`ap-netadmin-1`その他は起動しない。
5. timeout付きpollingで両serviceのhealthが`healthy`になるまで待つ。
6. 下記の受入観測を行う。
7. 成否にかかわらず所有resourceをcleanupし、事後状態を検証する。
8. cleanupを含む最終結果を記録し、FAIL counterを原子的に更新する。

起動はComposeの依存関係だけを成功根拠にしない。各containerの実状態とhealthをDocker hostから観測する。固定sleepだけでhealthを推測せず、各pollの時刻と状態を残す。

## 6. 受入観測とPASS基準

### 6.1 Composeとcontainer

- buildとupが終了コード0である。
- project labelとservice labelから`db-server`、`ap-server-1`が各1 containerだけ解決される。
- 両containerが`running`かつ`healthy`である。
- `docker compose ps`と各containerの`docker inspect`を保存する。
- 解釈済みservice一覧および同じproject labelの実container一覧に`ap-server-2`が存在しない。
- 起動済みservice一覧に`ap-netadmin-1`その他の非対象serviceが存在しない。

`ap-server-2`という名前の別project containerは本試験の所有物ではないため操作しない。ただし混同防止のため検出結果を診断情報として記録する。

### 6.2 PostgreSQL設定と基準値

`db-server`内で管理接続を1本だけ使用し、次を同一の観測処理で取得する。

```sql
SHOW max_connections;
SELECT pg_postmaster_start_time();
```

PASSには`max_connections`が整数20、postmaster起動時刻が空でなくPostgreSQL timestampとして解釈可能であることを要求する。さらにDocker hostの`docker inspect`から当該DB containerの`RestartCount`を整数として取得する。TEST-01では基準値取得が目的であり、将来の再起動有無をまだ判定しない。

SQL終了コード0、raw出力、正規化値、DB container IDを保存する。healthcheck成功だけでこれらを代替しない。

### 6.3 AP health

`ap-server-1`のDocker healthが`healthy`であることに加え、container内または同じnetwork namespaceからAP readiness endpointへ要求し、HTTP 200と機械判定可能なready値を確認する。Docker health文字列だけを成功根拠にしない。

### 6.4 APからDBへのTCP接続

`ap-server-1` container内でDNS名`db-server`を解決し、`db-server:5432`へ新しいTCP socketをtimeout付きで接続して正常終了させる。実行位置、解決IP、接続先port、開始・終了時刻、終了コードを保存する。

ホストやDB containerからの接続、`pg_isready`だけではAP→DB方向の成功証拠にならない。TEST-01ではTCP到達性のみを判定し、業務SQL成功や`application_name`はTEST-02の範囲とする。

### 6.5 TEST-01最終PASS

次が全て成立した場合だけTEST-01をPASSとする。

- 現在run自身がKillercoda上で実行された。
- Compose build/up成功。
- DB/APがrunningかつhealthyで、AP readinessも成功。
- `max_connections=20`。
- postmaster起動時刻とDB restart countを取得済み。
- AP→DBの実TCP接続成功。
- TEST-01 projectに`ap-server-2`が未定義・未起動。
- cleanupと事後検証が成功。
- 必須artifactが全て存在しvalidatorを通過。

部分的な成功や静的検査だけでPASSイベントを記録しない。

## 7. 実測証跡

artifactは既存runを上書きしない。

```text
artifacts/test-01/<environment-id>/<run-id>/
├── execution-context.json
├── result.jsonl
├── ownership-ledger.tsv
├── compose-version.txt
├── compose-config.yaml
├── compose-services.txt
├── build.log
├── up.log
├── health-polls.jsonl
├── compose-ps.json
├── db-inspect.json
├── ap-inspect.json
├── postgres-settings.json
├── postgres-settings.raw
├── ap-readiness.json
├── ap-db-tcp.json
├── cleanup.log
├── cleanup-verification.json
└── summary.json
```

`execution-context.json`にはschema version、`environment="killercoda"`、environment ID、hostname、boot ID、marker path、marker SHA-256、run ID、Docker/Compose versionを持たせる。validatorは現在のmarkerとboot IDから値を再計算する。

`result.jsonl`の全行にはtimestamp、phase、`test_id="TEST-01"`、event、status、rc、environment ID、run ID、command ID、artifact path、試験開始時FAIL countを持たせる。最終行にはcleanup結果と試験終了時FAIL countを含める。summaryにはcontainer IDs、health、max_connections、postmaster起動時刻、restart count、TCP接続結果、ap-server-2数、cleanup結果を集約する。

raw command出力と正規化JSONの両方を残す。password、marker本文、環境内secretはartifactへ書かない。

### 7.1 Phase 0 source固定manifest

保護rootは、version管理されたPhase 0 source設定ファイルそのものと、その設定から解決した単一のPhase 0 source run directoryの2つだけに限定する。親の`artifacts/phase0`全体、別run、リポジトリ全体を保護rootとして走査しない。解決pathは正規化し、source run directoryからのescapeやsymlink経由のroot外参照を拒否する。

environment preflight成功後、Compose検査・変更前に、次の2種類を別artifactとして保存する。

1. **検証必須固定集合manifest**：source設定、`result.jsonl`、TEST-00 PASS判定に参照する全観測JSON、cleanup JSON、execution context、cleanup ledger、PID cleanup actionを列挙する。各entryは保護root基準のrelative path、file type、byte数、regular fileのSHA-256を持つ。必須entryの欠落、非regular file化、重複pathは変更前FAILとする。
2. **保護対象inventory**：source設定ファイルを1 entryとして記録し、source run directory以下は開始時点の全entryを再帰的に列挙する。各entryはroot識別子、rootからのrelative path、type（regular file/directory/symlink/other）、regular fileならbyte数とSHA-256を持つ。symlinkはlink文字列も記録するが追跡してroot外を読み取らない。列挙順を正規化し、inventory自身のSHA-256も保存する。

終了時は、固定集合manifestの同じ必須entryについて存在、type、byte数、SHA-256一致を再計算する。加えて、同じ2保護rootを再inventoryし、開始時inventoryとentry集合および各entryのtype、regular fileのbyte数/SHA-256、symlink文字列を比較する。追加、欠落、type変更、内容変更を全てFAILとする。終了時の再列挙で固定集合を縮小・置換してはならない。

この比較はfilesystemの実体から行い、ownership ledgerやrunnerの「書き込んでいない」という自己申告だけを成功根拠にしない。runnerとcleanupは2保護rootへ一切書き込まず、派生要約はTEST-01 run directory内だけへ生成する。

## 8. cleanupと事後検証

runnerはEXIT、INT、TERMで同一の冪等cleanupを実行する。cleanupは次の順序とする。

1. ledgerとDocker labelを照合し、対象projectを再確定する。
2. 対象projectだけにCompose `down --volumes --remove-orphans`を実行する。
3. 対象project labelを持つcontainerとnetworkが0であることを確認する。
4. ledgerに記録した匿名・named volumeが残っていないことを確認する。
5. preflightで参照したPhase 0入力artifactのSHA-256が開始前後で同一であることを確認する。他runのartifact pathへ書込みを行っていないことをownership ledgerで確認する。

cleanup対象が一意に再検証できない場合、広い名前一致や全体pruneで代替しない。`docker system prune`、全container停止、全network/volume削除は禁止する。cleanup失敗は本体検証が成功していてもTEST-01 FAILとする。

artifactはcleanup対象外である。異常終了時にも原因調査用証跡を保持する。

runnerとcleanupは`git add`、`git commit`、`git push`、index操作を含む全Git変更操作を行わない。read-onlyなstatus記録だけを許可し、既存のstaged、unstaged、untracked fileを変更・削除・取り込まない。実測PASS後のcommitはorchestratorがTEST-01で承認されたpathだけを明示指定して行う。`git add .`、`git add -A`、暗黙の全変更commitは禁止する。

## 9. FAIL counterと3回停止

TEST-01専用状態を`artifacts/test-01/failure-state.json`へ原子的に保存する。少なくとも連続FAIL数、停止状態、直近run ID、原因fingerprint、artifact path、更新時刻を持たせる。

- 実行開始時に連続FAIL数を読み、3以上または停止状態ならDocker/Compose変更前に終了する。
- 1回のrunner実行で複数の検査が失敗しても、TEST-01の連続FAILは1だけ増やす。
- preflight後のbuild失敗、up失敗、受入基準不一致、cleanup失敗、必須artifact/validator失敗はいずれもTEST-01 FAILとして数える。
- Killercoda marker不在など、変更前に現在環境が試験対象でないと判明した実行も診断artifactを残してTEST-01 FAILとして扱う。
- TEST-01がcleanupを含め完全PASSした場合だけcounterを0へ戻す。
- 3回目の連続FAILを記録した時点で停止状態とし、4回目を開始しない。
- 停止後は3回分のコマンド、期待値、実測値、原因仮説、artifact pathを添えて人間へエスカレーションする。明示承認なしにcounterを削除・書換えしない。

runnerは最初にrun非依存lockを取得し、次にcounter gateを判定する。停止中なら新run artifactを作らず、既存counter pathを表示してunlockする。実行可能な場合だけ診断artifactを作成してenvironment preflightへ進む。

各terminal pathは、可能なcleanup、Phase 0 manifest事後検査、当該runのPASSまたはFAIL counter確定を一度だけ行ってからunlockする。signalも同じfinalizerを通り、1 runでcounterを複数回増減させない。counter更新は一時ファイル、flush、同一filesystem内のatomic renameを用いる。lockは取得時からcounter確定後まで保持し、取得不能ならartifact作成や変更操作を開始しない。

## 10. tester報告

PASS時は次の実測値を簡潔に報告する。

- Killercoda environment IDとrun ID
- Docker/Compose version
- DB/APのcontainer ID、running/health状態
- `max_connections`
- `pg_postmaster_start_time()`
- DB `RestartCount`
- AP→DB TCPの解決IP、port、終了コード
- TEST-01 project内の`ap-server-2`数
- cleanup後のcontainer/network/volume残数
- artifact path
- TEST-01連続FAIL count

FAIL時は実行コマンド、期待値、実測値、失敗工程、原因仮説、修正推奨、連続FAIL数、artifact pathを報告する。修正フローはTEST-01内に限定し、TEST-02や障害注入の実装へ進まない。
