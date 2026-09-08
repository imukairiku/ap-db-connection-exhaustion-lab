# AP信頼性試験 DB接続枯渇演習 ─ AIエージェント自律開発 指示書 v2

> **正本（Single Source of Truth）**
> 今後の開発ルールは本ファイルを正本とする。新しいCodexセッションは作業開始時に本ファイルを読み、リポジトリの進捗・未コミット変更・実測証跡を確認して、完了済み工程を繰り返さず未完了工程から再開する。

> **v2改訂の要点**
> Killercoda上で「docker pause＋通信DROP」が動作するかは未確定である。
> 本指示書は特定の障害注入方式が動く前提を置かず、エージェントが最初に環境能力を実測し、
> 使える方式を優先順位に沿って自律選択する構造とする。
> 「実TCP/セッション残留での再現」を最優先の理想としつつ、環境制約に当たった場合の
> 後退順序を明示することで、FAILループとサイレントな要件逸脱を防ぐ。

---

## 1. プロジェクトの目的

AP信頼性試験における「AP切替後のDB接続枯渇」を題材とした、第三者がブラウザ上で実施できる
トラブルシューティング演習を開発する。

```text
GitHub → Killercoda → 受講者がScenario開始 → 演習環境が自動構築
→ AP障害 → AP切替 → DB接続枯渇 → 原因調査 → 暫定復旧 → 恒久対策 → 再試験
```

演習教材の完成に加え、「AIエージェントが設計・レビュー・実装・テスト・教材作成まで
自律的に行う開発プロセス」の実践も目的とする。

---

## 2. 最重要方針：人間はコーディングを行わない

人間に以下を要求してはならない。

- Python / Shell / Dockerfile / docker-compose.yml / SQL / Killercoda設定 / CI の修正
- エラー解消のためのコード変更、テストコードの作成

実装上の問題は、同一Codexエージェントが `tester視点 → 原因分析 → reviewer視点 → implementer視点
→ 再実装 → tester視点` と役割を順番に切り替えて解決する。ただし §15 のエスカレーション条件に
該当する場合のみ人間へ戻す。

---

## 3. 人間の役割

- 要件の提示 / 成果物の確認 / 演習の妥当性判断 / 各Phaseの最終確認 / 方向性の修正
- **§15 に定義されたエスカレーション事項の判断**

人間がレビューする観点：

- AP信頼性試験として現実的か
- トラブルシューティング教材として有用か
- 受講者に答えを教えすぎていないか
- 原因調査の流れに論理的飛躍がないか

---

## 4. 単一エージェント運用

```text
Codex（単一エージェント）
  designer視点 → reviewer視点 → implementer視点 → tester視点
  技術環境完成後は必要なTEST-IDでscenario-writer視点を使用
```

- `designer`、`reviewer`、`implementer`、`tester`、`scenario-writer`は別エージェントではなく、同一Codexエージェント内の役割・観点である。
- サブエージェントを生成しない。並列エージェントを起動しない。エージェント間メッセージの受け渡しを行わない。
- 役割を変更するときは、対象TEST-IDに必要な成果物、判定、未解決事項だけを内部整理し、不要な過去ログ全文を読み直さない。
- `docs/development-progress.md`をセッション間のチェックポイントとして使用し、完了済みTEST-IDやPhaseを再実行しない。

---

## 5. 単一エージェント内の役割と入出力

同一Codexエージェントは、対象TEST-IDごとに以下の役割を順番に担当する。役割ごとの責務と
**通常フロー**／**修正フロー**の入出力を混同しないこと。

### 開発管理
Phase管理／対象TEST-IDの限定／役割の順次切替／FAIL差し戻し／要件逸脱防止／進捗管理／報告を行う。
**§15のエスカレーション条件を監視し、該当時のみ人間へ上げる責任を持つ。**

### designer視点
要件から技術設計を作成する。設計対象：Docker構成／AP構成／PostgreSQL構成／DB接続方式／
**障害注入方式（§8の方式リストから環境能力に応じて選択）**／AP切替方式／接続残留の再現方式／
接続枯渇条件／暫定復旧方式／TCP Keepalive／AP側タイムアウト／接続数設計／Killercoda構成／verify方式。

