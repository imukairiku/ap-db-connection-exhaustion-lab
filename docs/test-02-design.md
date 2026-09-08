# TEST-02 正常業務成功 設計

## 範囲

TEST-02はKillercoda上で`ap-server-1`の正常業務を1件だけ実行し、実際のPostgreSQL
transactionがCOMMITされることを確認する。TEST-00/01は再実行せず、障害注入、並列処理、
接続残留、`ap-server-2`は対象外とする。

## 設計

- TEST-02専用Compose projectで`db-server`と`ap-server-1`だけを起動する。
- APの`POST /work`は一意な`request_id`を受け取り、リクエストごとにDB接続を1本開く。
- APは`business_results`へ`request_id`をINSERTしてCOMMITし、接続を閉じる。
- APログへ同一`request_id`の`START`、`DB_CONNECTED`、`COMMIT`、`SUCCESS`をJSONで出力する。
- runnerはHTTP 200/SUCCESS、DBの確定行1件、4イベントの順序と一意性を照合する。
- 終了時は当該Compose projectだけを削除し、残存container/network/volumeが0であることを確認する。
- TEST-02専用の連続FAIL数を保存し、3回連続FAIL後は新規試行を停止する。

## PASS条件

Killercoda実環境で上記の全条件とcleanupが成功した場合のみPASSとする。静的確認やHTTPの
疑似成功だけではPASSにしない。
