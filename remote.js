/**
 * Network half of the LAN KVM bundle.
 *
 * The browser never talks to the Windows agent directly: every request goes
 * through these helpers on the Host so the token stays out of page URLs and
 * the page works even when the browser would block a private-network fetch.
 * @module dsh-lan-kvm/remote
 */

const DEFAULT_PORT = 7681;
const MAX_IMAGE_BYTES = 64 * 1024 * 1024;

/**
 * Normalize a user-entered Windows target.
 * @param {{host?: unknown, port?: unknown, token?: unknown}} input
 * @returns {{host: string, port: number, token: string}}
 */
export function normalizeTarget(input) {
  let host = String(input?.host ?? '').trim();
  host = host.replace(/^https?:\/\//i, '').replace(/\/.*$/, '').replace(/:\d+$/, '');
  if (host === '') throw new Error('Windows address is required, for example 192.168.1.20');
  if (host.length > 253 || !/^[A-Za-z0-9][A-Za-z0-9.-]*$/.test(host)) {
    throw new Error('Windows address must be an IPv4 address or hostname, without http:// or a path');
  }
  const port = input?.port === undefined || input?.port === '' ? DEFAULT_PORT : Number(input.port);
  if (!Number.isInteger(port) || port < 1024 || port > 65535) {
    throw new Error('Port must be an integer from 1024 to 65535');
  }
  const token = String(input?.token ?? '').trim();
  if (token.length < 6 || token.length > 256) {
    throw new Error('Token is required; copy it from the agent window');
  }
  return { host, port, token };
}

/**
 * @param {{host: string, port: number}} target
 * @param {string} path
 */
export function targetUrl(target, path) {
  return `http://${target.host}:${target.port}${path}`;
}

/**
 * One bounded request to the Windows agent.
 * @param {{host: string, port: number, token: string}} target
 * @param {string} path
 * @param {RequestInit & {timeoutMs?: number}} [options]
 */
async function request(target, path, options = {}) {
  const controller = new AbortController();
  const timeoutMs = Number(options.timeoutMs ?? 5000);
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(targetUrl(target, path), {
      ...options,
      redirect: 'error',
      signal: controller.signal,
      headers: {
        accept: 'application/json, image/jpeg, text/plain',
        'x-kvm-token': target.token,
        ...(options.headers ?? {}),
      },
    });
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`Windows agent did not answer within ${Math.round(timeoutMs / 1000)}s`);
    }
    const code = error?.cause?.code ?? error?.code ?? '';
    if (code === 'ECONNREFUSED' || code === 'EHOSTUNREACH' || code === 'ENETUNREACH') {
      throw new Error(`Cannot reach ${target.host}:${target.port}. Is the agent running and the firewall open?`);
    }
    throw new Error(`Network error reaching ${target.host}:${target.port}: ${error?.message ?? error}`);
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Validate the agent and read its virtual-screen geometry.
 * @param {{host: string, port: number, token: string}} target
 */
export async function probeRemote(target) {
  const startedAt = Date.now();
  const response = await request(target, '/api/ping', { method: 'GET', timeoutMs: 4000 });
  if (!response.ok) {
    const text = await response.text();
    if (response.status === 401) throw new Error('The token was rejected by the Windows agent');
    throw new Error(text.slice(0, 300) || `Windows agent returned HTTP ${response.status}`);
  }
  const payload = await response.json();
  if (payload?.ok !== true) throw new Error(payload?.error ?? 'Windows agent returned an invalid response');
  return { ...payload, latencyMs: Date.now() - startedAt };
}

/**
 * Fetch one screenshot as JPEG bytes.
 * @param {{host: string, port: number, token: string}} target
 */
export async function captureRemote(target) {
  const response = await request(target, '/api/shot', { method: 'GET', timeoutMs: 7000 });
  if (!response.ok) {
    const text = await response.text();
    throw new Error(text.slice(0, 300) || `Screenshot failed with HTTP ${response.status}`);
  }
  const contentType = response.headers.get('content-type') ?? 'image/jpeg';
  if (!contentType.startsWith('image/')) throw new Error(`Unexpected screenshot type: ${contentType}`);
  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.byteLength === 0) throw new Error('Windows agent returned an empty screenshot');
  if (bytes.byteLength > MAX_IMAGE_BYTES) throw new Error('Screenshot is too large');
  return { bytes, contentType };
}

/**
 * Send one input command. `input` is forwarded as-is to the agent.
 * @param {{host: string, port: number, token: string}} target
 * @param {Record<string, unknown>} input
 */
export async function inputRemote(target, input) {
  const body = JSON.stringify(input);
  const response = await request(target, '/api/input', {
    method: 'POST',
    timeoutMs: 4000,
    headers: { 'content-type': 'application/json' },
    body,
  });
  const text = await response.text();
  let payload = {};
  try {
    payload = text === '' ? {} : JSON.parse(text);
  } catch {
    throw new Error(text.slice(0, 300) || `Input failed with HTTP ${response.status}`);
  }
  if (!response.ok || payload?.ok === false) {
    throw new Error(payload?.error ?? `Input failed with HTTP ${response.status}`);
  }
  return payload;
}


/**
 * Read the Windows clipboard. `since` is the last clipboard sequence number
 * the Host saw; the agent answers unchanged without resending the payload.
 * `timeoutMs` should scale with the payload the agent may return.
 * @param {{host: string, port: number, token: string}} target
 * @param {number} since
 * @param {number} [timeoutMs]
 */
export async function readClipboard(target, since = 0, timeoutMs = 8000) {
  const response = await request(target, `/api/clipboard?since=${encodeURIComponent(String(since))}`, {
    method: 'GET',
    timeoutMs,
  });
  const text = await response.text();
  let payload;
  try {
    payload = text === '' ? {} : JSON.parse(text);
  } catch {
    throw new Error(text.slice(0, 300) || `Clipboard read failed with HTTP ${response.status}`);
  }
  if (!response.ok || payload?.ok === false) {
    throw new Error(payload?.error ?? `Clipboard read failed with HTTP ${response.status}`);
  }
  return payload;
}

/**
 * Write text or a PNG image to the Windows clipboard.
 * `timeoutMs` should scale with the payload being uploaded.
 * @param {{host: string, port: number, token: string}} target
 * @param {{kind: 'text'|'image', text?: string, image?: string}} payload
 * @param {number} [timeoutMs]
 */
export async function writeClipboard(target, payload, timeoutMs = 12000) {
  const response = await request(target, '/api/clipboard', {
    method: 'POST',
    timeoutMs,
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const text = await response.text();
  let result;
  try {
    result = text === '' ? {} : JSON.parse(text);
  } catch {
    throw new Error(text.slice(0, 300) || `Clipboard write failed with HTTP ${response.status}`);
  }
  if (!response.ok || result?.ok === false) {
    throw new Error(result?.error ?? `Clipboard write failed with HTTP ${response.status}`);
  }
  return result;
}
