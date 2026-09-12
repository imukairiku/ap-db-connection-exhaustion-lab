# 開発進捗チェックポイント

更新日: 2026-09-13

現在のPhase：Phase 2（DB接続枯渇）

完了済みTEST-ID：

- TEST-00：PASS（Phase 0環境探査）
- TEST-01：PASS（Docker Compose起動）
- TEST-02：PASS（正常時にap-server-1業務成功）
- TEST-03：PASS（最大12並列処理）
- TEST-04：PASS（障害注入時に複数接続が処理中）
- TEST-05：PASS（障害注入後に旧接続がpg_stat_activityとssの双方に残留）
- TEST-06：PASS（max_connections=20でDB接続枯渇）

次のTEST-ID：TEST-07（APログにDB接続エラー）

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

## Phase 1判定

Phase 1：**PASS**。TEST-01〜05がすべてKillercoda実測PASSし、方式Aによる障害後15秒時点の
実PostgreSQL session/TCP接続12本の残留、PostgreSQL再起動なし、cleanup後の対象接続0を確認した。

## 未解決課題

- TEST-07以降は未着手。次回はTEST-07だけを対象にする。
- TEST-01〜06の実測artifactはKillercodaセッション内にあり、Git管理対象ではない。
- Phase 2は進行中であり、まだPASS確定していない。

## 未実施TEST-IDの番号整理

Phase順との整合のため、未実施だった旧TEST-07を新TEST-06、旧TEST-08を新TEST-07、
旧TEST-06を新TEST-08へ変更した。試験内容とPASS条件は変更していない。TEST-00〜05は変更なし。

最新成果物commit：`1b1a1a7`（TEST-06判定修正）

この文書を更新したチェックポイントcommitは、次回更新時に最新成果物commitとして記録する。
