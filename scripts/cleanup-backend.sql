WITH current_pid AS MATERIALIZED (
  SELECT pid, backend_start, application_name, client_addr, client_port
  FROM pg_stat_activity
  WHERE pid = :'pid'::integer
), matched AS MATERIALIZED (
  SELECT pid
  FROM current_pid
  WHERE backend_start = :'backend_start'::timestamptz
    AND application_name = :'application_name'
    AND client_addr = :'client_addr'::inet
    AND client_port = :'client_port'::integer
), terminated AS (
  SELECT pg_terminate_backend(pid) AS ok FROM matched
)
SELECT json_build_object(
  'pid', :'pid'::integer,
  'action', CASE
    WHEN NOT EXISTS (SELECT 1 FROM current_pid) THEN 'SKIPPED_GONE'
    WHEN NOT EXISTS (SELECT 1 FROM matched) THEN 'IDENTITY_MISMATCH'
    ELSE 'TERMINATED'
  END,
  'terminated', COALESCE((SELECT bool_and(ok) FROM terminated), false)
)::text;
