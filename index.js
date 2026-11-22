/**
 * LAN KVM - Host half.
 *
 * The Windows agent receives input over HTTP. This Host owns the macOS global
 * input helper: it compiles and spawns the helper, forwards its JSON event
 * stream to Windows in small batches, and exposes same-origin status/control
 * routes to the sidebar panel. No screen capture is involved.
 * @module @local/dsh-lan-kvm
 */
import { execFile, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import net from 'node:net';
import { access, mkdir, readFile, rename, stat, unlink } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { promisify } from 'node:util';
import { fileURLToPath } from 'node:url';
import { normalizeTarget, probeRemote, captureRemote, inputRemote, readClipboard, writeClipboard } from './remote.js';

const execFileAsync = promisify(execFile);
const API_PREFIX = '/lan-kvm/api';
const BODY_LIMIT = 256 * 1024;
const ALLOWED_OPS = new Set(['move', 'moveRel', 'click', 'down', 'up', 'wheel', 'key', 'text', 'batch']);
const HERE = path.dirname(fileURLToPath(import.meta.url));
const AGENT_PATH = path.join(HERE, 'win-agent.ps1');
const HELPER_SOURCE = path.join(HERE, 'mac-helper.swift');
const SUPPORT_DIR = path.join(os.homedir(), 'Library', 'Application Support', 'dsh-lan-kvm');
const HELPER_BIN = process.env.DSH_LAN_KVM_HELPER || path.join(SUPPORT_DIR, 'bin', 'dsh-lan-kvm-helper');
const ACCESSIBILITY_URL = 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility';
const INPUT_MONITORING_URL = 'x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent';
const HOTKEY_LABEL = 'Control+Option+Command+K';
const FLUSH_INTERVAL_MS = 4;
/**
 * Clipboard payload defaults. These are deliberately generous: the relay runs
 * on a trusted LAN, and the Windows agent is the only peer. They stay tunable
 * through the plugin config row (`clipboard.textLimitBytes` and
 * `clipboard.imageLimitBytes`).
 */
const DEFAULT_CLIPBOARD_TEXT_LIMIT = 32 * 1024 * 1024;
const DEFAULT_CLIPBOARD_IMAGE_LIMIT = 64 * 1024 * 1024;
/** Total bytes allowed across one file-copy payload. */
const DEFAULT_CLIPBOARD_FILE_LIMIT = 128 * 1024 * 1024;
/** Base64 inflates by ~4/3, plus the JSON envelope around it. */
const CLIPBOARD_WIRE_FACTOR = 1.4;
/** Helper stdout carries whole clipboard payloads, so its line buffer is large. */
const HELPER_BUFFER_LIMIT = 192 * 1024 * 1024;
const MAX_BATCH_EVENTS = 256;
const MAX_QUEUED_EVENTS = 1200;

/** One shared build promise so simultaneous starts cannot race the compiler. */
let helperBuildPromise = null;
/** Last few stderr lines of the helper, for diagnostics. */
let helperStderr = '';

/**
 * @param {unknown} error
 */
function messageOf(error) {
  return error instanceof Error ? error.message : String(error);
}

/**
 * @param {import('node:http').ServerResponse} res
 * @param {number} status
 * @param {unknown} payload
 */
function sendJson(res, status, payload) {
  const text = JSON.stringify(payload);
  res.statusCode = status;
  res.setHeader('content-type', 'application/json; charset=utf-8');
  res.setHeader('cache-control', 'no-store');
  res.end(text);
}

/**
 * @param {import('node:http').IncomingMessage} req
 */
async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.byteLength;
    if (size > BODY_LIMIT) throw new Error('request body too large');
    chunks.push(chunk);
  }
  if (size === 0) return {};
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

/**
 * @param {import('node:http').IncomingMessage} req
 */
function targetFromQuery(req) {
  const url = new URL(req.url ?? '/', 'http://localhost');
  return normalizeTarget({
    host: url.searchParams.get('host') ?? '',
    port: url.searchParams.get('port') ?? '',
    token: url.searchParams.get('token') ?? '',
  });
}

/**
 * @param {import('node:http').IncomingMessage} req
 */
function targetFromBody(body) {
  return normalizeTarget({
    host: body?.host ?? '',
    port: body?.port ?? '',
    token: body?.token ?? '',
  });
}

/**
 * Local IPv4 addresses of this Mac, for the setup card.
 */
function localAddresses() {
  const entries = Object.values(os.networkInterfaces()).flat();
  return entries
    .filter((entry) => entry !== undefined && entry.family === 'IPv4' && entry.internal === false)
    .map((entry) => entry.address);
}

/**
 * @param {string} address
 */
function ipv4ToInt(address) {
  const parts = address.split('.').map(Number);
  if (parts.length !== 4 || parts.some((part) => !Number.isInteger(part) || part < 0 || part > 255)) return null;
  return (((parts[0] * 256 + parts[1]) * 256 + parts[2]) * 256 + parts[3]) >>> 0;
}

/**
 * @param {number} value
 */
function intToIpv4(value) {
  return [value >>> 24, (value >>> 16) & 255, (value >>> 8) & 255, value & 255].join('.');
}

/**
 * One /24 around each active LAN interface. A /16 (or larger) is deliberately
 * reduced to the local /24 so a scan cannot turn into a huge internet sweep.
 */
function scanTargets() {
  const addresses = new Set();
  const subnets = new Set();
  for (const entries of Object.values(os.networkInterfaces())) {
    for (const entry of entries ?? []) {
      if (entry.family !== 'IPv4' || entry.internal) continue;
      if (entry.address.startsWith('127.') || entry.address.startsWith('169.254.')) continue;
      const address = ipv4ToInt(entry.address);
      if (address === null) continue;
      const base = address & 0xffffff00;
      const network = intToIpv4(base);
      subnets.add(`${network}/24`);
      for (let host = 1; host <= 254; host += 1) {
        const candidate = base + host;
        if (candidate === address) continue;
        addresses.add(intToIpv4(candidate));
      }
    }
  }
  return { addresses: [...addresses].slice(0, 512), subnets: [...subnets] };
}

