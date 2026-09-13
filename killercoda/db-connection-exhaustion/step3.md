## 3. DB側の状況を調べる

`SHOW max_connections;` と `pg_stat_activity`、DBログを比較してください。
接続失敗がAP側の表示だけでなく、PostgreSQLの実際の接続上限に由来するか確認します。
