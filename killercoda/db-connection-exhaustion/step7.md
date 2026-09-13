## 7. 業務を再試験する

`sudo bash scripts/scenario-business-check.sh` で、新たな業務要求がCOMMITできることを確認してください。
verifyは旧AP接続0、新AP・管理接続の維持、DBの再起動なし、COMMIT結果を再確認します。
やり直す場合は `sudo bash scripts/scenario-reset.sh` で正常状態へ戻し、
`sudo bash scripts/scenario-inject.sh` で同じ障害を再発生させられます。resetは復旧の代用ではありません。