- 推測で設計を確定してはならない。**Phase 0 の環境探査結果に基づいて方式を選ぶ。**
- 「その障害をこの環境で本当に再現できるか」を、環境探査の実測値で裏づけること。

### reviewer視点
- **通常フロー入力**：designerの設計、implementerの実装
- **修正フロー入力**：testerのFAILレポート＋implementerの修正案
- **出力**：PASS / FAIL（FAILは理由と修正内容を具体的に。重大／中／軽微で分類）
- 重大または中の指摘が残る場合はPASSにしてはならない。
- 観点：技術的成立性／要件漏れ／障害再現性／過度な複雑さ／演習目的整合／安全なreset／第三者再現性。

### implementer視点
- **通常フロー入力**：PASS済みの設計
- **修正フロー入力**：testerのFAILレポート＋reviewer承認済みの修正方針
- **出力**：実行可能な状態の資材一式（人間のコード修正を前提としない）。
- 対象例：Dockerfile／docker-compose.yml／Python疑似AP／SQL／Shell／healthcheck／
  障害注入script／reset script／確認script／Killercoda Scenario／verify.sh／README。

### tester視点
- 実際に成果物を実行して確認する。「コードを見て動きそう」は禁止。
- **出力（FAIL時）**：実行コマンド／期待値／実測値／原因／修正推奨／**当該TEST-IDの連続FAIL回数**。
- FAIL時は同一エージェントがimplementer視点（設計起因ならdesigner視点）へ戻る。

### scenario-writer視点
技術環境完成後にKillercoda教材を作成：問題文／手順／ヒント／解説／verify条件／まとめ。
受講者に最初から原因を教えない。特に **旧AP接続残留／max_connections枯渇／Keepalive設定**
を初期問題文に書かない。

---

## 5A. TEST-ID単位の作業・停止ルール

- 1回の作業では、原則として1つのTEST-IDだけを扱う。複数のTEST-IDを一気に進めない。
- TEST-IDごとに、同一エージェントが `designer視点 → reviewer視点 → implementer視点 → tester視点` の工程を順番に完了させる。
- tester視点で実測PASSを確認したら、そのTEST-IDの成果物と進捗記録をcommitする。
- commit後は変更内容、実測結果、commit hashを人間へ簡潔に報告し、作業を停止する。
- 人間が「続けて」と明示するまで、次のTEST-IDへ進まない。
- FAIL時の原因分析、設計修正、レビュー、実装修正、再試験は、当該TEST-IDの範囲内で行う。
- 現在のTEST-IDに不要な将来Phaseまたは後続TEST-IDの機能を先回りして設計・実装しない。
- 各TEST完了時に、新しいCodexセッションが次の未完了TEST-IDから再開できるよう、`docs/development-progress.md`へ進捗を記録する。
- この節は、複数TEST-IDをまとめて進める旨を記した他の箇所より優先する。

進捗記録には最低限、次を含める。

```text
現在のPhase：
完了済みTEST-ID：
次のTEST-ID：
採用済み技術方式：
重要な実測結果：
未解決課題：
最新commit：
```

---

## 6. Phase 0（新設）：環境能力の探査と方式確定

**Phase 1に進む前に必ず実施する。** Killercoda上で何が使えるかをエージェント自身が実測する。

### 探査項目（tester視点で実行し、結果をログ化）
```text
・docker / docker compose が使えるか
・docker pause が使えるか
・iptables / nftables でのDROPが使えるか（要特権・NET_ADMIN）
・コンテナ内プロセスへのSIGSTOP等シグナル送出が可能か
・ss / conntrack が使えるか
・PostgreSQLコンテナを起動しpg_stat_activityを観測できるか
・特権コンテナ / --cap-add が許可されるか
```

### 出力
designer視点で「使える障害注入方式」を **§8の優先順位リストから確定** し、その根拠（実測値）を
Phase 0報告に記載する。**ここで方式が確定するまでPhase 1へ進まない。**

---

## 7. 演習環境（論理構成）

```text
Dockerホスト
├── ap-server-1：現用系AP
├── ap-server-2：待機系AP
└── db-server：PostgreSQL（max_connections = 20）
```

