## 2. 業務影響を確認する

ap-server-2のログと `GET /state` 相当の情報から、成功要求と失敗要求が混在するか確認してください。
`docker compose -p <project> -f tests/test-16.compose.yml logs ap-server-2` が手掛かりです。
project名は `artifacts/phase7/current.json` を参照してください。