/**
 * @param {string} url
 * @param {number} timeoutMs
 */
async function fetchShort(url, timeoutMs) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, {
      method: 'GET',
      redirect: 'error',
      signal: controller.signal,
      headers: { accept: 'application/json' },
    });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Identify one LAN host, accepting both the new unauthenticated /api/hello
 * endpoint and older agents that answer 401 on /api/ping.
 * @param {string} host
 * @param {number} port
 */
async function identifyHost(host, port) {
  const base = `http://${host}:${port}`;
  try {
    const response = await fetchShort(`${base}/api/hello`, 450);
    if (response.ok) {
      const payload = await response.json().catch(() => null);
      if (payload?.agent === 'dsh-lan-kvm' || payload?.agent === 'lankvm') {
        return {
          host,
          machine: typeof payload.machine === 'string' ? payload.machine : null,
          version: payload.version ?? null,
          legacy: false,
        };
      }
    }
  } catch {
    // Fall through to the older /api/ping probe.
  }
  try {
    const response = await fetchShort(`${base}/api/ping`, 450);
    if (response.ok) {
      const payload = await response.json().catch(() => null);
      if (payload?.agent === 'dsh-lan-kvm' || payload?.agent === 'lankvm' || payload?.ok === true) {
        return {
          host,
          machine: typeof payload.machine === 'string' ? payload.machine : null,
          version: payload.version ?? null,
          legacy: false,
        };
      }
    }
    if (response.status === 401 || response.status === 403) {
      return { host, machine: null, version: null, legacy: true };
    }
  } catch {
    // Host is offline, firewalled, or not running an agent.
  }
  return null;
}

/**
 * Scan the local /24(s) for DSH LAN KVM agents.
 * @param {number} port
 */
async function scanLan(port) {
  const { addresses, subnets } = scanTargets();
  const found = [];
  let cursor = 0;
  const worker = async () => {
    for (;;) {
      const index = cursor;
      cursor += 1;
      if (index >= addresses.length) return;
      const hit = await identifyHost(addresses[index], port);
      if (hit !== null) found.push(hit);
    }
  };
  const workers = Array.from({ length: Math.min(40, addresses.length) }, () => worker());
  await Promise.all(workers);
  found.sort((left, right) => (ipv4ToInt(left.host) ?? 0) - (ipv4ToInt(right.host) ?? 0));
  return { found, scanned: addresses.length, subnets };
}

/**
 * Compile the Swift helper on first use. The binary path is stable because the
 * macOS Accessibility grant belongs to that path; do not rebuild it on every
 * start.
 * @returns {Promise<string>}
 */
async function ensureHelperBinary() {
  if (process.env.DSH_LAN_KVM_HELPER) return HELPER_BIN;
  if (helperBuildPromise !== null) return helperBuildPromise;

  helperBuildPromise = (async () => {
    await mkdir(path.dirname(HELPER_BIN), { recursive: true });
    const [sourceStat, binaryStat] = await Promise.all([
      stat(HELPER_SOURCE).catch(() => null),
      stat(HELPER_BIN).catch(() => null),
    ]);
    if (binaryStat !== null && sourceStat !== null && binaryStat.mtimeMs >= sourceStat.mtimeMs) {
      return HELPER_BIN;
    }

    const temporary = `${HELPER_BIN}.tmp-${process.pid}-${Date.now()}`;
    try {
      await execFileAsync(
        'xcrun',
        [
          'swiftc',
          '-O',
          '-swift-version',
          '5',
          '-framework',
          'ApplicationServices',
          '-framework',
          'AppKit',
          '-o',
          temporary,
          HELPER_SOURCE,
        ],
        { timeout: 120000, maxBuffer: 4 * 1024 * 1024 },
      );
      await rename(temporary, HELPER_BIN);
      await execFileAsync('codesign', ['--force', '--sign', '-', HELPER_BIN], {
        timeout: 30000,
        maxBuffer: 1024 * 1024,
      }).catch(() => {});
      return HELPER_BIN;
    } finally {
      await unlink(temporary).catch(() => {});
    }
  })();

  try {
    return await helperBuildPromise;
  } catch (error) {
    helperBuildPromise = null;
    const detail = String(error?.stderr ?? error?.stdout ?? '').trim() || messageOf(error);
    throw new Error(`Could not build the macOS input helper: ${detail.slice(0, 1200)}`);
  }
}

/**
 * @param {string} pathname
 */
async function openSystemSettings(pathname) {
  await execFileAsync('open', [pathname], { timeout: 10000 });
}

/**
 * @param {unknown} value
 */
function normalizeEdge(value) {
  return value === 'left' || value === 'both' || value === 'off' || value === 'right' ? value : 'right';
}

/**
 * @param {import('@deepseek-ai/cordis').Context} ctx
 */
