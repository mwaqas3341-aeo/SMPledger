-- Apply LAST: only after the send-aeo-report edge function is deployed and the Brevo secrets are set.
-- Runs every minute but only calls the function when something has been waiting 3+ minutes,
-- so quiet periods cost nothing. The Authorization value is the project's public anon key.

select cron.unschedule('aeo-report-dispatch')
  where exists (select 1 from cron.job where jobname = 'aeo-report-dispatch');

select cron.schedule(
  'aeo-report-dispatch',
  '* * * * *',
  $cron$
  select net.http_post(
    url := 'https://gsswgpqrphqfomvsdooz.supabase.co/functions/v1/send-aeo-report',
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Imdzc3dncHFycGhxZm9tdnNkb296Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODY5NjE3OTUsImV4cCI6MjEwMjUzNzc5NX0.8NPY8wXzb99eopHpn-lMjSGPfayGAccz-g9f-Ob6gjQ'
    ),
    body := '{}'::jsonb
  )
  where exists (
    select 1 from public.aeo_report_queue
    where status = 'pending' and last_changed_at < now() - interval '3 minutes'
  );
  $cron$
);
