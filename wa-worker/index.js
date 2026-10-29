// SMP Ledger WhatsApp worker (Baileys). Sends only what the database hands out via fn_wa_claim_next().
// The daily cap (max 50), time window, emergency stop and dry-run are all enforced in the database.
import 'dotenv/config';
import fs from 'node:fs';
import crypto from 'node:crypto';
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
// Diagnostics for edits: write the SHAPE (key names only, no message text) of unusual group events to the issue log, so it can be read in the database.
const shape = (o, d = 0) => (o && typeof o === 'object' && d < 5) ? Object.fromEntries(Object.keys(o).slice(0, 12).map(k => [k, shape(o[k], d + 1)])) : (o === null || o === undefined ? o : typeof o);
async function diag(jid, tag, obj) {
  try { await db.rpc('fn_wa_collect_log', { p_group: jid, p_phone: null, p_name: null, p_kind: null, p_emis: null, p_outcome: 'ignored', p_cat: 'diag_' + tag, p_detail: JSON.stringify(shape(obj)).slice(0, 900), p_raw: null, p_msg: null }); } catch {}
}
// ---- Edits arrive end-to-end encrypted (secretEncryptedMessage) in newer WhatsApp; they are opened with the secret of the ORIGINAL message ----
const SECRETS_FILE = './msg-secrets.json';
let secrets = {}, secretsDirty = false;
try { secrets = JSON.parse(fs.readFileSync(SECRETS_FILE, 'utf8')); } catch {}
setInterval(() => {
  try {
    const cut = Date.now() - 3 * 86400000;
    for (const k of Object.keys(secrets)) if (secrets[k].t < cut) { delete secrets[k]; secretsDirty = true; }
    if (secretsDirty) { fs.writeFileSync(SECRETS_FILE, JSON.stringify(secrets)); secretsDirty = false; }
  } catch {}
}, 60000);
const jidForms = (...vals) => {
  const out = new Set();
  for (const v of vals) {
    if (!v) continue;
    out.add(v);
    const bare = String(v).split('@')[0].split(':')[0];
    out.add(bare + '@s.whatsapp.net'); out.add(bare + '@lid');
  }
  return [...out];
};
const hmac = (key, data) => crypto.createHmac('sha256', key).update(data).digest();
function openSecret(secretHex, id, origForms, modForms, payload, iv) {
  const secret = Buffer.from(secretHex, 'hex'), key0 = hmac(Buffer.alloc(32), secret);
  const ct = Buffer.from(payload).subarray(0, -16), tag = Buffer.from(payload).subarray(-16);
  for (const useCase of ['Message Edit', 'Edit Message', 'Message Edited', 'Edit', 'Secret Encrypted Message'])
    for (const o of origForms) for (const mo of modForms) {
      const key = hmac(key0, Buffer.concat([Buffer.from(id), Buffer.from(o), Buffer.from(mo), Buffer.from(useCase), Buffer.from([1])]));
      for (const aad of [`${id}\u0000${mo}`, `${id}\u0000${o}`, null]) {
        try {
          const d = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(iv)); d.setAuthTag(tag);
          if (aad !== null) d.setAAD(Buffer.from(aad));
          const plain = Buffer.concat([d.update(ct), d.final()]);
          return { plain, how: { useCase, aad: aad === null ? 'none' : (aad.endsWith(mo) ? 'mod' : 'orig') } };
        } catch { /* wrong combination */ }
      }
    }
  return null;
}
async function collectSecretEdit(m, sem, sender) {
  const jid = m.key.remoteJid, origId = sem.targetMessageKey?.id;
  if (!origId) return;
  const info = { enc: sem.secretEncType, haveSecret: !!secrets[origId] };
  let ok = false;
  try {
    const s = secrets[origId];
    if (s) {
      const r = openSecret(s.s, origId, jidForms(...(s.p || [])), jidForms(m.key.participantPn, m.key.participantAlt, m.key.participant, m.participant, sender), sem.encPayload, sem.encIv);
      info.opened = !!r; if (r) info.how = r.how;
      if (r) {
        const dm = baileys.proto.Message.decode(r.plain);
        const em = dm.protocolMessage?.editedMessage || dm.editedMessage?.message || dm;
        if (textOf(unwrap(em)).trim()) { ok = true; await collectEdited(jid, sender, origId, em, null); }
        info.hasText = ok;
      }
    }
  } catch (e) { info.err = String(e.message || e).slice(0, 80); }
  await diag(jid, 'secretedit', info);
  if (!ok) {
    // the edit could not be read: the old figure is no longer trusted, so it is withdrawn and the sender is asked to send a fresh message
    await db.rpc('fn_wa_collect_retract', { p_group_jid: jid, p_msg_id: origId, p_sender: sender });
    await collectReply(jid, sender, { text: '⚠ An edited message cannot be read by the system, so your earlier figure was withdrawn.\n\nPlease send the corrected report as a NEW message (do not edit) in the same format as shared.' }, null);
  }
}
const unwrap = (msg) => { try { return (baileys.normalizeMessageContent ? baileys.normalizeMessageContent(msg) : msg) || msg; } catch { return msg; } };
// An edited message replaces what the sender sent before: the database re-reads the new text for that sender.
async function collectEdited(jid, sender, origId, editedMsg, ctx2) {
  try {
    const em = unwrap(editedMsg?.message || editedMsg);
    const newText = textOf(em).trim();
    if (!newText) return;
    const editId = origId + '#e' + crypto.createHash('sha1').update(newText).digest('hex').slice(0, 10);   // same edit seen twice = processed once
    const { data, error } = await db.rpc('fn_wa_collect_edit', {
      p_group_jid: jid, p_orig_msg_id: origId, p_edit_id: editId, p_sender: sender, p_text: newText,
      p_quoted: ctx2?.quotedMessage ? textOf(ctx2.quotedMessage) : null });
    log.info({ origId, ok: !error, replied: !!data }, 'collect edit');
    if (error) { log.warn(error, 'collect edit failed'); return; }
    if (data && connected) await collectReply(jid, sender, { text: data }, null);
  } catch (e) { log.warn(e, 'collect edit crashed'); }
}
async function collectIncoming(m) {
  try {
    // newer WhatsApp versions may hide the number behind an @lid id; prefer the real phone-number id when Baileys provides it
    const sender = (m.key.participantPn || m.key.participantAlt || m.key.participant || m.participant || '').split('@')[0].split(':')[0];
    // deleted / edited messages: keep the pending list in step with what the sender now shows in the group
    // newer WhatsApp wraps edits (editedMessage -> message -> protocolMessage); unwrap everything first
    const mc = unwrap(m.message);
    const sec = m.message?.messageContextInfo?.messageSecret || mc?.messageContextInfo?.messageSecret;
    if (sec && m.key.id) {                                                         // remembered so a later (encrypted) edit can be opened
      secrets[m.key.id] = { s: Buffer.from(sec).toString('hex'), p: [m.key.participantPn, m.key.participantAlt, m.key.participant, m.participant].filter(Boolean), t: Date.now() };
      secretsDirty = true;
    }
    const sem = m.message?.secretEncryptedMessage || mc?.secretEncryptedMessage;
    if (sem) { await collectSecretEdit(m, sem, sender); return; }
    const pm = mc?.protocolMessage || m.message?.editedMessage?.message?.protocolMessage;
    if (pm) { log.info({ type: pm.type, hasEdit: !!pm.editedMessage }, 'collect: protocol message (edit/delete)'); if (pm.type !== 0 && pm.type !== 'REVOKE') await diag(m.key.remoteJid, 'protocol', { type: pm.type, pm }); }
    if (pm) {
      const origId = pm.key?.id;
      if (!origId) return;
      if (pm.type === 0 || pm.type === 'REVOKE') {
        const { error } = await db.rpc('fn_wa_collect_retract', { p_group_jid: m.key.remoteJid, p_msg_id: origId, p_sender: sender });
        if (error) log.warn(error, 'collect retract failed');
      } else if (pm.type === 14 || pm.type === 'MESSAGE_EDIT' || pm.editedMessage) {
        await collectEdited(m.key.remoteJid, sender, origId, pm.editedMessage, pm.editedMessage?.extendedTextMessage?.contextInfo);
      }
      return;
    }
    const text = textOf(mc).trim();
    if (!text) { log.info({ kinds: Object.keys(m.message || {}), unwrapped: Object.keys(mc || {}) }, 'collect: group message without text (ignored)'); await diag(m.key.remoteJid, 'notext', m.message); return; }
    const ctx = mc?.extendedTextMessage?.contextInfo;
    const quoted = ctx?.quotedMessage ? textOf(ctx.quotedMessage) : null;
    const { data, error } = await db.rpc('fn_wa_collect_ingest', {
      p_group_jid: m.key.remoteJid, p_sender: sender, p_msg_id: m.key.id, p_text: text, p_quoted: quoted });
    if (error) { log.warn(error, 'collect ingest failed'); return; }
    if (data && connected) await collectReply(m.key.remoteJid, sender, { text: data }, { quoted: m });
  } catch (e) { log.warn(e, 'collect incoming failed'); }
}
// Auto-replies are optional and low volume: the database must grant each one (counts toward the shared daily limit,
// per-day / per-person / per-group cool-down limits, reserve kept for the 4 pm reports). Refused replies are simply skipped.
async function collectReply(jid, sender, content, opts) {
  try {
    const { data: ok, error } = await db.rpc('fn_wa_collect_reserve_send', { p_kind: 'reply', p_group: jid, p_sender: sender || null });
    if (error || !ok) { if (error) log.warn(error, 'collect reserve failed'); return; }
    await new Promise(r => setTimeout(r, 4000 + Math.random() * 8000));
    if (connected) await sock.sendMessage(jid, content, opts || undefined);
  } catch (e) { log.warn(e, 'collect reply failed'); }
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
      if (u.update?.message && (u.key?.remoteJid || '').endsWith('@g.us') && !u.key?.fromMe) { log.info({ keys: Object.keys(u.update.message) }, 'collect: group message update'); await diag(u.key.remoteJid, 'update', { key: u.key, update: u.update }); }
      const ed = u.update?.message?.editedMessage;
      if (ed && !u.key?.fromMe && (u.key?.remoteJid || '').endsWith('@g.us')) {
        const snd = (u.key.participantPn || u.key.participantAlt || u.key.participant || '').split('@')[0].split(':')[0];
        await collectEdited(u.key.remoteJid, snd, u.key.id, ed, null);
      }
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
