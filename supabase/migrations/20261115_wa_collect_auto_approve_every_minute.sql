-- After the admin's auto-approve time, every new entry is approved automatically.
-- The job used to run every 10 minutes (an entry could wait up to 10 minutes after arriving); it now runs
-- every minute, so an entry that arrives after the set time is approved within about a minute.
-- (Corrections - a different figure for a day that is already recorded - still wait for a person.)
select cron.alter_job(jobid, schedule := '* * * * *') from cron.job where jobname = 'wa-collect-auto-approve';
