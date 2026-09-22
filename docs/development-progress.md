# 開発進捗チェックポイント

更新日: 2026-09-23

現在のPhase：Phase 7（Killercoda化、TEST-16〜18実測PASS）

完了済みTEST-ID：

- TEST-00：PASS（Phase 0環境探査）
- TEST-01：PASS（Docker Compose起動）
- TEST-02：PASS（正常時にap-server-1業務成功）
- TEST-03：PASS（最大12並列処理）
- TEST-04：PASS（障害注入時に複数接続が処理中）
- TEST-05：PASS（障害注入後に旧接続がpg_stat_activityとssの双方に残留）
- TEST-06：PASS（max_connections=20でDB接続枯渇）
- TEST-07：PASS（APログにDB接続エラー）
- TEST-08：PASS（ap-server-2へ自動切替）
- TEST-09：PASS（pg_stat_activityから旧AP由来の残留接続を特定）
- TEST-10：PASS（旧AP由来の接続だけを終了し業務復旧）
- TEST-11：PASS（PostgreSQL再起動なしで復旧）
- TEST-12：PASS（Keepaliveによる旧AP接続の自動解放）
- TEST-13：PASS（APの自動再接続と業務復旧）
- TEST-14：PASS（max_connections=20の容量測定）
- TEST-15：PASS（max_connections=30の容量測定と比較）
- TEST-16：PASS（reset後に正常化し、方式Aの障害を再現）
- TEST-17：PASS（対象を限定した復旧をverifyが正しく受理）
- TEST-18：PASS（DB再起動による誤復旧をverifyが拒否）

次のTEST-ID：なし（TEST-00〜18すべて実測PASS）

採用済み技術方式：方式A「対象通信DROP → docker pause」

## 重要な実測結果

- TEST-00 attempt 4：Killercoda実環境で方式Aを確認。障害注入後の
  `immediate_after`、`after_5s`、`after_15s`で対象接続が各3件残留し、AP状態は`PAUSED`。
- TEST-01：Killercoda実環境でPASS。
  - environment ID：`ubuntu-81356df3-62ce-41aa-904b-1a5bfcbe032d`
  - run ID：`20260908T165104-2137-e89aab53`
  - 連続FAIL数：`0`（直前のFAIL 1回後にPASSしてリセット）
  - evidence：`artifacts/test-01/ubuntu-81356df3-62ce-41aa-904b-1a5bfcbe032d/20260908T165104-2137-e89aab53`
- TEST-02：Killercoda実環境で正常業務1件がPASS。
  - environment ID：`ubuntu-81356df3-62ce-41aa-904b-1a5bfcbe032d`
  - run ID：`20260908T170034-3580-b3c70bad`
  - request ID：`test02-20260908T170034-3580-b3c70bad`
  - 連続FAIL数：`0`
  - evidence：`artifacts/test-02/ubuntu-81356df3-62ce-41aa-904b-1a5bfcbe032d/20260908T170034-3580-b3c70bad`
- TEST-03：Killercoda実環境で最大12並列処理がPASS。
  - environment ID：`ubuntu-81356df3-62ce-41aa-904b-1a5bfcbe032d`
  - run ID：`20260908T170934-4908-0b22ca59`
  - AP同時処理数：`12`
  - PostgreSQL同時接続数：`12`
  - COMMIT成功数：`12`
  - 13件目：HTTP `429`で拒否
  - 連続FAIL数：`0`
  - evidence：`artifacts/test-03/ubuntu-81356df3-62ce-41aa-904b-1a5bfcbe032d/20260908T170934-4908-0b22ca59`
- TEST-04：Killercoda実環境で方式Aによる障害注入時の処理中接続を確認してPASS。
  - environment ID：`ubuntu-e19b44ed-787c-401b-abad-b22bf74ae6d4`
  - run ID：`20260908T172127-1740-24625c12`
  - 注入時処理中接続：AP `12`、PostgreSQL `12`、`ss` `12`、相関済み `12`
  - 障害注入：対象flowのDROP rule `2`本を確認後、AP状態`PAUSED`
  - DB状態：稼働継続、postmaster起動時刻不変
  - 連続FAIL数：`0`
  - evidence：`artifacts/test-04/ubuntu-e19b44ed-787c-401b-abad-b22bf74ae6d4/20260908T172127-1740-24625c12`
