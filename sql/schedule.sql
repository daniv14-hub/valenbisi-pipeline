-- Valenbisi pipeline: scheduling (Supabase: pg_cron + pg_net + Vault)
--
-- GitHub's built-in cron proved unreliable for a 30-minute schedule (most runs
-- were skipped), so the database triggers the GitHub Actions workflow instead:
-- every 30 minutes pg_cron calls GitHub's "workflow dispatch" API through pg_net.
--
-- This file documents what is configured in the database. It contains no secrets:
-- the GitHub token is stored encrypted in Supabase Vault.


-- 1. Extensions.
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;


-- 2. GitHub token (fine-grained, this repository only, Actions: read and write).
--    Run once by hand with the real token and do not save the query:
--
--    SELECT vault.create_secret('<GITHUB_TOKEN>', 'github_token');


-- 3. The job: trigger the "Collect Valenbisi data" workflow every 30 minutes.
SELECT cron.schedule(
  'trigger-valenbisi-collect',
  '*/30 * * * *',
  $$
  SELECT net.http_post(
    url := 'https://api.github.com/repos/daniv14-hub/valenbisi-pipeline/actions/workflows/collect.yml/dispatches',
    headers := jsonb_build_object(
      'Authorization', 'Bearer ' || (SELECT decrypted_secret FROM vault.decrypted_secrets WHERE name = 'github_token'),
      'Accept', 'application/vnd.github+json',
      'User-Agent', 'valenbisi-pipeline',
      'Content-Type', 'application/json'
    ),
    body := '{"ref": "main"}'::jsonb
  );
  $$
);


-- 4. Monitoring.
--    Is the job active?
SELECT jobid, jobname, schedule, active FROM cron.job;

--    Did the last runs start correctly?
SELECT status, return_message, start_time
FROM cron.job_run_details
ORDER BY start_time DESC
LIMIT 5;

--    What did GitHub answer? (204 = accepted)
SELECT id, status_code, content
FROM net._http_response
ORDER BY id DESC
LIMIT 5;


-- 5. To stop the job:
--    SELECT cron.unschedule('trigger-valenbisi-collect');
