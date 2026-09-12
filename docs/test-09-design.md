# TEST-09 残留接続の識別

Phase 4の最初の試験。既存の方式AとPhase 3の監視プロセスを使い、AP1の処理中接続3本に双方向DROPを適用してからAP1をpauseする。監視プロセスだけがAP2を起動し、`ACTIVE`を宣言する。AP2の業務接続3本と管理接続2本を保持したまま、DB内の`pg_stat_activity`を採取する。

AP1障害前のPID集合と障害後のPID集合を照合し、`application_name`、`client_addr`、`backend_start`、`state_change`、`state`を保存する。AP1/AP2のIPはDocker inspectで独立に取得し、同名だけでなく接続元IPとの一致を確認する。管理接続は`management-1/2`として別に確認する。AP1の3本が同一PID・接続元IPで残り、AP2の3本と管理2本が別の接続として観測され、状態ファイルがAP2 ACTIVE、DB postmaster時刻不変のときのみPASSとする。

試験中に`pg_terminate_backend`は実行しない。試験終了時は隔離されたCompose projectを停止・破棄し、DROP ruleの除去を確認する。cleanupによる接続終了は判定後だけに行う。Killercoda実測前にPASSとはしない。