障害時の期待挙動：
```text
ap-server-1障害 → ap-server-2へ切替 → 旧APのDB接続が残留
→ 新APの接続と競合 → max_connections到達 → 業務失敗
```

---

## 8. 障害注入要件（方式を固定せず優先順位で選ぶ）

**理想（最優先）**：障害発生時点で処理中だったDB接続を、正常切断通知（FIN/RST）を
DBへ届けないまま残留させ、実TCP/実PostgreSQLセッションとして残す。

### 障害注入方式 ─ 優先順位つき許容リスト
designer視点では Phase 0 の探査結果に基づき、**動作が確認できた最上位の方式**を採用する。

```text
方式A（第一候補）：通信DROP（iptables/nft）→ その後 docker pause
  目的：FIN/RSTを届けず、DB側TCP/セッションを残留

方式B：通信DROP → コンテナ内APプロセスへSIGSTOP
  pauseが不可でもシグナルで停止できる場合

方式C：APプロセスをSIGKILL/強制停止しつつ、事前にsocketをDROPして
  FIN到達を阻止（切断通知を出させない停止のさせ方）

方式D：ネットワーク名前空間分離 / veth linkのdownで通信断を作り、
  APコンテナを停止

方式E（最終後退）：DB-AP間の経路上でパケットを落とす別手段
  （tc/netem等）＋AP停止
```

### 実再現の最低ライン（これを割ってはならない）
どの方式を採っても、**PostgreSQL側 `pg_stat_activity` とOS側 `ss` の両方に、
停止済みAP由来の接続が実体として残る**ことを満たすこと。
単なるダミー行やsleepでの疑似再現は §16 の禁止事項に該当する。

### 方式リストで再現できない場合
方式A〜Eをすべて試して最低ラインを満たせない場合に限り、**§15のエスカレーション**
（技術方式の根本変更）として人間へ報告する。勝手に疑似再現へ落とさない。

---

## 9. 疑似AP要件

- Python等で実装。**原則、業務処理ごとにDB接続**（プール12本常時保持はしない）。
  理由：障害時に「処理中だった接続だけが残る」状態を再現しやすくするため。
- 最大同時業務数：12。処理時間を混在（短1秒／通常3秒／長10秒）。
- 各リクエストに一意な `request_id`。開始／COMMIT／ROLLBACK／成功／失敗を追跡可能に。

---

## 10. Phase構成

> **各Phaseは「Phase 0で確定した方式」を用いる。** 方式名を各Phaseにハードコードしない。

### Phase 0：環境探査（§6）
使える障害注入方式を確定。**PASSまで先へ進まない。**

### Phase 1：DB接続残留MVP
`ap-server-1 → PostgreSQL` のみで、障害後もDB接続が実体として残る状態を再現。
PASS条件：Docker起動／複数接続／障害注入／ap-server-1停止／
`pg_stat_activity` と `ss` の双方にap-server-1接続が複数残留。

### Phase 2：DB接続枯渇
ap-server-2を追加。旧AP残留8〜12／新AP要求最大12／管理系1〜2／max_connections=20。
PASS条件：ap-server-2が接続開始／上限到達／DB接続エラー／切替後業務が失敗。

### Phase 3：AP自動切替
ap-server-1障害を検知しap-server-2をACTIVE化。HA製品は不要、healthcheck＋監視scriptで可。
**切替完了の宣言方法と、それをverifyがどう検知するかのインターフェースを設計に明記する**
（例：共有フラグ、特定プロセスの生死、特定ファイル/エンドポイントの状態）。後続Phaseがこれに依存する。

### Phase 4：暫定復旧
受講者が残留接続を特定し、旧AP由来のみ終了。
```sql
SELECT pg_terminate_backend(pid)
FROM pg_stat_activity
WHERE application_name = 'ap-server-1' AND pid <> pg_backend_pid();
```
PASS条件：旧AP接続0／新AP接続成功／業務回復／**PostgreSQL再起動なし**（判定は §12）。

### Phase 5：恒久対策
TCP Keepalive（idle=20／interval=5／count=3、目安約35秒。**実測値を確認**）。
AP側 connect_timeout=5秒、失敗時バックオフ（1→2→4秒）。

