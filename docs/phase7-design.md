# Phase 7 実測準備設計（TEST-16〜18）

状態: 実測前。TEST-16〜18およびPhase 7はPASS未確定。

## 分離と基準

Phase 7専用の `tests/test-16.compose.yml` は `phase7-<boot-id先頭>` のCompose projectを使う。
Phase 0〜6のテストprojectや未追跡資材を変更しない。`scripts/phase7-lab.py reset` はこのprojectだけを
unpause、`phase7_`タグ付きDROPルール削除、`down -v`、再構築する。resetは演習の初期化であり、
暫定復旧としては認めない。再構築したDBのコンテナID、restart count、
`pg_postmaster_start_time()`を新しいbaselineとして記録する。

方式Aを使う `inject` は10本の旧AP処理中接続を `pg_stat_activity` とDB側 `ss` で照合し、
通信DROPを2方向へ投入してからAP1をpauseする。既存の監視器がpauseを検知しAP2を自動起動する。
AP2の12接続要求でPostgreSQL実ログの容量超過FATALとAP2側の接続失敗を観測する。
Phase 7専用APはトランザクションを演習時間中保持する。ダミー接続は使わない。

## TEST-ID別判定

- TEST-16: いったん障害を作り、reset後の旧APコンテナ消滅、DROP消滅、unpause、AP1業務COMMITを確認。
  同じ方式Aを再注入し、旧AP残留・自動切替・DB容量超過を再観測する。
- TEST-17: 旧AP接続だけを既存のPID再照合付き手順で終了。AP2・管理接続の元PIDと開始時刻が
  保たれ、AP2の新規業務がCOMMITし、DBコンテナ・postmaster・restart countが不変ならverify PASS。
- TEST-18: TEST-17後にresetで新しい隔離実験を始める。DB再起動で見かけ上業務を成功させても、
  verifyがDB継続性違反を理由にFAILしたときだけTEST-18をPASSとする。

各TESTは同一Killercoda起動環境の先行PASSをゲートにし、先行FAILでは後続を実行しない。
実行時の詳細証跡はGit追跡外の `artifacts/test-16..18/` に残る。

## Killercoda教材

`killercoda/db-connection-exhaustion/index.json` は7 Stepと各verifyを定義する。
開始時のbackgroundはGitHubから教材repoを取得してreset→障害を自動注入する。
初期問題文では旧AP残留・接続上限・Keepalive値を明示しない。
Step 1〜4は障害時の実状態、Step 5は対象限定復旧、Step 6はDBのKeepalive設定実値、
Step 7は新規業務COMMITと復旧状態を検証する。Step 6の設定確認はKeepaliveによる
自動解放の再実測と同義ではない（自動解放はTEST-12で別途確認済み）。

## 自己レビューと未確認事項

静的確認のみでPASSにしない。KillercodaのCompose standalone、NET_ADMIN、Docker pause、
監視器、DBの実接続数、reset再現性、verify正誤はTEST-16〜18の順で実測する。
背景セットアップやKillercoda UIからのverify起動も実環境で確認が必要。
