CREATE ROLE app_user LOGIN PASSWORD 'app-only' NOSUPERUSER;
CREATE TABLE business_results (request_id text PRIMARY KEY, ap_name text NOT NULL);
GRANT INSERT, SELECT ON business_results TO app_user;
