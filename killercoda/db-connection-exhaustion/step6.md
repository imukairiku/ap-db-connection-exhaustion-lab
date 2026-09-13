## 6. 恒久対策を検討する

暫定復旧後、再発時の接続残留を短縮するTCP Keepaliveを検討してください。
PostgreSQLの `tcp_keepalives_idle=20`、`tcp_keepalives_interval=5`、`tcp_keepalives_count=3` を設定し、再起動せずリロードしてください。
verifyは設定の実値を確認します。既存TCP接続への適用と自動解放の実測は別問題で、Phase 5の試験結果を参照できます。
`max_connections`を増やすだけでは、残留接続そのものは解消しません。
