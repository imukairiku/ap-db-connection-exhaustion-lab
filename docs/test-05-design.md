# TEST-05 障害注入後の旧接続残留 設計

TEST-05は確定済み方式A「双方向通信DROP → docker pause」を使用し、注入直前に相関した
12接続について`immediate_after`、`after_5s`、`after_15s`で同一PostgreSQL backend PIDと
DB側TCP tupleが複数（最低2、期待12）残留することを実測する。各観測点でAPは`PAUSED`、
postmaster起動時刻とDB restart countは不変でなければならない。

cleanupはAPをunpauseし、当該tagのDROPだけを除去する。続いて注入前の各PIDを
PID、backend_start、application_name、client_addr、client_portで再照合し、消滅済みは成功、
完全一致した対象PIDだけをterminateする。identity不一致はFAILとする。DB稼働中にbefore PIDと
tupleが`pg_stat_activity`と`ss`の双方から0になり、postmaster/restart countが不変であることを
確認してから、TEST-05専用Compose projectを削除する。

AP切替、接続枯渇、恒久対策は対象外である。Killercoda実測で全条件が成立した場合のみPASSとする。