export function apply(ctx, config) {
  const clipboardConfig = config?.clipboard ?? {};
  const clipboardTextLimit = Number.isFinite(Number(clipboardConfig.textLimitBytes))
    ? Math.max(1024, Number(clipboardConfig.textLimitBytes))
    : DEFAULT_CLIPBOARD_TEXT_LIMIT;
  const clipboardImageLimit = Number.isFinite(Number(clipboardConfig.imageLimitBytes))
    ? Math.max(1024, Number(clipboardConfig.imageLimitBytes))
    : DEFAULT_CLIPBOARD_IMAGE_LIMIT;
  const clipboardFileLimit = Number.isFinite(Number(clipboardConfig.fileLimitBytes))
    ? Math.max(1024, Number(clipboardConfig.fileLimitBytes))
    : DEFAULT_CLIPBOARD_FILE_LIMIT;

  let helper = null;
  let helperBuffer = '';
  let helperExitExpected = false;
  let helperState = {
    running: false,
    trusted: false,
    tapInstalled: false,
    active: false,
    pid: null,
    edgeArmed: false,
    helperEdgeMode: null,
    hotkey: HOTKEY_LABEL,
    path: HELPER_BIN,
    error: '',
  };

  /** @type {{host: string, port: number, token: string} | null} */
  let target = null;
  let edgeMode = 'right';
  /** @type {{left: number, top: number, width: number, height: number} | null} */
  let screenInfo = null;
  let lastProbeAt = 0;
  let lastLatencyMs = null;
  let lastProbeError = '';
  let lastInputError = '';
  let probeInFlight = false;
  let pendingActivate = false;

  /** @type {any[]} */
  let inputQueue = [];
  let flushTimer = null;
  let flushing = false;
  let inputFailures = 0;
  /** Persistent raw input socket to the Windows agent (HTTP port + 1). */
  let streamSocket = null;
  let streamReady = false;
  let streamBuffer = '';
  let streamReconnectTimer = null;
  let clipboardEnabled = clipboardConfig.enabled !== false;
  let lastClipboardSkip = '';
  let clipboardTimer = null;
  let clipboardPolling = false;
  let lastClipboardHash = '';
  let lastWindowsSeq = 0;
  let lastClipboardError = '';

  function statusPayload() {
    const trusted = helperState.trusted;
    return {
      ok: true,
      helper: {
        running: helperState.running,
        trusted,
        tapInstalled: helperState.tapInstalled,
        active: helperState.active,
        pid: helperState.pid,
        hotkey: helperState.hotkey,
        path: helperState.path,
        error: helperState.error,
      },
      target: target === null ? null : { host: target.host, port: target.port },
      connected: target !== null,
      pendingActivate,
      edgeMode,
      edgeArmed: helperState.edgeArmed === true,
      helperEdgeMode: helperState.helperEdgeMode,
      stream: streamReady,
      clipboard: clipboardEnabled,
      clipboardTextLimit,
      clipboardImageLimit,
      clipboardFileLimit,
      clipboardSkipped: lastClipboardSkip,
      permissionPending: helperState.running && !trusted,
      latencyMs: lastLatencyMs,
      connectionError: lastProbeError,
      inputError: lastInputError,
      clipboardError: lastClipboardError,
    };
  }

  /**
   * @param {Record<string, unknown>} command
   */
  function sendHelper(command) {
    if (helper === null || helper.stdin.destroyed) return false;
    try {
      helper.stdin.write(`${JSON.stringify(command)}\n`);
      return true;
    } catch (error) {
      helperState.error = `Could not write to the Mac helper: ${messageOf(error)}`;
      return false;
    }
  }

  function scheduleFlush(delay = FLUSH_INTERVAL_MS) {
    if (flushTimer !== null) return;
    flushTimer = setTimeout(() => {
      flushTimer = null;
      void flushInputQueue();
    }, delay);
  }

  /** Allow a slow LAN transfer enough time for a large payload. */
  function clipboardTimeout(payloadBytes) {
    const seconds = 10 + (payloadBytes * CLIPBOARD_WIRE_FACTOR) / (2 * 1024 * 1024);
    return Math.min(180000, Math.max(10000, Math.round(seconds * 1000)));
  }

  function payloadBytes(kind, text, image, files) {
    if (kind === 'text') return Buffer.byteLength(text, 'utf8');
    if (kind === 'files') {
      return (files ?? []).reduce((sum, file) => sum + Math.ceil(String(file?.data ?? '').length * 0.75), 0);
    }
    return Math.ceil(String(image ?? '').length * 0.75);
  }

  function payloadLimit(kind) {
    if (kind === 'text') return clipboardTextLimit;
    if (kind === 'files') return clipboardFileLimit;
    return clipboardImageLimit;
  }

  function reportClipboardSkip(kind, bytes, limit) {
    const noun = kind === 'image' ? 'image' : kind === 'files' ? 'file copy' : 'text';
    lastClipboardSkip = `${noun} is ${(bytes / (1024 * 1024)).toFixed(1)} MB, above the ${(limit / (1024 * 1024)).toFixed(0)} MB limit`;
  }

  function clipboardHash(kind, text, image, files) {
    const hash = createHash('sha256').update(kind);
    if (kind === 'text') hash.update(String(text ?? ''));
    else if (kind === 'files') {
      for (const file of files ?? []) hash.update(`${file?.name ?? ''}\u0000${file?.data ?? ''}`);
    } else hash.update(String(image ?? ''));
    return hash.digest('hex');
  }

  function stopClipboardPolling() {
    if (clipboardTimer !== null) {
      clearTimeout(clipboardTimer);
      clipboardTimer = null;
    }
    clipboardPolling = false;
  }

  function startClipboardPolling() {
    if (!clipboardEnabled || target === null || !helperState.tapInstalled || clipboardTimer !== null) return;
    const tick = async () => {
      clipboardTimer = null;
      if (!clipboardEnabled || target === null || !helperState.tapInstalled) return;
      await pollWindowsClipboard();
      if (clipboardEnabled && target !== null && helperState.tapInstalled) {
        clipboardTimer = setTimeout(tick, 450);
      }
    };
    clipboardTimer = setTimeout(tick, 180);
  }

  async function pollWindowsClipboard() {
    if (!clipboardEnabled || target === null || clipboardPolling) return;
    clipboardPolling = true;
    try {
      const result = await readClipboard(target, lastWindowsSeq, clipboardTimeout(Math.max(clipboardImageLimit, clipboardFileLimit)));
      if (result.seq !== undefined) lastWindowsSeq = Number(result.seq) || lastWindowsSeq;
      if (result.unchanged === true || result.kind === 'none') return;
      let kind = '';
      let text;
      let image;
      let files;
      if (result.kind === 'text' && typeof result.text === 'string' && result.text !== '') {
        kind = 'text';
        text = result.text;
      } else if (result.kind === 'files' && Array.isArray(result.files) && result.files.length > 0) {
        kind = 'files';
        files = result.files;
      } else if (result.kind === 'image' && typeof result.image === 'string' && result.image !== '') {
        kind = 'image';
        image = result.image;
      } else {
        return;
      }
      const bytes = payloadBytes(kind, text, image, files);
      const limit = payloadLimit(kind);
      if (bytes > limit) {
        reportClipboardSkip(kind, bytes, limit);
        return;
      }
      const hash = clipboardHash(kind, text, image, files);
      if (hash === lastClipboardHash) return;
      lastClipboardHash = hash;
      sendHelper({ action: 'clipboardSet', kind, text, image, files });
      lastClipboardSkip = '';
      lastClipboardError = '';
    } catch (error) {
      lastClipboardError = messageOf(error);
    } finally {
      clipboardPolling = false;
    }
  }

  async function primeWindowsClipboard() {
    if (!clipboardEnabled || target === null) return;
    try {
      const result = await readClipboard(target, 0);
      if (result.seq !== undefined) lastWindowsSeq = Number(result.seq) || 0;
      if (result.kind === 'text' || result.kind === 'image' || result.kind === 'files') {
        lastClipboardHash = clipboardHash(result.kind, result.text, result.image, result.files);
      } else {
        lastClipboardHash = '';
      }
      lastClipboardError = '';
    } catch (error) {
      lastClipboardError = messageOf(error);
    }
  }

  function handleMacClipboard(message) {
    if (!clipboardEnabled || target === null) return;
    let kind = '';
    let text;
    let image;
    let files;
    if (message.kind === 'text' && typeof message.text === 'string' && message.text !== '') {
      kind = 'text';
      text = message.text;
    } else if (message.kind === 'files' && Array.isArray(message.files) && message.files.length > 0) {
      kind = 'files';
      files = message.files;
    } else if (message.kind === 'image' && typeof message.image === 'string' && message.image !== '') {
      kind = 'image';
      image = message.image;
    } else {
      return;
    }
    const bytes = payloadBytes(kind, text, image, files);
    const limit = payloadLimit(kind);
    if (bytes > limit) {
      reportClipboardSkip(kind, bytes, limit);
      return;
    }
    const hash = clipboardHash(kind, text, image, files);
    if (hash === lastClipboardHash) return;
    lastClipboardHash = hash;
    writeClipboard(target, { kind, text, image, files }, clipboardTimeout(bytes))
      .then((result) => {
        if (result?.seq !== undefined) lastWindowsSeq = Number(result.seq) || lastWindowsSeq;
        lastClipboardError = '';
      })
      .catch((error) => {
        lastClipboardHash = '';
        lastClipboardError = messageOf(error);
      });
  }

  function closeInputStream() {
    if (streamReconnectTimer !== null) {
      clearTimeout(streamReconnectTimer);
      streamReconnectTimer = null;
    }
    streamReady = false;
    streamBuffer = '';
    if (streamSocket !== null) {
      const socket = streamSocket;
      streamSocket = null;
      try { socket.destroy(); } catch { /* already closed */ }
    }
  }

  function scheduleStreamReconnect() {
    if (target === null || streamReconnectTimer !== null) return;
    streamReconnectTimer = setTimeout(() => {
      streamReconnectTimer = null;
      if (target !== null && streamSocket === null) connectInputStream(target);
    }, 1500);
  }

  function handleStreamLine(line) {
    if (line === '') return;
    let message;
    try { message = JSON.parse(line); } catch { return; }
    if (message?.stream === 1) {
      streamReady = true;
      lastInputError = '';
      return;
    }
    if (message?.ok === false) {
      lastInputError = typeof message.error === 'string' ? message.error : 'Windows input stream error';
      return;
    }
    if (screenInfo !== null && message !== null && typeof message === 'object') {
      const x = Number(message.x);
      const y = Number(message.y);
      if (Number.isFinite(x) && Number.isFinite(y)) {
        sendHelper({
          action: 'cursor',
          x,
          y,
          left: screenInfo.left,
          top: screenInfo.top,
          width: screenInfo.width,
          height: screenInfo.height,
        });
      }
    }
  }

  function connectInputStream(next) {
    closeInputStream();
    const socket = net.createConnection({ host: next.host, port: next.port + 1 });
    streamSocket = socket;
    streamReady = false;
    streamBuffer = '';
    socket.setNoDelay(true);
    socket.setEncoding('utf8');
    socket.on('connect', () => {
      try { socket.write(`TOKEN ${next.token}\n`); } catch { /* error handler follows */ }
    });
    socket.on('data', (chunk) => {
      streamBuffer += chunk;
      for (;;) {
        const newline = streamBuffer.indexOf('\n');
        if (newline < 0) break;
        const line = streamBuffer.slice(0, newline).trim();
        streamBuffer = streamBuffer.slice(newline + 1);
        handleStreamLine(line);
      }
      if (streamBuffer.length > 64 * 1024) streamBuffer = streamBuffer.slice(-64 * 1024);
    });
    socket.on('error', (error) => {
      streamReady = false;
      lastInputError = `Windows input stream: ${messageOf(error)}`;
    });
    socket.on('close', () => {
      streamReady = false;
      if (streamSocket === socket) streamSocket = null;
      if (target !== null) scheduleStreamReconnect();
    });
  }

  async function flushInputQueue() {
    if (flushing || target === null || inputQueue.length === 0) return;
    const events = inputQueue.splice(0, MAX_BATCH_EVENTS);

    if (streamReady && streamSocket !== null) {
      try {
        streamSocket.write(`${JSON.stringify({ op: 'batch', events })}\n`);
        inputFailures = 0;
        lastInputError = '';
      } catch (error) {
        streamReady = false;
        lastInputError = `Windows input stream: ${messageOf(error)}`;
      }
      if (inputQueue.length > 0) scheduleFlush(FLUSH_INTERVAL_MS);
      return;
    }

    flushing = true;
    try {
      const outcome = await inputRemote(target, { op: 'batch', events });
      inputFailures = 0;
      lastInputError = '';
      if (screenInfo !== null && outcome !== null && typeof outcome === 'object') {
        const x = Number(outcome.x);
        const y = Number(outcome.y);
        if (Number.isFinite(x) && Number.isFinite(y)) {
          sendHelper({
            action: 'cursor',
            x,
            y,
            left: screenInfo.left,
            top: screenInfo.top,
            width: screenInfo.width,
            height: screenInfo.height,
          });
        }
      }
    } catch (error) {
      inputFailures += 1;
      lastInputError = messageOf(error);
      if (inputFailures >= 3) {
        pendingActivate = false;
        sendHelper({ action: 'return' });
        helperState.error = `Windows input failed; returned control to this Mac. ${lastInputError}`;
        inputQueue = [];
      }
    } finally {
      flushing = false;
      if (inputQueue.length > 0) scheduleFlush(4);
    }
  }

  /**
   * @param {any} event
   */
  function queueInput(event) {
    if (target === null || event === null || typeof event !== 'object') return;
    if (event.type === 'mouse' && event.kind === 'move') {
      const dx = Number(event.dx);
      const dy = Number(event.dy);
      if (!Number.isFinite(dx) || !Number.isFinite(dy) || (dx === 0 && dy === 0)) return;
      const previous = inputQueue[inputQueue.length - 1];
      if (previous !== undefined && previous.op === 'moveRel') {
        previous.dx += Math.round(dx);
        previous.dy += Math.round(dy);
      } else {
        inputQueue.push({ op: 'moveRel', dx: Math.round(dx), dy: Math.round(dy) });
      }
    } else if (event.type === 'mouse' && (event.kind === 'down' || event.kind === 'up')) {
      inputQueue.push({
        op: event.kind,
        button: event.button === 'right' ? 'right' : event.button === 'middle' ? 'middle' : 'left',
      });
    } else if (event.type === 'key') {
      const vk = Number(event.vk);
      if (!Number.isInteger(vk) || vk <= 0 || vk > 255) return;
      inputQueue.push({ op: 'key', vk, down: event.down === true });
    } else if (event.type === 'wheel') {
      const delta = Number(event.delta);
      if (!Number.isFinite(delta) || delta === 0) return;
      inputQueue.push({
        op: 'wheel',
        delta: Math.max(-1200, Math.min(1200, Math.round(delta))),
        horizontal: event.horizontal === true,
      });
    } else {
      return;
    }

    if (inputQueue.length > MAX_QUEUED_EVENTS) {
      inputQueue.splice(0, inputQueue.length - MAX_QUEUED_EVENTS);
    }
    scheduleFlush(event.type === 'mouse' && event.kind === 'move' ? FLUSH_INTERVAL_MS : 4);
  }

  /**
   * @param {any} message
   */
  function handleHelperMessage(message) {
    if (message === null || typeof message !== 'object') return;
    switch (message.type) {
      case 'hello':
        helperState.pid = Number.isInteger(message.pid) ? message.pid : helperState.pid;
        if (typeof message.hotkey === 'string') helperState.hotkey = message.hotkey;
        break;
      case 'permission':
        helperState.trusted = message.trusted === true;
        if (helperState.trusted) helperState.error = '';
        break;
      case 'ready':
        helperState.tapInstalled = true;
        helperState.trusted = true;
        helperState.error = '';
        sendHelper({ action: 'edge', mode: edgeMode });
        if (screenInfo !== null) sendHelper({ action: 'screen', ...screenInfo });
        sendHelper({
          action: 'clipboard',
          enabled: clipboardEnabled,
          textLimit: clipboardTextLimit,
          imageLimit: clipboardImageLimit,
          fileLimit: clipboardFileLimit,
        });
        if (clipboardEnabled) {
          void primeWindowsClipboard().finally(() => startClipboardPolling());
        }
        if (pendingActivate) {
          sendHelper({ action: 'activate' });
          pendingActivate = false;
        }
        break;
      case 'status':
        helperState.active = message.active === true;
        helperState.trusted = message.trusted === true;
        helperState.tapInstalled = message.tapInstalled === true;
        if (typeof message.hotkey === 'string') helperState.hotkey = message.hotkey;
        break;
      case 'active':
        helperState.active = message.active === true;
        if (!helperState.active) {
          helperState.edgeArmed = false;
          scheduleFlush(0);
        }
        break;
      case 'edgeEnter':
        helperState.edgeArmed = true;
        break;
      case 'edgeReturn':
        helperState.edgeArmed = false;
        break;
      case 'edgeMode':
        helperState.helperEdgeMode = typeof message.mode === 'string' ? message.mode : null;
        break;
      case 'error':
        if (message.code !== 'not-ready') {
          helperState.error = typeof message.message === 'string' ? message.message : 'Mac helper error';
        }
        break;
      case 'clipboard':
        handleMacClipboard(message);
        break;
      case 'clipboardSkipped':
        reportClipboardSkip(
          typeof message.kind === 'string' ? message.kind : 'text',
          Number(message.bytes) || 0,
          Number(message.limit) || clipboardTextLimit,
        );
        break;
      case 'edgeEnter':
        helperState.edgeArmed = true;
        if (screenInfo !== null) {
          const ratio = Math.max(0, Math.min(1, Number(message.ratio) || 0));
          const x = message.side === 'right'
            ? screenInfo.left + 1
            : screenInfo.left + screenInfo.width - 2;
          const y = screenInfo.top + ratio * screenInfo.height;
          inputQueue = [{ op: 'move', x, y }];
          scheduleFlush(0);
        }
        break;
      case 'mouse':
      case 'key':
      case 'wheel':
        if (helperState.active) queueInput(message);
        break;
      default:
        break;
    }
  }

  function handleHelperStdout(chunk) {
    helperBuffer += chunk;
    for (;;) {
      const newline = helperBuffer.indexOf('\n');
      if (newline < 0) break;
      const line = helperBuffer.slice(0, newline).trim();
      helperBuffer = helperBuffer.slice(newline + 1);
      if (line === '') continue;
      try {
        handleHelperMessage(JSON.parse(line));
      } catch {
        // Ignore malformed helper output; stderr carries diagnostics.
      }
    }
    if (helperBuffer.length > HELPER_BUFFER_LIMIT) helperBuffer = helperBuffer.slice(-HELPER_BUFFER_LIMIT);
  }

  function handleHelperStderr(chunk) {
    helperStderr = `${helperStderr}${chunk}`.slice(-8000);
    console.error('dsh-lan-kvm helper:', String(chunk).trim());
  }

  /**
   * @returns {Promise<typeof helperState>}
   */
  async function startHelperProcess() {
    const binary = await ensureHelperBinary();
    helperState.path = binary;
    if (helper !== null && helper.exitCode === null) return helperState;

    helperExitExpected = false;
    helperBuffer = '';
    helperStderr = '';
    helperState = {
      ...helperState,
      running: true,
      trusted: false,
      tapInstalled: false,
      active: false,
      pid: null,
      error: '',
    };

    const child = spawn(binary, [], {
      stdio: ['pipe', 'pipe', 'pipe'],
      env: process.env,
    });
    helper = child;
    helperState.pid = child.pid ?? null;

    child.stdout.setEncoding('utf8');
    child.stdout.on('data', handleHelperStdout);
    child.stderr.setEncoding('utf8');
    child.stderr.on('data', handleHelperStderr);
    child.stdin.on('error', (error) => {
      helperState.error = `Mac helper input closed: ${messageOf(error)}`;
    });
    child.on('error', (error) => {
      helperState.running = false;
      helperState.error = `Could not start the Mac helper: ${messageOf(error)}`;
    });
    child.on('exit', (code, signal) => {
      if (helper === child) helper = null;
      helperState.running = false;
      helperState.active = false;
      helperState.tapInstalled = false;
      pendingActivate = false;
      inputQueue = [];
      stopClipboardPolling();
      if (!helperExitExpected) {
        const detail = helperStderr.trim().split('\n').slice(-3).join(' ');
        helperState.error = `Mac helper stopped (${signal ?? code ?? 'unknown'})${detail === '' ? '' : `: ${detail}`}`;
      } else {
        helperState.error = '';
      }
      helperExitExpected = false;
    });

    return helperState;
  }

  /**
   * Ask the helper to start capturing. Returns immediately: Accessibility
   * permission can take a user action in System Settings.
   * @returns {Promise<typeof helperState>}
   */
  async function activateHelper() {
    pendingActivate = true;
    await startHelperProcess();
    if (helperState.tapInstalled) sendHelper({ action: 'activate' });
    return helperState;
  }

  function deactivateHelper() {
    pendingActivate = false;
    // Keep active=true until the helper reports the transition. Its final
    // events are the modifier key-ups that prevent stuck keys on Windows.
    sendHelper({ action: 'deactivate' });
  }

  function stopHelper() {
    pendingActivate = false;
    inputQueue = [];
    if (flushTimer !== null) {
      clearTimeout(flushTimer);
      flushTimer = null;
    }
    if (helper === null) return;
    helperExitExpected = true;
    const child = helper;
    sendHelper({ action: 'deactivate' });
    sendHelper({ action: 'quit' });
    setTimeout(() => {
      try {
        child.kill('SIGKILL');
      } catch {
        // Already gone.
      }
    }, 600).unref?.();
  }

  /**
   * @param {{host: string, port: number, token: string}} next
   */
  async function connectTarget(next) {
    const info = await probeRemote(next);
    target = next;
    connectInputStream(next);
    if (Number.isFinite(Number(info.left)) && Number.isFinite(Number(info.top))) {
      screenInfo = {
        left: Number(info.left),
        top: Number(info.top),
        width: Number(info.width),
        height: Number(info.height),
      };
      sendHelper({ action: 'screen', ...screenInfo });
    }
    lastProbeAt = Date.now();
    lastLatencyMs = Number.isFinite(Number(info.latencyMs)) ? Number(info.latencyMs) : null;
    lastProbeError = '';
    lastInputError = '';
    inputFailures = 0;
    return info;
  }

  function kickProbe() {
    if (target === null || probeInFlight || Date.now() - lastProbeAt < 8000) return;
    probeInFlight = true;
    const current = target;
    probeRemote(current)
      .then((info) => {
        if (Number.isFinite(Number(info.left)) && Number.isFinite(Number(info.top))) {
          screenInfo = {
            left: Number(info.left),
            top: Number(info.top),
            width: Number(info.width),
            height: Number(info.height),
          };
          sendHelper({ action: 'screen', ...screenInfo });
        }
        lastProbeAt = Date.now();
        lastLatencyMs = Number.isFinite(Number(info.latencyMs)) ? Number(info.latencyMs) : null;
        lastProbeError = '';
      })
      .catch((error) => {
        lastProbeAt = Date.now();
        lastProbeError = messageOf(error);
        if (helperState.active) {
          pendingActivate = false;
          // `return` also disarms edge mode, so the pointer cannot be stuck on
          // a Windows desktop the Host can no longer reach.
          sendHelper({ action: 'return' });
        }
      })
      .finally(() => {
        probeInFlight = false;
      });
  }

  ctx.effect(
    () => () => {
      stopHelper();
      closeInputStream();
      stopClipboardPolling();
      target = null;
    },
    'dsh-lan-kvm: stop macOS helper',
  );

  ctx.inject(['webServer', 'connection'], (scoped) => {
    /**
     * @param {import('node:http').IncomingMessage} req
     * @param {import('node:http').ServerResponse} res
     */
    const rejected = (req, res) => {
      const rejection = scoped.connection?.requestRejection?.(req);
      if (rejection === undefined) return false;
      res.statusCode = rejection;
      res.end();
      return true;
    };

    /**
     * @param {string} routePath
     * @param {(req: import('node:http').IncomingMessage, res: import('node:http').ServerResponse) => Promise<void>} handler
     * @param {string} label
     */
    const route = (routePath, handler, label) => {
      scoped.effect(
        () => scoped.webServer.register({ kind: 'exact', path: routePath, handler }),
        `dsh-lan-kvm: ${label}`,
      );
    };

    /**
     * @param {import('node:http').IncomingMessage} req
     * @param {import('node:http').ServerResponse} res
     * @param {'GET'|'POST'} method
     */
    const methodAllowed = (req, res, method) => {
      if (req.method === method) return true;
      res.statusCode = 405;
      res.setHeader('allow', method);
      res.end();
      return false;
    };

    route(
      `${API_PREFIX}/info`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'GET')) return;
        sendJson(res, 200, {
          version: '0.2.0',
          hostname: os.hostname(),
          addresses: localAddresses(),
          defaultPort: 7681,
          helperPath: HELPER_BIN,
          hotkey: HOTKEY_LABEL,
        });
      },
      'GET info',
    );

    route(
      `${API_PREFIX}/status`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'GET')) return;
        kickProbe();
        sendJson(res, 200, statusPayload());
      },
      'GET status',
    );

    route(
      `${API_PREFIX}/probe`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'GET')) return;
        let parsed;
        try {
          parsed = targetFromQuery(req);
          const info = await probeRemote(parsed);
          sendJson(res, 200, { ...info, target: { host: parsed.host, port: parsed.port } });
        } catch (error) {
          sendJson(res, 400, {
            ok: false,
            error: messageOf(error),
            target: parsed === undefined ? null : { host: parsed.host, port: parsed.port },
          });
        }
      },
      'GET probe',
    );

    route(
      `${API_PREFIX}/clipboard`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        try {
          const body = await readJson(req);
          clipboardEnabled = body?.enabled !== false;
          sendHelper({
            action: 'clipboard',
            enabled: clipboardEnabled,
            textLimit: clipboardTextLimit,
            imageLimit: clipboardImageLimit,
            fileLimit: clipboardFileLimit,
          });
          stopClipboardPolling();
          lastWindowsSeq = 0;
          lastClipboardHash = '';
          if (clipboardEnabled && helperState.tapInstalled) {
            void primeWindowsClipboard().finally(() => startClipboardPolling());
          }
          sendJson(res, 200, statusPayload());
        } catch (error) {
          sendJson(res, 400, { ...statusPayload(), ok: false, error: messageOf(error) });
        }
      },
      'POST clipboard',
    );

    route(
      `${API_PREFIX}/edge`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        try {
          const body = await readJson(req);
          edgeMode = normalizeEdge(body?.mode);
          sendHelper({ action: 'edge', mode: edgeMode });
          sendJson(res, 200, statusPayload());
        } catch (error) {
          sendJson(res, 400, { ...statusPayload(), ok: false, error: messageOf(error) });
        }
      },
      'POST edge',
    );

    route(
      `${API_PREFIX}/scan`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        try {
          const body = await readJson(req);
          const port = body?.port === undefined ? 7681 : Number(body.port);
          if (!Number.isInteger(port) || port < 1024 || port > 65535) {
            throw new Error('Port must be an integer from 1024 to 65535');
          }
          const result = await scanLan(port);
          sendJson(res, 200, { ok: true, ...result });
        } catch (error) {
          sendJson(res, 400, { ok: false, error: messageOf(error) });
        }
      },
      'POST scan',
    );

    route(
      `${API_PREFIX}/start`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        try {
          const body = await readJson(req);
          const next = targetFromBody(body);
          edgeMode = normalizeEdge(body?.edge);
          if (typeof body?.clipboard === 'boolean') clipboardEnabled = body.clipboard;
          const info = await connectTarget(next);
          // In edge mode, connecting must not lock the Mac. Start the helper
          // with its event tap ready and let the pointer crossing activate it.
          pendingActivate = edgeMode === 'off';
          await startHelperProcess();
          sendHelper({ action: 'edge', mode: edgeMode });
          sendHelper({
          action: 'clipboard',
          enabled: clipboardEnabled,
          textLimit: clipboardTextLimit,
          imageLimit: clipboardImageLimit,
          fileLimit: clipboardFileLimit,
        });
          if (clipboardEnabled) {
            void primeWindowsClipboard().finally(() => startClipboardPolling());
          }
          if (pendingActivate && helperState.tapInstalled) {
            sendHelper({ action: 'activate' });
            pendingActivate = false;
          }
          sendJson(res, 200, { ...statusPayload(), info });
        } catch (error) {
          sendJson(res, 400, { ...statusPayload(), ok: false, error: messageOf(error) });
        }
      },
      'POST start',
    );

    route(
      `${API_PREFIX}/activate`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        if (target === null) {
          sendJson(res, 400, { ...statusPayload(), ok: false, error: 'Connect to Windows first' });
          return;
        }
        try {
          pendingActivate = true;
          await startHelperProcess();
          if (helperState.tapInstalled) {
            sendHelper({ action: 'activate' });
            pendingActivate = false;
          }
          sendJson(res, 200, statusPayload());
        } catch (error) {
          sendJson(res, 400, { ...statusPayload(), ok: false, error: messageOf(error) });
        }
      },
      'POST activate',
    );

    route(
      `${API_PREFIX}/return`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        pendingActivate = false;
        sendHelper({ action: 'return' });
        await new Promise((resolve) => setTimeout(resolve, 90));
        sendJson(res, 200, statusPayload());
      },
      'POST return',
    );

    route(
      `${API_PREFIX}/deactivate`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        deactivateHelper();
        await new Promise((resolve) => setTimeout(resolve, 90));
        sendJson(res, 200, statusPayload());
      },
      'POST deactivate',
    );

    route(
      `${API_PREFIX}/stop`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        deactivateHelper();
        await new Promise((resolve) => setTimeout(resolve, 90));
        sendJson(res, 200, statusPayload());
      },
      'POST stop',
    );

    route(
      `${API_PREFIX}/disconnect`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        deactivateHelper();
        // Give the helper enough time to emit its modifier key-ups before the
        // target is cleared; otherwise Windows can keep a modifier latched.
        await new Promise((resolve) => setTimeout(resolve, 120));
        stopHelper();
        closeInputStream();
        stopClipboardPolling();
        await new Promise((resolve) => setTimeout(resolve, 180));
        target = null;
        lastProbeError = '';
        lastInputError = '';
        lastProbeAt = 0;
        lastLatencyMs = null;
        sendJson(res, 200, statusPayload());
      },
      'POST disconnect',
    );

    route(
      `${API_PREFIX}/permissions`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'GET')) return;
        sendJson(res, 200, {
          ok: true,
          helperPath: HELPER_BIN,
          trusted: helperState.trusted,
          tapInstalled: helperState.tapInstalled,
          accessibilityUrl: ACCESSIBILITY_URL,
          inputMonitoringUrl: INPUT_MONITORING_URL,
          stderr: helperStderr.trim().slice(-2000),
        });
      },
      'GET permissions',
    );

    route(
      `${API_PREFIX}/open-accessibility`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        try {
          await openSystemSettings(ACCESSIBILITY_URL);
          sendJson(res, 200, { ok: true });
        } catch (error) {
          sendJson(res, 500, { ok: false, error: messageOf(error) });
        }
      },
      'POST open-accessibility',
    );

    route(
      `${API_PREFIX}/open-input-monitoring`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        try {
          await openSystemSettings(INPUT_MONITORING_URL);
          sendJson(res, 200, { ok: true });
        } catch (error) {
          sendJson(res, 500, { ok: false, error: messageOf(error) });
        }
      },
      'POST open-input-monitoring',
    );

    route(
      `${API_PREFIX}/reveal-helper`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        try {
          await ensureHelperBinary();
          await execFileAsync('open', ['-R', HELPER_BIN], { timeout: 10000 });
          sendJson(res, 200, { ok: true, path: HELPER_BIN });
        } catch (error) {
          sendJson(res, 500, { ok: false, error: messageOf(error) });
        }
      },
      'POST reveal-helper',
    );

    route(
      `${API_PREFIX}/shot`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'GET')) return;
        try {
          const parsed = targetFromQuery(req);
          const image = await captureRemote(parsed);
          res.statusCode = 200;
          res.setHeader('content-type', image.contentType);
          res.setHeader('content-length', String(image.bytes.length));
          res.setHeader('cache-control', 'no-store, no-cache, must-revalidate');
          res.setHeader('pragma', 'no-cache');
          res.end(image.bytes);
        } catch (error) {
          res.statusCode = 502;
          res.setHeader('content-type', 'application/json; charset=utf-8');
          res.setHeader('cache-control', 'no-store');
          res.end(JSON.stringify({ ok: false, error: messageOf(error) }));
        }
      },
      'GET shot',
    );

    route(
      `${API_PREFIX}/input`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'POST')) return;
        try {
          const body = await readJson(req);
          const parsed = targetFromBody(body);
          const op = String(body?.op ?? '');
          if (!ALLOWED_OPS.has(op)) throw new Error(`unsupported input op "${op}"`);
          const command = { ...body };
          delete command.host;
          delete command.port;
          delete command.token;
          const outcome = await inputRemote(parsed, command);
          sendJson(res, 200, { ...outcome, ok: true });
        } catch (error) {
          sendJson(res, 400, { ok: false, error: messageOf(error) });
        }
      },
      'POST input',
    );

    route(
      `${API_PREFIX}/agent.ps1`,
      async (req, res) => {
        if (rejected(req, res) || !methodAllowed(req, res, 'GET')) return;
        try {
          const script = await readFile(AGENT_PATH, 'utf8');
          const bytes = Buffer.from(script, 'utf8');
          res.statusCode = 200;
          res.setHeader('content-type', 'text/plain; charset=utf-8');
          res.setHeader('content-disposition', 'attachment; filename="dsh-lan-kvm-agent.ps1"');
          res.setHeader('content-length', String(bytes.length));
          res.setHeader('cache-control', 'no-store');
          res.end(bytes);
        } catch (error) {
          sendJson(res, 500, { ok: false, error: messageOf(error) });
        }
      },
      'GET agent.ps1',
    );
  });
}
