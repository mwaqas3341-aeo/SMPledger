// SMP Ledger WhatsApp worker (Baileys). Sends only what the database hands out via fn_wa_claim_next().
// The daily cap (max 50), time window, emergency stop and dry-run are all enforced in the database.
import 'dotenv/config';
import fs from 'node:fs';
import * as baileys from '@whiskeysockets/baileys';
const { useMultiFileAuthState, DisconnectReason, fetchLatestBaileysVersion } = baileys;
const makeWASocket = typeof baileys.default === 'function' ? baileys.default : (baileys.makeWASocket || baileys.default?.default);
import { createClient } from '@supabase/supabase-js';
import pino from 'pino';
import qrcode from 'qrcode-terminal';
import QRCode from 'qrcode';

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

// Tell the database which groups this number belongs to, so the Admin page can offer them as recipients.
async function syncGroups() {
  try {
    const groups = await sock.groupFetchAllParticipating();
    const rows = Object.values(groups).map((g) => ({ jid: g.id, subject: g.subject || null, updated_at: new Date().toISOString() }));
    if (rows.length) await db.from('wa_groups').upsert(rows, { onConflict: 'jid' });
    log.info({ count: rows.length }, 'groups synced');
  } catch (e) {
    log.warn(e, 'could not sync groups');
  }
}

// ---- Data collection (branch feature): read replies in collection groups, send the daily prompt ----
let ackOn = false, ackAt = 0;
async function ackEnabled() {
  if (Date.now() - ackAt > 60000) {
    const { data } = await db.from('wa_collect_settings').select('ack_enabled').eq('id', true).maybeSingle();
    ackOn = !!data?.ack_enabled; ackAt = Date.now();
  }
  return ackOn;
}
const textOf = (msg) => msg?.conversation || msg?.extendedTextMessage?.text || msg?.imageMessage?.caption || '';
async function collectIncoming(m) {
  try {
    const text = textOf(m.message).trim();
    if (!text) return;
    const ctx = m.message?.extendedTextMessage?.contextInfo;
    const quoted = ctx?.quotedMessage ? textOf(ctx.quotedMessage) : null;
    // newer WhatsApp versions may hide the number behind an @lid id; prefer the real phone-number id when Baileys provides it
    const sender = (m.key.participantPn || m.key.participantAlt || m.key.participant || m.participant || '').split('@')[0].split(':')[0];
    const { data, error } = await db.rpc('fn_wa_collect_ingest', {
      p_group_jid: m.key.remoteJid, p_sender: sender, p_msg_id: m.key.id, p_text: text, p_quoted: quoted });
    if (error) { log.warn(error, 'collect ingest failed'); return; }
    if (data && connected && await ackEnabled()) await sock.sendMessage(m.key.remoteJid, { text: data }, { quoted: m });
  } catch (e) { log.warn(e, 'collect incoming failed'); }
}
let collectBusy = false;
async function collectTick() {
  if (collectBusy || !connected) return;
  collectBusy = true;
  try {
    const { data, error } = await db.rpc('fn_wa_collect_claim_next');
    if (error) return;
    const job = data?.[0];
    if (!job) return;
    await sleep(rand(job.m_min_gap, job.m_max_gap));
    try {
      const sent = await sock.sendMessage(job.m_jid, { text: job.m_text });
      await db.rpc('fn_wa_collect_report_result', { p_id: job.m_id, p_ok: true, p_provider_id: sent?.key?.id });
      log.info({ id: job.m_id }, 'collection prompt sent');
    } catch (e) {
      await db.rpc('fn_wa_collect_report_result', { p_id: job.m_id, p_ok: false, p_error: e.message });
      log.error(e, 'collection prompt failed');
    }
  } finally { collectBusy = false; }
}

async function start() {
  const { state, saveCreds } = await useMultiFileAuthState('./auth');
  const { version } = await fetchLatestBaileysVersion();
  sock = makeWASocket({ version, auth: state, logger: pino({ level: 'warn' }), printQRInTerminal: false, markOnlineOnConnect: false });

  sock.ev.on('creds.update', saveCreds);

  sock.ev.on('connection.update', async ({ connection, lastDisconnect, qr }) => {
    if (qr) {
      // Link by scanning: WhatsApp > Linked devices > Link a device. A new QR is issued about every 20 seconds.
      log.info('Scan this QR with WhatsApp (also saved as qr.png - open it from the file manager if the console garbles it)');
      qrcode.generate(qr, { small: true });
      QRCode.toFile('./qr.png', qr, { width: 480, margin: 2 }).catch((e) => log.warn(e, 'could not write qr.png'));
    }
    if (connection === 'open') {
      connected = true;
      log.info('WhatsApp connected');
      fs.rm('./qr.png', { force: true }, () => {});   // the QR is no longer needed (and must not be left lying around)
      setTimeout(syncGroups, 5000);
    }
    if (connection === 'close') {
      connected = false;
      const code = lastDisconnect?.error?.output?.statusCode;
      if (code === DisconnectReason.loggedOut || code === 403 || code === 401) {
        await emergencyStop(`Session ended (code ${code}). Possible restriction; do not relink until checked.`);
        process.exit(1);
      }
      // Right after a successful QR scan WhatsApp asks for one restart - do that straight away.
      if (code === DisconnectReason.restartRequired) { log.info('Restart required after linking, reconnecting'); start(); return; }
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
      if ((m.key.remoteJid || '').endsWith('@g.us')) { await collectIncoming(m); continue; }   // groups: data collection only (never STOP etc.)
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
    const isGroup = job.q_phone.endsWith('@g.us');
    try {
      let jid;
      if (isGroup) {
        jid = job.q_phone;              // groups are addressed directly
      } else {
        const [res] = await sock.onWhatsApp(job.q_phone.replace('+', ''));
        if (!res?.exists) {
          await db.rpc('fn_wa_report_result', { p_queue_id: job.q_id, p_ok: false, p_error: 'Number not on WhatsApp', p_permanent: true });
          return; // invalid number is not a session failure
        }
        jid = res.jid;
      }
      const sent = await sock.sendMessage(jid, { text: job.q_text });
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
setInterval(collectTick, 60 * 1000);
