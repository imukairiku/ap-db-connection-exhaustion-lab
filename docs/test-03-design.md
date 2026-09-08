# TEST-03 最大12並列処理 設計

## 範囲

TEST-03はKillercoda上で`ap-server-1`が12件の業務を同時に処理し、全件を正常にCOMMIT
できることを実測する。TEST-00〜02は再実行しない。障害注入、接続残留、AP切替は対象外とする。

## 設計と判定

- TEST-03専用Compose projectで`db-server`と`ap-server-1`だけを起動する。
- 12個の一意な`request_id`でHTTPリクエストを同時送信する。
- 各リクエストは独立したDB接続とtransactionを使用し、INSERT後に8秒間処理を継続する。
- 処理中にAPのactive数と`pg_stat_activity`の`application_name='ap-server-1'`をpollし、
  双方が同時に12となった観測点を必須とする。
- 12件処理中の13件目はHTTP 429で拒否し、最大同時業務数12を確認する。
- 12応答すべてがHTTP 200/SUCCESS、DB確定行が12件、各request IDのログが
  `START → DB_CONNECTED → COMMIT → SUCCESS`であることを照合する。
- 当該Compose projectだけをcleanupし、TEST-03専用FAIL counterを管理する。

静的確認だけではPASSにしない。上記の実測条件がすべて成立した場合のみPASSとする。
