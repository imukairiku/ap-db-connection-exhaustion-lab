# 開発進捗チェックポイント

更新日: 2026-09-09

現在のPhase：Phase 1（DB接続残留MVP）

完了済みTEST-ID：

- TEST-00：PASS（Phase 0環境探査）
- TEST-01：PASS（Docker Compose起動）
- TEST-02：PASS（正常時にap-server-1業務成功）
- TEST-03：PASS（最大12並列処理）
- TEST-04：PASS（障害注入時に複数接続が処理中）

次のTEST-ID：TEST-05（障害注入後に旧接続がpg_stat_activityとssの双方に残留）

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

## 未解決課題

- TEST-05以降は未着手。次回はTEST-05だけを対象にする。
- TEST-01〜04の実測artifactはKillercodaセッション内にあり、Git管理対象ではない。

最新成果物commit：`882dea0`（TEST-04実測準備）

この文書を更新したチェックポイントcommitは、次回更新時に最新成果物commitとして記録する。
