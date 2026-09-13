# Phase 6：接続数設計の実測比較（準備）

TEST-14とTEST-15は同一ランナー、同一Compose構成、同一AP資材を使用する。差分はPostgreSQL起動引数の`max_connections`のみ（20／30）。両方とも`superuser_reserved_connections=3`、旧APの処理中接続10本、管理接続2本、新APの接続要求12件を固定し、方式A（対象通信DROP→docker pause）を適用する。AP2は明示操作で起動し、自動切替の再試験はしない。

DBの`pg_stat_activity`から旧AP、新AP、管理用、その他のclient backendを数え、観測用SQL自身の接続は除く。AP2の状態から接続成功数と失敗数を取得し、DBログの実FATALも保存する。接続余力は`max_connections - superuser_reserved_connections - 観測中client backend数`と定義する（一般APユーザーが使える非予約枠）。マイナス値は0に丸めず、そのまま記録する。最終接続数は観測用SQL自身を除く実client backend数である。

TEST-14では旧AP残留10本と新APの実接続失敗を要求する。TEST-15では同じ負荷を再現し、TEST-14の同一環境PASS証跡との入力条件と測定値を並記する。30で失敗0件と決め打ちせず、実測値を残す。容量拡張は瞬間的な余力を作る対策であり、残留接続自体を解消するKeepaliveの代替ではない。DB再起動や手動backend終了を試験成立に利用しない。各TESTはKillercoda実測前にPASSとはしない。