- TEST-05：Killercoda実環境で方式Aによる旧接続残留と安全なcleanupを確認してPASS。
  - environment ID：`ubuntu-b2e446fa-055c-4866-997d-ce0d3f8d9200`
  - run ID：`20260908T173314-1722-19fb173f`
  - 相関済み残留接続：注入直後 `12`、5秒後 `12`、15秒後 `12`
  - 観測元：`pg_stat_activity`とDB側`ss`の双方
  - PostgreSQL：postmaster起動時刻不変
  - cleanup後：対象`pg_stat_activity` `0`、対象`ss` `0`
  - 連続FAIL数：`0`
  - evidence：`artifacts/test-05/ubuntu-b2e446fa-055c-4866-997d-ce0d3f8d9200/20260908T173314-1722-19fb173f`
- TEST-06：Killercoda実環境でPostgreSQL自身の接続上限による拒否を確認してPASS。
  - environment ID：`ubuntu-c996a738-ea98-49e2-941c-7b41f8b4a95a`
  - run ID：`20260912T180934-4856-8d9b88dc`
  - `max_connections=20`、旧AP残留 `10`、新AP接続 `5`、新AP接続失敗 `7`、管理接続 `2`
  - 観測時client backend `18`（収束後の値であり、瞬間ピーク値ではない）
  - PostgreSQLログに実FATAL、postmaster起動時刻不変
  - 連続FAIL数：`0`（前回FAIL 1回後にPASSしてリセット）
  - evidence：`artifacts/test-06/ubuntu-c996a738-ea98-49e2-941c-7b41f8b4a95a/20260912T180934-4856-8d9b88dc`
- TEST-07：Killercoda実環境で新APの実DB接続失敗をAPログとDBログの双方で確認してPASS。
  - environment ID：`ubuntu-08de0985-c51c-4db7-9144-cbaa93c666b4`
  - run ID：`20260912T181944-1923-aedd50ee`
  - 新AP接続失敗 `7`件、同一request_idのAPエラーログ `7`件
  - PostgreSQLログに実FATAL、postmaster起動時刻不変
  - 連続FAIL数：`0`
  - evidence：`artifacts/test-07/ubuntu-08de0985-c51c-4db7-9144-cbaa93c666b4/20260912T181944-1923-aedd50ee`
- TEST-08：Killercoda実環境で監視によるap-server-2への自動切替を確認してPASS。
  - environment ID：`ubuntu-08de0985-c51c-4db7-9144-cbaa93c666b4`
  - run ID：`20260912T183239-7551-d0c6077d`
  - 検知主体：`monitor`、ACTIVE：`ap-server-2`
  - 切替完了インターフェース：`artifacts/phase3/current.json`
  - ap-server-1はPAUSED、ap-server-2はhealthy、postmaster起動時刻不変
  - 連続FAIL数：`0`
  - evidence：`artifacts/test-08/ubuntu-08de0985-c51c-4db7-9144-cbaa93c666b4/20260912T183239-7551-d0c6077d`
- TEST-09：Killercoda実環境で旧AP由来の残留接続を`pg_stat_activity`から識別してPASS。
  - environment ID：`ubuntu-08de0985-c51c-4db7-9144-cbaa93c666b4`
  - run ID：`20260912T184128-10202-5c3e8a3f`
  - 旧AP接続 `3`本、新AP接続 `3`本、管理接続 `2`本
  - ACTIVE：`ap-server-2`、postmaster起動時刻不変
  - 連続FAIL数：`0`
  - evidence：`artifacts/test-09/ubuntu-08de0985-c51c-4db7-9144-cbaa93c666b4/20260912T184128-10202-5c3e8a3f`
- TEST-10：Killercoda実環境で対象旧AP接続のみを終了し、新AP業務COMMITを確認してPASS。
  - environment ID：`ubuntu-f35abd1b-24c4-4b33-9ba8-3a3dce614e92`
  - run ID：`20260912T185610-1921-ad3ce5da`
  - 旧AP接続：復旧前 `10`本、復旧後 `0`本
  - 新AP・管理接続のPIDは維持、新AP業務COMMIT成功
  - 連続FAIL数：`0`
  - evidence：`artifacts/test-10/ubuntu-f35abd1b-24c4-4b33-9ba8-3a3dce614e92/20260912T185610-1921-ad3ce5da`
