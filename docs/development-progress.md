# 開発進捗チェックポイント

更新日: 2026-09-13

現在のPhase：Phase 4（暫定復旧）

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

次のTEST-ID：TEST-10（pg_terminate_backendで復旧）

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

## 未解決課題

- TEST-10以降は未着手。次回はTEST-10だけを対象にする。
- TEST-01〜09の実測artifactはKillercodaセッション内にあり、Git管理対象ではない。
- Phase 4の復旧判定は未完了。TEST-09では接続識別のみ確認し、terminateによる復旧は実施していない。

## 未実施TEST-IDの番号整理

Phase順との整合のため、未実施だった旧TEST-07を新TEST-06、旧TEST-08を新TEST-07、
旧TEST-06を新TEST-08へ変更した。試験内容とPASS条件は変更していない。TEST-00〜05は変更なし。

最新成果物commit：`d1cf8dc`（TEST-09実測準備）

この文書を更新したチェックポイントcommitは、次回更新時に最新成果物commitとして記録する。
