# 開発進捗チェックポイント

更新日: 2026-09-09

現在のPhase：Phase 1（DB接続残留MVP）

完了済みTEST-ID：

- TEST-00：PASS（Phase 0環境探査）
- TEST-01：PASS（Docker Compose起動）

次のTEST-ID：TEST-02（正常時にap-server-1業務成功）

採用済み技術方式：方式A「対象通信DROP → docker pause」

## 重要な実測結果

- TEST-00 attempt 4：Killercoda実環境で方式Aを確認。障害注入後の
  `immediate_after`、`after_5s`、`after_15s`で対象接続が各3件残留し、AP状態は`PAUSED`。
- TEST-01：Killercoda実環境でPASS。
  - environment ID：`ubuntu-81356df3-62ce-41aa-904b-1a5bfcbe032d`
  - run ID：`20260908T165104-2137-e89aab53`
  - 連続FAIL数：`0`（直前のFAIL 1回後にPASSしてリセット）
  - evidence：`artifacts/test-01/ubuntu-81356df3-62ce-41aa-904b-1a5bfcbe032d/20260908T165104-2137-e89aab53`

## 未解決課題

- TEST-02以降は未着手。次回はTEST-02だけを対象にする。
- TEST-01の実測artifactはKillercodaセッション内にあり、Git管理対象ではない。

最新成果物commit：`c1d0ad42aa4724184ce19c9da6ec52a097839214`

この文書を更新したチェックポイントcommitは、次回更新時に最新成果物commitとして記録する。
