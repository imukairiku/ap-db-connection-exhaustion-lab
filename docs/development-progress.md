# 開発進捗チェックポイント

更新日: 2026-09-09

現在のPhase：Phase 1（DB接続残留MVP）

完了済みTEST-ID：

- TEST-00：PASS（Phase 0環境探査）
- TEST-01：PASS（Docker Compose起動）
- TEST-02：PASS（正常時にap-server-1業務成功）
- TEST-03：PASS（最大12並列処理）

次のTEST-ID：TEST-04（障害注入時に複数接続が処理中）

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

## 未解決課題

- TEST-04以降は未着手。次回はTEST-04だけを対象にする。
- TEST-01〜03の実測artifactはKillercodaセッション内にあり、Git管理対象ではない。

最新成果物commit：`d41a2c8`（TEST-03実測準備）

この文書を更新したチェックポイントcommitは、次回更新時に最新成果物commitとして記録する。
