## 6. 恒久対策を検討する

目的：次回の通信断で残る接続を長時間放置しないため、DB側TCP Keepaliveを設定します。DBは再起動せず、設定をリロードします。

`idle=20`秒後に探査を始め、`interval=5`秒間隔で最大`count=3`回失敗した接続を検出します。約35秒は目安で、実際の解放時間は環境で変わります。

```bash
cd /root/ap-db-connection-exhaustion-lab
PROJECT="phase7-$(cut -d- -f1 /proc/sys/kernel/random/boot_id)"
DB=$(sudo docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter 'label=com.docker.compose.service=db-server')
sudo docker exec "$DB" psql -U lab -d lab -c "ALTER SYSTEM SET tcp_keepalives_idle = 20"
sudo docker exec "$DB" psql -U lab -d lab -c "ALTER SYSTEM SET tcp_keepalives_interval = 5"
sudo docker exec "$DB" psql -U lab -d lab -c "ALTER SYSTEM SET tcp_keepalives_count = 3"
sudo docker exec "$DB" psql -U lab -d lab -c "SELECT pg_reload_conf()"
sudo docker exec "$DB" psql -U lab -d lab -c "SELECT name, setting FROM pg_settings WHERE name IN ('tcp_keepalives_idle','tcp_keepalives_interval','tcp_keepalives_count') ORDER BY name"
```

観察：最後の表示がidle`20`、interval`5`、count`3`になればverifyへ進みます。既存接続への適用や自動解放そのものは、このStepのverify対象ではありません。

AP側では接続待ちを無期限にしないため`connect_timeout=5`秒が現在のAPに設定されています。失敗時の再試行間隔`1→2→4`秒は連続接続でDBをさらに圧迫しないための恒久対策です。ただし、このScenarioのAPワーカーには自動retryの切替設定がなく、受講者にAPコード編集は求めません。今回のverifyはDB側設定の実値を判定します。`max_connections`の増加だけでは残留接続自体は消えません。
