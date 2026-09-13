## 4. 接続を識別する

`pg_stat_activity` の `application_name`、`client_addr`、`backend_start`、`state_change` を確認してください。
旧AP、新AP、管理用接続を区別し、どの接続が障害時点から残っているか推定します。
必要ならDBコンテナで `ss -nt` も照合してください。まだ接続を終了しないでください。
