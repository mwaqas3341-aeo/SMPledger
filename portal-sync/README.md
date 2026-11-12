# Portal sync (SMP portal -> Supabase)

Signs in to the SMP portal, reads each school's tables (inventory received, daily stock/consumption) and writes them
straight into this project's Supabase (`portal_receipts`, `portal_consumption`, `portal_sync_state`). Nothing is committed.
Only data not already stored is sent (the database remembers the last date per school and product; the last 3 days are re-sent).

Setup: add repository secrets `SMP_USERNAME`, `SMP_PASSWORD`, `SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`,
put the school list in `portal-sync/karor_mee_codes.txt` (one 8-digit EMIS per line), then run
Actions -> "Portal sync to Supabase". It also runs daily at 20:30 Pakistan time.

Local dry run on an existing export: `python scripts/push_supabase.py --bundle <folder> --dry-run`.
Send everything again: add `--full`.