### Phase 6：接続数設計比較
Case A：max_connections=20（旧AP解放まで一時的な接続失敗あり）／
Case B：max_connections=30（旧AP残留中も新AP接続可能）。
Keepaliveだけでは瞬間的枯渇を防げないことを確認。

### Phase 7：Killercoda化
GitHub資材からScenarioを構築。受講者は環境構築しない。
URLを開く→Start Scenario→調査開始 だけで実施可能に。

---

## 11. Killercoda受講者向け構成（7Step）

```text
Step1 AP切替状況確認 / Step2 切替後の業務障害確認 / Step3 DB接続エラー切り分け
Step4 残留接続特定 / Step5 暫定復旧 / Step6 恒久対策 / Step7 再試験
```
環境構築・疑似AP作成は受講者に実施させない。

---

## 12. verifyの考え方（判定基準を具体化）

「コマンドを打ったか」ではなく「システムが期待状態になったか」を判定する。

### 誤復旧（DB全体再起動での逃げ）を弾く判定基準
```sql
-- postmaster起動時刻がScenario開始時刻から変化していないことを確認
SELECT pg_postmaster_start_time();
```
Scenario開始時に起動時刻（またはコンテナ起動時刻）を記録し、Step5 verifyで
**起動時刻が変化＝再起動された場合はFAIL**とする。加えてコンテナの再作成/再起動回数も併用可。

### 各Stepのverify期待状態（例）
```text
Step1 ap-server-2がACTIVE（Phase3で定義したインターフェースで判定）
Step4 原因調査に必要な状態が存在（旧AP接続が観測可能）
Step5 ap-server-1由来接続=0 / postmaster起動時刻が不変 / ap-server-2業務成功
Step7 旧AP接続が自動解放 / 新AP業務成功
```

---

## 13. tester視点での必須試験

```text
TEST-00 環境探査：使える障害注入方式の確定（Phase0）
TEST-01 docker compose起動
TEST-02 正常時にap-server-1業務成功
TEST-03 最大12並列処理
TEST-04 障害注入時に複数接続が処理中
TEST-05 障害注入後に旧接続がpg_stat_activityとssの双方に残留
TEST-06 ap-server-2へ切替（Phase3インターフェースで検知）
TEST-07 max_connections=20で接続枯渇
TEST-08 APログにDB接続エラー
TEST-09 pg_stat_activityから旧AP特定
TEST-10 pg_terminate_backendで復旧
TEST-11 PostgreSQL再起動なしで復旧（postmaster起動時刻不変で確認）
TEST-12 Keepalive後に旧接続自動解放（解放までの実測秒数を記録）
TEST-13 AP自動再接続
TEST-14 max_connections=20 比較試験
TEST-15 max_connections=30 比較試験
TEST-16 reset後に再度同じ障害を再現
TEST-17 Killercoda verify正常判定
TEST-18 誤った復旧方法（DB全体再起動）をPASSさせない
```

---

## 14. 再現性のルール

禁止表現：「おそらく残る」「理論上再現できる」「コードを見る限り問題ない」。必ず実測。
ログとして残す：障害前接続数／障害直後接続数／旧AP接続数／新AP接続数／
Keepalive解放時間／接続失敗数／業務成功・失敗数。

---

## 15. 自律修正ルールとエスカレーション（停止条件を明記）

FAIL検出時は即座に人間へ質問しない。同一エージェント内で原則 `tester視点 → 原因分析
→ reviewer視点 → implementer視点 → 再実装 → tester視点` と切り替える。必要ならdesigner視点まで戻る。

### FAILループの停止条件（新設）
- **同一TEST-IDが3回連続でFAILした場合**、原因仮説・試行履歴・実測ログを添えて
  同一Codexエージェントが開発管理の責務として人間へエスカレーションする。無限リトライを禁止する。
- 異なるTEST-IDのFAILは各々独立にカウントする。

### 人間へのエスカレーションが必要な場合
```text
・要件そのものの変更が必要
・技術方式の根本変更が必要（§8の方式A〜Eすべてで最低ラインを満たせない等）
・複数案があり学習目的に影響する
・同一TEST-IDが3回連続FAIL
```

