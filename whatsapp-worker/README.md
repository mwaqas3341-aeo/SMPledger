# WhatsApp worker: automatic "missing consumption on SMP" Excel report

`smp-file.mjs` is added next to the worker's main file on Wispbyte. Two small edits to the main file:

1. Near the other imports:
   `import { smpFileTick } from './smp-file.mjs';`
2. Next to the other `setInterval(...)` lines at the bottom:
   `setInterval(() => smpFileTick({ db, log, getSock: () => sock, isConnected: () => connected }), 60 * 1000);`

No new npm packages are needed (the Excel file is written with Node's built-in zlib).

How it works: each group (Admin > WhatsApp data collection > groups) can have an "SMP missing-consumption Excel time" and a mode
(previous day, or same day from 3:00 PM). `fn_wa_smp_enqueue_due()` (every 5 minutes) creates the job once the time has come and
fresh SMP data exists (waits up to 3 hours, then sends with a warning). `fn_wa_smp_claim_next()` hands it to the worker within the
daily cap / emergency stop / dry-run settings. The message states when the SMP web-portal data was fetched; the file lists the
schools and has a per-school fetch-time column.
