// SMP Ledger WhatsApp worker (Baileys). Sends only what the database hands out via fn_wa_claim_next().
// The daily cap (max 20), time window, emergency stop and dry-run are all enforced in the database.
import 'dotenv/config';
import makeWASocket, { useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion } from '@whiskeysockets/baileys';
import { createClient } from '@supabase/supabase-js';
import pino from 'pino';
import qrcode from 'qrcode-terminal';

const { SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY } = process.env;
if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) throw new Error('Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY');

const db = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, { auth: { persistSession: false } });
const log = pino({ level: 'info' });
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const rand = (a, b) => (a + Math.random() * (b - a)) * 1000;

let sock = null;
let connected = false;
let consecutiveFailures = 0;
let busy = false;

async function emergencyStop(reason) {
  log.error({ reason }, 'EMERGENCY STOP');
  await db.from('wa_settings').update({ emergency_stop: true }).eq('id', true);
  await db.from('wa_logs').insert({ event: 'emergency_stop', error_message: String(reason).slice(0, 500) });
}

async function start() {
  const { state, saveCreds } = await useMultiFileAuthState('./auth');
  const { version } = await fetchLatestBaileysVersion();
  sock = makeWASocket({ version, auth: state, logger: pino({ level: 'warn' }), printQRInTerminal: false, markOnlineOnConnect: false });

  sock.ev.on('creds.update', saveCreds);

  // First-time link without a QR: set WA_PAIRING_NUMBER (digits with country code, e.g. 923047392281)
  const pairNo = (process.env.WA_PAIRING_NUMBER || '').replace(/\D/g, '');
  if (pairNo && !sock.authState.creds.registered) {
    setTimeout(async () => {
      try {
        const code = await sock.requestPairingCode(pairNo);
        log.info(`PAIRING CODE for +${pairNo}: ${code}  (WhatsApp > Linked devices > Link with phone number)`);
      } catch (e) { log.error(e, 'pairing code request failed'); }
    }, 3000);
  }

  sock.ev.on('connection.update', async ({ connection, lastDisconnect, qr }) => {
    if (qr) qrcode.generate(qr, { small: true });
    if (connection === 'open') { connected = true; log.info('WhatsApp connected'); }
    if (connection === 'close') {
      connected = false;
      const code = lastDisconnect?.error?.output?.statusCode;
      if (code === DisconnectReason.loggedOut || code === 403 || code === 401) {
        await emergencyStop(`Session ended (code ${code}). Possible restriction; do not relink until checked.`);
        process.exit(1);
      }
      log.warn({ code }, 'Disconnected, reconnecting in 15s');
      await sleep(15000);
      start();
    }
  });

  // Delivery receipts
  sock.ev.on('messages.update', async (updates) => {
    for (const u of updates) {
      if (u.key?.fromMe && u.update?.status >= 3) await db.rpc('fn_wa_mark_delivered', { p_provider_id: u.key.id });
    }
  });

  // Opt-out: recipient replies STOP
  sock.ev.on('messages.upsert', async ({ messages }) => {
    for (const m of messages) {
      if (m.key.fromMe) continue;
      const text = (m.message?.conversation || m.message?.extendedTextMessage?.text || '').trim().toUpperCase();
      if (text === 'STOP') {
        const phone = '+' + (m.key.remoteJid || '').split('@')[0];
        await db.rpc('fn_wa_opt_out', { p_phone: phone });
        await sock.sendMessage(m.key.remoteJid, { text: 'You have been unsubscribed from SMP notifications.' });
      }
    }
  });
}

async function tick() {
  if (busy) return;
  busy = true;
  try {
    const { data, error } = await db.rpc('fn_wa_claim_next');
    if (error) { log.error(error, 'claim failed'); return; }
    const job = data?.[0];
    if (!job) return;

    if (job.q_dry_run) {
      await db.rpc('fn_wa_report_result', { p_queue_id: job.q_id, p_ok: true, p_dry: true });
      log.info({ id: job.q_id }, 'dry-run: not sent');
      return;
    }
    if (!connected) {
      await db.rpc('fn_wa_report_result', { p_queue_id: job.q_id, p_ok: false, p_error: 'Worker not connected' });
      return;
    }

    await sleep(rand(job.q_min_gap, job.q_max_gap)); // human-like spacing between sends
    const digits = job.q_phone.replace('+', '');
    try {
      const [res] = await sock.onWhatsApp(digits);
      if (!res?.exists) {
        await db.rpc('fn_wa_report_result', { p_queue_id: job.q_id, p_ok: false, p_error: 'Number not on WhatsApp', p_permanent: true });
        return; // invalid number is not a session failure
      }
      const sent = await sock.sendMessage(res.jid, { text: job.q_text });
      await db.rpc('fn_wa_report_result', { p_queue_id: job.q_id, p_ok: true, p_provider_id: sent?.key?.id });
      consecutiveFailures = 0;
      log.info({ id: job.q_id }, 'sent');
    } catch (e) {
      consecutiveFailures++;
      await db.rpc('fn_wa_report_result', { p_queue_id: job.q_id, p_ok: false, p_error: e.message });
      log.error(e, 'send failed');
      if (consecutiveFailures >= 3) { await emergencyStop('3 consecutive send failures'); process.exit(1); }
    }
  } finally {
    busy = false;
  }
}

await start();
setInterval(tick, 60 * 1000);