---

## 16. 勝手な要件変更の禁止（例外の入口を明記）

実装を簡単にするために以下を勝手に行ってはならない。

```text
・DB接続残留を単なるダミーデータで表現
・接続枯渇を人工的なエラーメッセージだけで表現
・実際にはDB接続していない
・旧AP接続が残っていないのに残ったことにする
・Keepaliveをsleepだけで疑似再現
```

可能な限り実際のLinux TCP / PostgreSQLセッションとして再現する。

**唯一の例外**：§8の方式A〜Eをすべて実測し、いずれでも「実接続残留の最低ライン」を
満たせないことがログで示された場合に限り、§15のエスカレーションとして人間へ判断を仰ぐ。
人間の承認なしに疑似再現へ後退してはならない。

---

## 17. GitHubリポジトリ想定

```text
db-connection-exhaustion-lab/
├── README.md
├── docker-compose.yml
├── ap/            (Dockerfile, app.py)
├── db/            (Dockerfile, init.sql)
├── monitor/       (failover.sh)
├── scripts/       (setup.sh, inject-failure.sh, restore-network.sh,
│                   check-connections.sh, reset-lab.sh, probe-env.sh ←環境探査)
├── tests/
└── killercoda/db-connection-exhaustion/
    ├── index.json, intro.md, step1..7.md, verify/, finish.md
```
最終構成は実際のKillercoda仕様に合わせてdesigner視点で調整する。

---

## 18. 各Phase終了時の報告形式

```text
Phase X：PASS / FAIL
実装内容：-
テスト結果：-
確認できた事実（実測値）：-
残課題：-
次Phase：-
```
（Phase 0報告には「確定した障害注入方式とその根拠」を必ず含める）
大量の内部ログやコード全文を毎回人間に見せる必要はない。

---

## 19. 最終Definition of Done

```text
□ GitHubで演習資材を管理できる
□ KillercodaからScenarioを開始できる
□ Scenario開始時に環境が自動構築される
□ ap-server-1で正常業務が動作する
□ 障害注入を再現できる（Phase0で確定した方式で）
□ ap-server-1のDB接続が実際に残留する（pg_stat_activity＋ssの双方で確認）
□ ap-server-2へ自動切替する
□ max_connections=20でDB接続枯渇を再現できる
□ APログからDB接続失敗を確認できる
□ pg_stat_activityから原因を調査できる
□ 旧AP接続のみterminateできる
□ PostgreSQL再起動なしで業務復旧できる（postmaster起動時刻不変で確認）
□ Keepaliveで旧接続が自動解放される（解放秒数を実測記録）
□ APが自動再接続する
□ max_connections=20と30を比較できる
□ request_idから業務整合性を確認できる
□ resetして何度でも再試験できる
□ verifyで正誤判定できる（誤復旧をFAILにできる）
□ 第三者が説明なしで演習できる
□ gitコミットの著者がすべてエージェントである（人間のコード修正が履歴上ゼロ）
```

> 旧版の「人間がコードを一度も修正していない」は自己申告で検証不能だったため、
> gitコミット著者という観測可能な形に置き換えた。

---

## 20. 開発開始指示

**まず Phase 0（環境探査）から開始する。** Killercoda上で使える障害注入方式を
エージェント自身が実測し、designer視点で§8の優先順位に沿って方式を確定する。

進め方：同一エージェントが
`環境探査(tester視点) → 方式確定(designer視点) → reviewer視点 → implementer視点 → tester視点`
の順に担当する。

Phase 0がPASSしたら結果（確定方式と根拠）を人間へ報告。
その後 Phase 1 へ進み、tester視点で `pg_stat_activity` と `ss` の双方で残留接続を
確認するまでPhase 1を終了しない。

人間から明示的停止指示がない限り、同じ品質基準でPhase 2以降を順次進める。
§15のエスカレーション条件に該当する場合のみ人間へ戻す。コード修正を人間へ依頼しない。

最終目標：「GitHubとKillercodaを連携し、第三者がAP信頼性試験におけるDB接続枯渇トラブルを
自力で調査・復旧できる教材」を完成させること。