- TEST-11：同じKillercoda実測runのDB継続性を独立判定してPASS。
  - `pg_postmaster_start_time()`不変、DBコンテナID不変、restart count不変
  - 新AP業務COMMIT成功、連続FAIL数：`0`
  - evidence：`artifacts/test-10/ubuntu-f35abd1b-24c4-4b33-9ba8-3a3dce614e92/20260912T185610-1921-ad3ce5da`
- TEST-12：Killercoda実環境で方式Aの障害後、Keepaliveによる旧AP接続の自動解放を確認してPASS。
  - environment ID：`ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569`
  - run ID：`20260913T135135-6380-3ce0e16d`
  - 実効Keepalive：idle `20`秒／interval `5`秒／count `3`
  - 旧AP接続：障害直後 `3`本、自動解放後 `0`本。`pg_stat_activity`と`ss`の双方で消滅を確認
  - 解放までの実測時間：`35.664`秒。postmaster起動時刻不変、連続FAIL数：`0`
  - evidence：`artifacts/test-12/ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569/20260913T135135-6380-3ce0e16d`
- TEST-13：Killercoda実環境で余計なTracebackなしに再実測PASS。
  - environment ID：`ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569`
  - run ID：`20260913T135718-12940-9878fb1d`
  - `connect_timeout=5`秒、backoff `1→2→4`秒、復旧前の接続失敗 `3`回
  - AP・DBとも再起動なし。AP自動再接続後、業務COMMIT成功。連続FAIL数：`0`
  - evidence：`artifacts/test-13/ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569/20260913T135718-12940-9878fb1d`
- TEST-14：Killercoda実環境で`max_connections=20`時の実接続枯渇を測定してPASS。
  - environment ID：`ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569`
  - run ID：`20260913T140641-15502-5a7675fa`
  - 旧AP残留 `10`本、新AP成功 `5`本／失敗 `7`本、管理 `2`本
  - 最終接続 `17`本、非予約枠の接続余力 `0`本、postmaster起動時刻不変、連続FAIL数 `0`
  - evidence：`artifacts/test-14/ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569/20260913T140641-15502-5a7675fa`
- TEST-15：同一Killercoda環境・同一負荷条件で`max_connections=30`を測定してPASS。
  - environment ID：`ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569`
  - run ID：`20260913T140712-18061-8b6aa06d`
  - 旧AP残留 `10`本、新AP成功 `12`本／失敗 `0`本、管理 `2`本
  - 最終接続 `24`本、非予約枠の接続余力 `3`本、postmaster起動時刻不変、連続FAIL数 `0`
  - evidence：`artifacts/test-15/ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569/20260913T140712-18061-8b6aa06d`

## Phase 1判定

Phase 1：**PASS**。TEST-01〜05がすべてKillercoda実測PASSし、方式Aによる障害後15秒時点の
実PostgreSQL session/TCP接続12本の残留、PostgreSQL再起動なし、cleanup後の対象接続0を確認した。

## Phase 2判定

Phase 2：**PASS**。TEST-06〜07がKillercoda実環境でPASSし、`max_connections=20`下で
旧AP残留10本、新AP接続失敗7件、PostgreSQL実FATALとAP側の対応エラーログ7件を確認した。
PostgreSQL再起動はなかった。AP切替は明示操作であり、自動切替はPhase 3の対象とする。

## Phase 3判定

Phase 3：**PASS**。TEST-08がKillercoda実環境でPASSし、方式Aによる障害を監視機能が検知して
ap-server-2を自動的にACTIVE化した。`artifacts/phase3/current.json`で切替完了を判定し、
ap-server-1のPAUSED、ap-server-2のhealthy、postmaster起動時刻不変を確認した。

## Phase 4判定

Phase 4：**PASS**。TEST-09〜11がKillercoda実環境でPASSし、旧AP接続10本のみを終了して0本にし、
新AP・管理接続を維持したまま新AP業務COMMITに成功した。postmaster起動時刻、DBコンテナID、
restart countは復旧前後で変化しなかった。

## Phase 5判定

Phase 5：**PASS**。TEST-12〜13がKillercoda実環境でPASSした。Keepalive `20/5/3`で旧APの
実接続3本が`35.664`秒後に自動解放され、PostgreSQLは再起動していない。APは
`connect_timeout=5`秒、`1→2→4`秒のbackoff後に再接続し、AP・DB再起動なしで業務COMMITに成功した。

## Phase 6判定

