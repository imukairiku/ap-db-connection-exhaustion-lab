# Phase 0 実測報告

## 判定

- Phase: Phase 0（環境能力調査・障害注入方式選定）
- TEST-ID: TEST-00
- 結果: **PASS**
- 実行attempt: 4
- 確定方式: **A（対象通信DROP後にAPコンテナをpause）**
- AP停止状態: `PAUSED`

Phase 1へ進むための障害注入方式は方式Aに確定した。優先順位最上位の方式Aが
QUALIFIEDとなった時点で探索を終了しており、方式B〜Eは未実行である。

## 実測環境

| 項目 | 実測値 |
|---|---|
| environment | Killercoda |
| environment ID | `ubuntu-01747e9d-d5c2-494b-bc03-e68deae7aac4` |
| Docker | `29.1.3` |
| Docker Compose | standalone `docker-compose 1.29.2` |
| 選定方式 | `A` |

## 接続残留の実測結果

方式Aの注入前接続をPostgreSQL backend PIDとDB namespace側のcanonical TCP
4-tupleで照合した。次の全観測点で、注入前から同一の相異なる3接続が残留した。

| 観測点 | AP状態 | matched_count | 判定 |
|---|---:|---:|---|
| `immediate_after` | `PAUSED` | 3 | PASS |
| `after_5s` | `PAUSED` | 3 | PASS |
| `after_15s` | `PAUSED` | 3 | PASS |

単なる接続総数ではなく、PID、backend開始時刻、client endpoint、およびDB側
`ss` の `ESTAB` tupleをTEST-00が再計算している。

## cleanupと無再起動保証

cleanupでは、注入前台帳の各接続について次の全項目を再照合する実装を使用した。

- `pid`
- `backend_start`
- `application_name`
- `client_addr`
- `client_port`

既に消滅したPIDは `SKIPPED_GONE`、全項目が一致したPIDだけを
`pg_terminate_backend` の対象とする。PIDが存在してもidentityが異なる場合は
`IDENTITY_MISMATCH` としてcleanupをFAILさせ、対象外backendを終了しない。
psql変数は `docker exec -i ... psql -v ...` のstdin経由で確実に展開し、SQLと
PIDごとのaction/resultをartifactへ保存した。cleanup後は、注入前PIDとtupleが
`pg_stat_activity` と `ss` の双方から消えたことをTEST-00が検証した。

PostgreSQLの `pg_postmaster_start_time()` とDocker restart countについても
TEST-00内部検証PASS（個別値はartifact）である。提示された端末出力には個別値が
含まれていないため、本報告では推測値を記載しない。

## Evidence

実測証拠はKillercoda session内の次のattempt別ディレクトリに保存された。

```text
artifacts/phase0/ubuntu-01747e9d-d5c2-494b-bc03-e68deae7aac4/run-20260903T155321-1728/result.jsonl
```

正確なパスはKillercoda端末が表示した最終evidence pathおよび生成済み
`config/selected-method.json` の `evidence_artifact` と一致する。同じrun directoryに
connection snapshot、readiness履歴、cleanup ledger、cleanup SQL、PID別cleanup結果、
execution contextが保存されている。

## attempt 4 one-shot承認

既知の連続FAIL 3回を受け、人間が方式Aのidentity-safe cleanup修正を検証する
attempt 4を明示承認した。probeは最初の障害注入前にone-shot承認を原子的に消費し、
次の消費済みmarkerを生成した。

```text
artifacts/phase0/attempt4-authorization-consumed.json
```

attempt 4はPASSして完了している。同じ承認は再利用できず、attempt 5は許可されて
いない。再試験が必要な場合は新たな人間エスカレーションを要する。

## 残課題

- Killercoda runtime artifactを共有workspaceへ同期していないため、本報告から
  postmaster時刻などの個別値を直接参照することはできない。
- Phase 1以降は、Killercoda sessionで生成された`config/selected-method.json`を
  schema、environment ID、evidence存在まで検証し、方式名をハードコードせず利用する。
