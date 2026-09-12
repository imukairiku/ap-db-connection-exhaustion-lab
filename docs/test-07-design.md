# TEST-07 APログにDB接続エラー

TEST-06で実測した専用Compose構成を再利用し、同じ方式Aで旧AP接続10本を残留させる。
新APを明示起動して12接続を要求し、PostgreSQLの`max_connections=20`に起因する接続拒否を
発生させる。TEST-06のtest scriptやFAIL counterは呼び出さず、TEST-07専用runとして記録する。

APの各workerは`psycopg2.connect`から発生した例外についてのみ`error_phase=connect`、
`error_type=OperationalError`、実例外文`db_error`、一意な`request_id`をJSON logに記録する。
runnerは同じrunの新AP状態に失敗が複数あり、AP logの失敗request IDと一致すること、
AP側エラー文がPostgreSQLの接続枠拒否文であること、DB側にも実FATALがあることを照合する。
エラー文を生成・置換するテストstubは使わない。postmaster起動時刻とrestart count不変、
当該Compose projectのcleanup成功も必須とする。自動切替はTEST-08の範囲外である。
