# TEST-08 AP自動切替

Phase 3の切替完了インターフェースは`artifacts/phase3/current.json`である。これは
`environment_id`、`run_id`、`project`、`state_path`を持ち、対象runの
`failover-state.json`を指す。監視プロセスだけが状態ファイルを原子的に更新する。
`status=ACTIVE`、`active_service=ap-server-2`、AP2 container ID、障害検知時刻、
切替完了時刻を含む。後続verifyはpointerとstateのrun/project一致を確認し、
Docker上のAP2実体とhealthを独立に照合する。

TEST-08はAP1をhealthyな現用系として起動し、AP2が存在しないことを確認する。3本の
処理中DB接続を作って方式A（対象flowの双方向DROPを確認してからdocker pause）を実施する。
runnerはAP2の起動・ACTIVE化を呼ばない。別プロセスのmonitorがAP1のPaused状態を検知し、
同一Compose projectのAP2を起動し、healthyになった後だけACTIVEを宣言する。

PASS条件は、AP1の事前health、AP2事前不在、監視側の検知→起動→ACTIVEの順序、
状態インターフェースとDocker実体の一致、AP1=PAUSED、DB稼働、postmaster起動時刻と
restart count不変、対象ruleと専用projectのcleanup成功である。手動切替や将来の接続枯渇・
復旧判定は含めない。Killercoda実測前はPASSにしない。
