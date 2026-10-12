# Supabase: user directory + AEO report emails

Source of truth for these backend pieces lives here so they are versioned with the app.

## Apply order
1. `migrations/20261012000001_user_directory_local_control.sql`
   Adds `profiles.report_email` and `profiles.locked_scope`; blocks signed-in non-admins from editing
   anything on their own profile except `report_email`; stops A-I-DB login/sync overwriting users an
   admin maintains locally. No behaviour changes for any user until an admin edits them in
   **Users & Markaz Access** (`users.html`).
2. `migrations/20261012000002_aeo_report_email_queue.sql`
   Queue table + fail-safe trigger on `consumption` (never blocks saving consumption).
3. Deploy edge function `functions/send-aeo-report` (verify_jwt **on**) and set secrets:
   - `BREVO_API_KEY`: Brevo -> SMTP & API -> API Keys
   - `BREVO_SENDER_EMAIL`: must be a verified sender in Brevo -> Senders & IP
   - `BREVO_SENDER_NAME`: optional, defaults to "SMP Reports"
   Until both required secrets exist the function leaves the queue untouched.
4. `migrations/20261012000003_aeo_report_dispatch_cron.sql` (apply last): per-minute dispatcher.

## Behaviour
- Saving a consumption entry queues (school, date). After 3 quiet minutes, waiting rows are grouped
  **per markaz** and one email goes to everyone holding that markaz (home or additional markaz,
  roles aeo/tr/admin) who has a report email, with Previous Balance / Consumed / Remaining per
  product for each school.
- Brevo free plan allows 300 emails/day; batching per markaz keeps usage well below that.
- Queued rows older than 3 days are expired, never sent late. Failed sends retry up to 3 times.
- Admin test: call the function with `{"test_email":"you@example.com"}` and an admin session to send a
  sample report and confirm Brevo works.

## Not stored in this repo
Personal data (CNICs, personal emails, phone numbers) is kept only in the database, never committed.
