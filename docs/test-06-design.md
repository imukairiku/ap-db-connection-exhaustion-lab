# TEST-06 max_connections=20でDB接続枯渇 設計

TEST-06はPostgreSQL自身の`max_connections=20`による接続拒否をKillercodaで実測する。
方式Aで`ap-server-1`の非superuser接続10本を残留させた後、`ap-server-2`を明示的に起動し、
12本を要求する。自動切替はTEST-08の範囲なので実装しない。

PostgreSQLは`superuser_reserved_connections=3`のため、非superuserのAP枠は最大17本である。
旧AP 10本に対して新APの接続要求が並列に集中するため、成功数は一時的な認証中backendや
観測時点によって変動する。管理用superuser接続2本も保持する。実上限到達はPostgreSQL自身の
`FATAL: sorry, too many clients already`と予約枠エラーで確認し、収束後の`numbackends`を
瞬間ピーク20と取り違えない。人工的な接続エラーは生成しない。

PASS条件は、旧AP残留10、新AP接続7以上、新AP接続失敗1以上、PostgreSQL
`max_connections=20`、PostgreSQLログの実FATAL、観測時のclient backend内訳の整合、旧APと新APの実backend識別、postmaster起動時刻と
restart count不変である。cleanupは方式Aを解除し、旧AP PIDをidentity-safeに終了してから
専用Compose projectだけを削除する。