Phase 6：**PASS**。TEST-14〜15がKillercoda実環境でPASSした。同じ旧AP残留10本・管理2本・
新AP要求12件の条件で、`max_connections=20`では新AP成功5件／失敗7件・余力0本、
`max_connections=30`では成功12件／失敗0件・余力3本を実測した。両ケースともPostgreSQL再起動なし。
`max_connections`増加は容量余力を増やす対策であり、旧AP残留接続そのものを解消する根本対策ではない。
残留接続の解消はKeepalive等の別対策として扱う。

## Phase 7実測結果と判定

Phase 7：**PASS**。TEST-16〜18をKillercoda実環境で順に実行し、すべてPASSした。
TEST-00〜18はすべて実測PASS。Phase 7の資材は`f8239cc`で実測準備commit済みであり、
この判定は以下の人間から提供されたKillercoda実測結果に基づく。

- TEST-16：environment `ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569`、
  run `20260913T142437-6af60280`。reset前の旧AP接続は`10`本。reset後の
  正常業務COMMIT成功、DROPルール残存`0`、AP1 pause残存`false`。
  方式Aを再注入して旧AP接続`10`本とAP2接続失敗`9`件を確認。連続FAIL数`0`。
  evidence：`artifacts/test-16/ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569/20260913T142437-6af60280`。
- TEST-17：同環境、run `20260913T142530-397d6d4b`。旧AP接続`10→0`本、
  新AP接続と管理接続はともに維持。AP2業務request ID
  `phase7-business-ba0ac8205b3243eebc33a29fe12da3bf`がCOMMITし、
  postmaster起動時刻不変。正しい復旧をverifyがPASS判定。連続FAIL数`0`。
  evidence：`artifacts/test-17/ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569/20260913T142530-397d6d4b`。
- TEST-18：同環境、run `20260913T142535-42ce9997`。誤復旧としてDBを再起動。
  再起動後も業務COMMITは可能だったが、postmaster起動時刻が変化し、
  verify結果は`FAIL`。誤復旧を拒否したためTEST-18自体はPASS。連続FAIL数`0`。
  evidence：`artifacts/test-18/ubuntu-9a5b439e-7a34-4261-a420-0bdc72261569/20260913T142535-42ce9997`。

開発・TEST-ID検証は完了。TEST-18のDB再起動は誤復旧を拒否できるか確認するための
隔離された負例試験であり、正しい復旧手順には含まれない。

## Phase 7 Scenario retry追加実測

Scenarioで実際に使用するAPへ`connect_timeout=5`秒と`1→2→4`秒（以後4秒上限）の
自動retryを追加した。既存TEST-IDとは分離した限定チェックをKillercoda実環境で実施し、PASSした。

- environment：`ubuntu-12fe89c3-42e0-437e-937d-48c794226c32`
- run：`20260922T150317-1795-df92c39e`
- 実測：`connect_timeout=5`、backoff `1,2,4`、AP再起動`false`、DB再起動`false`、
  自動再接続後の業務COMMIT成功
- evidence：`artifacts/phase7-retry/ubuntu-12fe89c3-42e0-437e-937d-48c794226c32/20260922T150317-1795-df92c39e`
- 実装・実測準備commit：`bf28dd2`

これにより、元の恒久対策要件であるKeepalive `20/5/3`、`connect_timeout=5`、retry backoff
`1→2→4`秒は、Scenarioで使用する構成まで実装・実測済みとなった。TEST-00〜18のPASS記録は維持する。

## 未解決課題

- TEST-ID上の未完了項目はない。
- TEST-01〜18の実測artifactはKillercodaセッション内にあり、Git管理対象ではない。
- KillercodaブラウザからのScenario公開・開始・7 Step UI操作を第三者が通すエンドツーエンド確認は、
  自動試験およびretry限定実測では確認できない。次の作業は教材表示だけを使うブラウザE2E受入とする。

## 未実施TEST-IDの番号整理

Phase順との整合のため、未実施だった旧TEST-07を新TEST-06、旧TEST-08を新TEST-07、
旧TEST-06を新TEST-08へ変更した。試験内容とPASS条件は変更していない。TEST-00〜05は変更なし。

最新成果物commit：`bf28dd2`（Phase 7 Scenario AP retry実装・実測準備）

この文書を更新したチェックポイントcommitは、次回更新時に最新成果物commitとして記録する。
