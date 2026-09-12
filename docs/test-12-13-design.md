# Phase 5 実測準備：TEST-12／TEST-13

TEST-12はDBサーバー側の`tcp_keepalives_idle=20`、`tcp_keepalives_interval=5`、`tcp_keepalives_count=3`を設定し、`SHOW`と接続単位の`pg_stat_activity`で有効値を採取する。旧APで複数の実DB接続を保持し、方式A（AP側の双方向DROP→pause）を適用する。対象PIDとTCP tupleがDB側`pg_stat_activity`と`ss`の双方に残ることを確認してから、手動終了せず1秒間隔で消滅まで測定する。判定時間は固定35秒とせず、実測秒数を記録する。DB postmaster時刻・コンテナ再起動回数不変を要件とする。終了後の隔離Compose project停止は試験判定後の資源cleanupであり、接続解放判定には使わない。

TEST-13は別の隔離Compose projectでDBを起動したまま、AP2ネットワーク名前空間のDB宛通信をDROPする。AP2 retry workerが`connect_timeout=5`で実DB接続を試み、失敗時刻と所要秒数、backoff 1→2→4秒の開始・終了をJSONログに残す。3回の失敗とbackoffを確認後にDROPを除去し、AP2を再起動せず次のretryで業務INSERT/COMMITする。DB内の行、APログ、AP/DBコンテナID・restart count・postmaster時刻を照合する。TEST-12がFAILならTEST-13は実行しない。

両TESTはKillercoda実測前にPASSとはしない。実測値の報告と進捗確定は別commitとする。
