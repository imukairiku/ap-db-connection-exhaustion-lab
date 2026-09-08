# TEST-04 障害注入時の処理中接続 設計

TEST-04は、12件の業務がCOMMIT前のbarrierで待機し、AP・PostgreSQL・DB側TCPの三者で
同じ12接続を確認した時点に限り、確定済み方式A「双方向通信DROP → docker pause」を1回
実行する。対象flow以外のfirewall変更、方式B〜E、AP切替は行わない。

PASSには、注入直前のAP active/connected/waiting各12、異なるPostgreSQL backend 12、
`ss`と相関したTCP接続12、COMMIT/ROLLBACK前であること、対象DROP rule 2本、DROP確認後の
AP=`PAUSED`、DB稼働、postmaster起動時刻とrestart count不変を要求する。ledgerの順序は
snapshot完了、OUTPUT DROP、INPUT DROP、rule確認、pause、pause確認とする。

cleanupはAPをunpauseし、当該tagの2 ruleだけを除去してから当該Compose projectを削除する。
TEST-04では注入後の経時的な接続残留をPASS判定しない。これはTEST-05の範囲である。
