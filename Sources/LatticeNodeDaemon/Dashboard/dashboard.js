// Lattice node dashboard. Served by the node; talks only to the operator API
// with a token (or the loopback cookie) the operator pastes. No dependencies.
'use strict';
(() => {

// ---------------------------------------------------------------- utilities

class Raw { constructor(s) { this.s = s; } toString() { return this.s; } }
const raw = (s) => new Raw(s);
const ESC = { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' };
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ESC[c]);
function part(v) {
  if (v == null || v === false || v === true) return '';
  if (v instanceof Raw) return v.s;
  if (Array.isArray(v)) return v.map(part).join('');
  return esc(v);
}
/** Template literal that escapes every value unless it is raw(). */
function html(strings, ...values) {
  let out = '';
  strings.forEach((s, i) => { out += s; if (i < values.length) out += part(values[i]); });
  return raw(out);
}
const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => [...root.querySelectorAll(sel)];
const store = {
  get(area, key, fallback) {
    try { const v = area.getItem(key); return v == null ? fallback : JSON.parse(v); } catch { return fallback; }
  },
  set(area, key, value) {
    try { if (value == null) area.removeItem(key); else area.setItem(key, JSON.stringify(value)); } catch { /* storage off */ }
  },
};
const local = (() => { try { return window.localStorage; } catch { return null; } })();
const session = (() => { try { return window.sessionStorage; } catch { return null; } })();
const lget = (k, f) => local ? store.get(local, k, f) : f;
const lset = (k, v) => local && store.set(local, k, v);
const sget = (k, f) => session ? store.get(session, k, f) : f;
const sset = (k, v) => session && store.set(session, k, v);

const num = (n) => (n == null || Number.isNaN(n) ? '–' : Number(n).toLocaleString());
function bytes(n) {
  if (n == null) return '–';
  const units = ['bytes', 'KB', 'MB', 'GB', 'TB'];
  let i = 0; let v = Number(n);
  while (v >= 1000 && i < units.length - 1) { v /= 1000; i += 1; }
  return `${i === 0 ? v : v.toFixed(v < 10 ? 1 : 0)} ${units[i]}`;
}
function duration(ms) {
  if (ms == null || !Number.isFinite(ms)) return '–';
  const s = Math.max(0, Math.round(ms / 1000));
  if (s < 60) return `${s} s`;
  const m = Math.round(s / 60);
  if (m < 60) return `${m} min`;
  const h = Math.floor(m / 60);
  if (h < 48) return m % 60 && h < 10 ? `${h} h ${m % 60} min` : `${h} h`;
  return `${Math.round(h / 24)} days`;
}
const ago = (t) => (t ? `${duration(Date.now() - t)} ago` : '–');
const plural = (n, one, many = `${one}s`) => `${num(n)} ${n === 1 ? one : many}`;
const lastSegment = (path) => path.split('/').pop();
const parentOf = (path) => path.split('/').slice(0, -1).join('/');
function shortCid(cid) { return cid && cid.length > 18 ? `${cid.slice(0, 10)}…${cid.slice(-6)}` : cid || ''; }
function cidView(cid) {
  if (!cid) return html`<span class="muted">none</span>`;
  return html`<span class="cid"><span title="${cid}">${shortCid(cid)}</span><button type="button" class="quiet" data-copy="${cid}" aria-label="Copy ${cid}">Copy</button></span>`;
}
const isPlainObject = (v) => v && typeof v === 'object' && !Array.isArray(v);
const clone = (v) => (v === undefined ? undefined : JSON.parse(JSON.stringify(v)));
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
function sortKeys(v) {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (isPlainObject(v)) return Object.fromEntries(Object.keys(v).sort().map((k) => [k, sortKeys(v[k])]));
  return v;
}
const deepEqual = (a, b) => same(sortKeys(a), sortKeys(b));

const ICON = {
  warn: '<svg class="icon warn" viewBox="0 0 20 20" aria-hidden="true"><path d="M10 2.5 18.5 17h-17z" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linejoin="round"/><path d="M10 8v4.2M10 14.6v.1" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg>',
  bad: '<svg class="icon bad" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8" fill="none" stroke="currentColor" stroke-width="1.8"/><path d="m7 7 6 6m0-6-6 6" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg>',
  note: '<svg class="icon" viewBox="0 0 20 20" aria-hidden="true"><circle cx="10" cy="10" r="8" fill="none" stroke="currentColor" stroke-width="1.6"/><path d="M10 9v5M10 6.2v.1" stroke="currentColor" stroke-width="1.9" stroke-linecap="round"/></svg>',
  mark: '<svg width="18" height="18" viewBox="0 0 16 16" aria-hidden="true"><path d="M3 2v12M3 5h5v4M8 9h5" stroke="currentColor" stroke-width="1.8" fill="none" stroke-linecap="round"/></svg>',
};
const LEVEL_WORD = { bad: 'Problem', warn: 'Warning', note: 'Note' };

function toast(message) {
  const box = $('#toast');
  box.innerHTML = '';
  const div = document.createElement('div');
  div.textContent = message;
  box.append(div);
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.innerHTML = ''; }, 3200);
}
async function copy(text) {
  try { await navigator.clipboard.writeText(text); toast('Copied'); } catch { toast('Copy failed: select the text and copy it'); }
}

// ---------------------------------------------------------------- nodes + API

const NODES_KEY = 'lattice.dashboard.nodes';
const SESSION_TOKENS = 'lattice.dashboard.tokens';
const CURRENT_KEY = 'lattice.dashboard.current';
const LOCAL_ID = 'here';

/** The nodes this browser knows. The node that served the page is always
 *  first; the others were added here and are stored on this device only. */
function loadNodes() {
  const saved = lget(NODES_KEY, []);
  const here = saved.find((n) => n.id === LOCAL_ID) || { id: LOCAL_ID, name: location.host, url: '' };
  return [here, ...saved.filter((n) => n.id !== LOCAL_ID)];
}
function saveNodes() {
  lset(NODES_KEY, state.nodes.map((n) => ({ id: n.id, name: n.name, url: n.url, remember: !!n.remember, token: n.remember ? n.token : undefined })));
  sset(SESSION_TOKENS, Object.fromEntries(state.nodes.filter((n) => n.token && !n.remember).map((n) => [n.id, n.token])));
}
function restoreTokens() {
  const sessionTokens = sget(SESSION_TOKENS, {});
  for (const n of state.nodes) if (!n.token && sessionTokens[n.id]) n.token = sessionTokens[n.id];
}
/** A pasted secret: a token, or the cookie file's whole content. */
const cleanToken = (t) => t.trim().replace(/^__cookie__:/, '');

class ApiError extends Error {
  constructor(status, message, body) { super(message); this.status = status; this.body = body; }
}
function apiBase(node) {
  return node.url ? `${node.url.replace(/\/+$/, '')}/` : new URL('.', location.href).href;
}
async function api(node, path, { method = 'GET', body, text = false, contentType = 'application/json', timeout = 12000, accept = [] } = {}) {
  const headers = {};
  if (node.token) headers.Authorization = `Bearer ${node.token}`;
  if (body !== undefined) headers['Content-Type'] = contentType;
  let res;
  try {
    res = await fetch(apiBase(node) + path.replace(/^\//, ''), {
      method, headers, body: body === undefined ? undefined : JSON.stringify(body),
      cache: 'no-store', credentials: 'omit', signal: AbortSignal.timeout(timeout),
    });
  } catch (e) {
    throw new ApiError(0, e && e.name === 'TimeoutError' ? 'The node did not answer in time.' : 'The node could not be reached.');
  }
  const bodyText = await res.text();
  let data = bodyText;
  if (!text) { try { data = bodyText ? JSON.parse(bodyText) : null; } catch { data = bodyText; } }
  if (!res.ok && !accept.includes(res.status)) {
    const message = (data && data.error && (data.error.message || data.error.reason)) || (typeof data === 'string' && data) || res.statusText || `HTTP ${res.status}`;
    throw new ApiError(res.status, message, data);
  }
  return { status: res.status, data };
}
const get = async (node, path, opts) => (await api(node, path, opts)).data;
const q = (path, chain) => (chain && chain !== 'Nexus' ? `${path}${path.includes('?') ? '&' : '?'}chainPath=${encodeURIComponent(chain)}` : path);

// ---------------------------------------------------------------- app state

const state = {
  nodes: [],
  current: LOCAL_ID,
  snaps: {},        // node id -> snapshot
  timers: {},
  failures: {},     // node id -> consecutive failures
  inflight: {},
  route: { name: 'overview', params: {} },
};
const node = (id = state.current) => state.nodes.find((n) => n.id === id);
const snap = (id = state.current) => state.snaps[id] || (state.snaps[id] = blankSnap());
function blankSnap() { return { at: 0, chains: {}, hist: {}, progress: {}, blockTime: {} }; }
const SNAP_KEY = (id) => `lattice.dashboard.snap.${id}`;
function persistSnap(id) {
  const n = node(id); const s = state.snaps[id];
  if (!n || !s) return;
  // The role belongs to the token, not the node: it is asked afresh.
  const keep = { ...s, role: undefined, roleToken: undefined, blockCache: undefined, logCache: undefined, pinsCache: undefined, mineLog: undefined };
  if (n.remember) lset(SNAP_KEY(id), keep); else sset(SNAP_KEY(id), keep);
}
function restoreSnap(id) {
  const n = node(id);
  const s = (n && n.remember ? lget(SNAP_KEY(id), null) : null) || sget(SNAP_KEY(id), null);
  if (s) { s.restored = true; delete s.role; delete s.roleToken; state.snaps[id] = { ...blankSnap(), ...s }; }
}

/** One refresh of everything the overview shows for a node. Last-known
 *  values stay when a read fails; the failure is recorded beside them. */
async function refresh(id) {
  const n = node(id);
  if (!n || !n.token) return;
  if (state.inflight[id]) return state.inflight[id];
  const s = snap(id);
  s.busy = true; paintFreshness();
  const token = n.token;
  const run = (async () => {
    const now = Date.now();
    try {
      const [status, hosted] = await Promise.all([get(n, 'status'), get(n, 'hosted-chains')]);
      s.status = status;
      s.hosted = hosted;
      // A role is the token's: asked again whenever the token changed.
      if (s.roleToken !== token) {
        const role = await detectRole(n);
        if (n.token === token) { s.role = role; s.roleToken = role ? token : undefined; }
      }
      const chains = ['Nexus', ...(hosted.chains || [])];
      const extra = await Promise.allSettled([
        get(n, 'mining'),
        get(n, 'disk'),
        api(n, 'config', { accept: [409] }),
        get(n, 'metrics', { text: true }),
      ]);
      if (extra[0].status === 'fulfilled') s.mining = extra[0].value;
      if (extra[1].status === 'fulfilled') s.disk = extra[1].value;
      if (extra[2].status === 'fulfilled') s.config = extra[2].value.status === 409 ? { flags: true } : extra[2].value.data;
      if (extra[3].status === 'fulfilled') s.metrics = parseMetrics(extra[3].value);
      const per = await Promise.all(chains.map(async (path) => {
        const [health, peers, latest] = await Promise.allSettled([
          path === 'Nexus' ? Promise.resolve(status) : get(n, q('health', path)),
          get(n, q('api/peers', path)),
          get(n, q('api/block/latest', path)),
        ]);
        if (s.blockTime[path] == null) {
          try { const spec = await get(n, q('api/chain/spec', path)); s.blockTime[path] = Number(spec.targetBlockTime); } catch { /* later */ }
        }
        return [path, {
          path,
          health: health.status === 'fulfilled' ? health.value : (s.chains[path] && s.chains[path].health),
          peers: peers.status === 'fulfilled' ? peers.value.count : (s.chains[path] && s.chains[path].peers),
          latest: latest.status === 'fulfilled' ? latest.value : (s.chains[path] && s.chains[path].latest),
          error: health.status === 'rejected' ? health.reason.message : null,
        }];
      }));
      s.chains = Object.fromEntries(per);
      for (const [path, c] of per) record(s, path, c, now);
      s.at = now;
      s.error = null;
      s.restored = false;
      state.failures[id] = 0;
    } catch (e) {
      s.error = { status: e.status, message: e.message, at: now };
      state.failures[id] = (state.failures[id] || 0) + 1;
      if (e.status === 401 && id === state.current && n.token === token) { n.token = null; saveNodes(); signInReason = n.url ? 'That node no longer accepts the saved token. Paste one it knows.' : 'The node no longer accepts that secret. If it restarted, its cookie changed: paste the new one.'; }
    } finally {
      s.busy = false;
      if (state.inflight[id] === run) delete state.inflight[id];
      persistSnap(id);
    }
  })();
  state.inflight[id] = run;
  await run;
  if (id === state.current || state.route.name === 'nodes') paint();
  else paintChrome();
}

/** Remembers each chain's heights over time: the rate, and when it last moved. */
function record(s, path, c, now) {
  const h = c.health;
  if (!h || h.height == null) return;
  const height = Number(h.height);
  const best = Number(h.bestHeaderHeight ?? h.height);
  const hist = (s.hist[path] = (s.hist[path] || []).filter((p) => now - p[0] < 10 * 60e3));
  const last = hist[hist.length - 1];
  if (!last || last[1] !== height || now - last[0] > 20e3) hist.push([now, height, best]);
  const blockTime = c.latest && c.latest.timestamp ? Number(c.latest.timestamp) : 0;
  const p = s.progress[path];
  if (!p || p.height !== height) s.progress[path] = { height, at: p ? now : Math.max(blockTime, now - 1), firstSeen: p ? p.firstSeen : now };
  if (blockTime && blockTime > s.progress[path].at && blockTime <= now) s.progress[path].at = blockTime;
}
function rateOf(s, path) {
  const hist = s.hist[path] || [];
  if (hist.length < 2) return null;
  const now = hist[hist.length - 1];
  const from = hist.find((p) => now[0] - p[0] <= 3 * 60e3) || hist[0];
  const dt = (now[0] - from[0]) / 1000;
  if (dt < 15) return null;
  return (now[1] - from[1]) / dt; // blocks per second
}

/** 'admin' if the token may list tokens, 'limited' if refused (a read or
 *  routes token: which writes it may make, the node says per action), and
 *  undefined when unknown, so the next refresh asks again. */
async function detectRole(n) {
  const r = await api(n, 'tokens', { accept: [403, 404, 409] }).catch(() => ({ status: 0 }));
  if (r.status === 200 || r.status === 409) return 'admin';
  if (r.status === 403) return 'limited';
  return undefined;
}
function parseMetrics(text) {
  const out = {};
  for (const line of String(text).split('\n')) {
    if (line.startsWith('process_start_time_seconds')) out.start = Number(line.split(' ').pop()) * 1000;
    const peers = line.match(/^lattice_overlay_peers\{chain="Nexus"\} (\d+)/);
    if (peers) out.peers = Number(peers[1]);
  }
  return out;
}

function schedule(id) {
  clearTimeout(state.timers[id]);
  const fails = state.failures[id] || 0;
  const base = id === state.current ? 5000 : 15000;
  const wait = Math.min(base * 2 ** fails, 60000);
  state.nodes.find((n) => n.id === id).nextAt = Date.now() + wait;
  state.timers[id] = setTimeout(async () => {
    if (!document.hidden) await refresh(id);
    schedule(id);
  }, wait);
}
function startPolling() {
  for (const n of state.nodes) {
    if (!n.token) continue;
    if (!state.snaps[n.id]) restoreSnap(n.id);
    refresh(n.id).then(() => schedule(n.id));
  }
}
document.addEventListener('visibilitychange', () => { if (!document.hidden && node() && node().token) refresh(state.current); });

// ---------------------------------------------------------------- verdicts

const WAITING = {
  'not obtained from any peer': 'No peer has sent this block yet.',
  "exceeds this node's byte budget": "The block is bigger than this node fetches at once (maxAcquisitionBytes).",
  'local storage failed': 'Writing it to disk failed. Check free space and the log.',
};
function waitingCause(w) {
  if (!w) return null;
  const reason = w.replace(/^body of \S+: /, '');
  if (WAITING[reason]) return WAITING[reason];
  if (reason.startsWith('not connected')) return "It couldn't be connected to the chain yet; the node keeps retrying.";
  return reason;
}

/** One verdict per chain, or null when there is nothing to say. */
function chainVerdict(s, path) {
  const c = s.chains[path];
  const configured = (s.hosted && s.hosted.configured) || [];
  if (!c) {
    if (configured.includes(path)) return { level: 'bad', text: "Didn't start", detail: "It's in the configuration but isn't running. The node log says why." };
    return null;
  }
  const h = c.health;
  if (!h) return { level: 'warn', text: 'No answer for this chain', detail: c.error || '' };
  if (h.phase === 'awaitingGenesis' || h.height == null) {
    const seen = s.genesisWait = s.genesisWait || {};
    seen[path] = seen[path] || s.at || Date.now();
    const waited = (s.at || Date.now()) - seen[path];
    const how = 'A chain added by its path needs a peer that hosts it; a new chain gets its first block from its parent’s miners.';
    if (waited > 3 * 60e3) return { level: 'warn', text: 'Still no first block', detail: `Waiting for ${duration(waited)}${c.peers === 0 ? ' with no peers serving it' : ''}. ${how}` };
    return { level: 'note', text: 'Waiting for its first block', detail: how };
  }
  const now = s.at || Date.now();
  const height = Number(h.height);
  const best = Number(h.bestHeaderHeight ?? h.height);
  const gap = Math.max(0, best - height);
  const p = s.progress[path] || {};
  const still = now - (p.at || now);
  const watched = now - (p.firstSeen || now);
  const rate = rateOf(s, path);
  const blockTime = s.blockTime[path];
  const cause = waitingCause(h.waiting);
  // The mining loop merged-mines every hosted chain, paid or not.
  const minedHere = !!(s.mining && s.mining.running);
  if (gap > 2) {
    if (still > 90e3 && watched > 60e3 && !(rate > 0)) {
      return {
        level: 'bad', text: `Stalled ${plural(gap, 'block')} behind`,
        detail: `No new block for ${duration(still)} while peers are at ${num(best)}. ${cause || (c.peers === 0 ? 'It has no peers to fetch from.' : 'The node keeps asking its peers.')}`,
        gap, best, height,
      };
    }
    if (rate > 0) {
      const eta = gap / rate * 1000;
      return { level: 'note', text: `Syncing: ${plural(gap, 'block')} to go`, detail: `${num(Math.round(rate * 60))} blocks a minute, about ${duration(eta)} left.`, gap, best, height, progress: best ? height / best : 0 };
    }
    return {
      level: 'note', text: `Catching up: ${plural(gap, 'block')} behind`,
      detail: blockTime ? `About ${duration(gap * blockTime)} of blocks. Last progress ${ago(p.at)}.` : `Last progress ${ago(p.at)}.`,
      gap, best, height, progress: best ? height / best : 0,
    };
  }
  if (h.waiting) return { level: 'warn', text: 'Waiting on its next block', detail: cause };
  // When the node has no peers at all, Nexus says so once for every chain.
  const isolated = s.chains.Nexus && s.chains.Nexus.peers === 0;
  if (c.peers === 0 && path !== 'Nexus' && !minedHere && isolated) return { level: 'quiet', text: 'no peers', detail: 'This node has no peers at all; see Nexus.' };
  if (c.peers === 0 && path !== 'Nexus' && !minedHere) {
    return { level: 'warn', text: 'No peers', detail: "No other node is serving this chain to this one, so it won't hear about new blocks." };
  }
  if (c.peers === 0 && path === 'Nexus' && !minedHere) {
    const hosted = ((s.hosted && s.hosted.chains) || []).length;
    return { level: 'warn', text: 'No peers', detail: `This node isn't connected to anyone, so it won't hear about new blocks${hosted ? ` on Nexus or the ${plural(hosted, 'chain')} it hosts` : ''}. Check its peers and network.` };
  }
  if (c.peers === 0) return { level: 'quiet', text: 'only this node', detail: 'No peers serve this chain; this node mines it alone.' };
  return null;
}

/** What the operator should look at, worst first. Empty when all is well. */
function attention(id = state.current) {
  const s = snap(id); const n = node(id);
  const items = [];
  if (s.error && s.error.status !== 401) {
    items.push({ level: 'bad', what: "Can't reach this node", why: `${s.error.message} ${s.at ? `Showing what it said ${ago(s.at)}.` : ''} Retrying ${n.nextAt ? `in ${duration(n.nextAt - Date.now())}` : 'soon'}.`, action: { label: 'Retry now', run: 'retry' } });
  }
  for (const path of chainPaths(s)) {
    const v = chainVerdict(s, path);
    if (v && (v.level === 'bad' || v.level === 'warn')) {
      items.push({ level: v.level, what: `${path}: ${v.text.toLowerCase()}`, why: v.detail, action: { label: 'Open chain', href: `#/chain/${path}` } });
    }
  }
  const m = s.mining;
  if (m && m.enabled && !m.running) {
    items.push({ level: 'warn', what: "Mining is on, but the miner isn't running", why: `${m.lastExit ? `It last stopped with ${m.lastExit}. ` : ''}The node starts it again 5 s after it exits${m.restarts ? `; it has restarted ${plural(m.restarts, 'time')}` : ''}.`, action: { label: 'Miner log', href: '#/logs?file=mine' } });
  } else if (m && m.running && m.restarts > 2) {
    items.push({ level: 'warn', what: `The miner has restarted ${plural(m.restarts, 'time')}`, why: m.lastExit ? `Last exit: ${m.lastExit}.` : '', action: { label: 'Miner log', href: '#/logs?file=mine' } });
  }
  if (s.disk && s.disk.freeBytes != null) {
    const free = s.disk.freeBytes;
    if (free < 1e9) items.push({ level: 'bad', what: `Only ${bytes(free)} of disk left`, why: 'The node stops writing blocks when the disk fills. Free space or keep less history.', action: { label: 'Storage', href: '#/storage' } });
    else if (free < 5e9) items.push({ level: 'warn', what: `Disk is getting full: ${bytes(free)} left`, why: 'Free space, or keep less state history in Settings.', action: { label: 'Storage', href: '#/storage' } });
  }
  return items.sort((a, b) => (a.level === b.level ? 0 : a.level === 'bad' ? -1 : 1));
}
function worst(id) {
  const items = attention(id);
  if (!items.length) return null;
  return items.some((i) => i.level === 'bad') ? 'bad' : 'warn';
}
/** Nexus and every hosted chain, parent before child, plus configured
 *  chains that did not start. */
function chainPaths(s) {
  const set = new Set(['Nexus']);
  for (const c of (s.hosted && s.hosted.chains) || []) set.add(c);
  for (const c of (s.hosted && s.hosted.configured) || []) set.add(c);
  return [...set].sort((a, b) => a.localeCompare(b));
}
const restartKeys = (s) => (s.config && s.config.restartRequired) || [];

// ---------------------------------------------------------------- routing

function parseRoute() {
  let hash;
  try { hash = decodeURIComponent(location.hash.replace(/^#\/?/, '')); } catch { return { name: 'not-found', arg: '', params: {} }; }
  const [pathPart, query = ''] = hash.split('?');
  const params = Object.fromEntries(new URLSearchParams(query));
  const [name, ...rest] = pathPart.split('/');
  return { name: name || 'overview', arg: rest.join('/'), params };
}
window.addEventListener('hashchange', () => { state.route = parseRoute(); leaveLogs(); paint(true); });

const NAV = [
  { name: 'overview', label: 'Overview' },
  { name: 'logs', label: 'Logs' },
  { name: 'mining', label: 'Mining' },
  { name: 'storage', label: 'Storage' },
  { name: 'settings', label: 'Settings' },
  { name: 'access', label: 'Access' },
  { name: 'danger', label: 'Restart and wipe' },
];

// ---------------------------------------------------------------- painting

let signInReason = '';
let dirtyForm = false;

function paint(navigated = false) {
  const n = node();
  if (!n || !n.token) { paintSignIn(); return; }
  if (!$('.shell')) {
    $('#app').innerHTML = shellHTML().s;
  }
  paintChrome();
  const main = $('main');
  const view = VIEWS[state.route.name] || VIEWS.overview;
  const editing = !navigated && (view.form || (main.contains(document.activeElement) && document.activeElement.matches('input, textarea, select')) || $('dialog[open]'));
  if (editing) {
    const slot = $('#restart-slot'); if (slot) slot.innerHTML = part(restartBannerInner());
    if (view.update) view.update();
    return;
  }
  const scroll = navigated ? 0 : window.scrollY;
  main.innerHTML = `<div class="page">${view.render().s}</div>`;
  applyWidths(main);
  if (view.mount) view.mount(main);
  if (navigated) { window.scrollTo(0, 0); const h = $('h1', main); if (h) { h.tabIndex = -1; h.focus({ preventScroll: true }); } } else window.scrollTo(0, scroll);
}
function applyWidths(root) { for (const el of $$('[data-w]', root)) el.style.width = el.dataset.w; }

function shellHTML() {
  return html`<div class="shell">
    <aside class="rail" aria-label="Node"></aside>
    <div class="col">
      <header class="topbar"></header>
      <main id="main" tabindex="-1"></main>
    </div>
  </div>`;
}

function paintChrome() {
  if (!$('.shell')) return;
  const rail = $('.rail'); const top = $('.topbar');
  if (!rail.contains(document.activeElement)) rail.innerHTML = railHTML().s;
  if (!top.contains(document.activeElement)) top.innerHTML = topHTML().s;
  paintFreshness();
}
function navLinks(mobile) {
  const s = snap(); const route = state.route.name === 'chain' ? 'overview' : state.route.name;
  const w = worst(state.current);
  return NAV.map((item) => {
    let badge = '';
    if (item.name === 'overview' && w) badge = html`<span class="flag ${w === 'bad' ? 'bad' : ''}" aria-hidden="true"></span><span class="visually-hidden">(needs attention)</span>`;
    if (item.name === 'settings' && restartKeys(s).length) badge = html`<span class="flag" aria-hidden="true"></span><span class="visually-hidden">(restart needed)</span>`;
    return html`<a href="#/${item.name === 'overview' ? '' : item.name}" ${raw(route === item.name ? 'aria-current="page"' : '')}>${item.label}${mobile ? badge : html`<span>${badge}</span>`}</a>`;
  });
}
function switcherHTML(id) {
  if (state.nodes.length < 2) return '';
  return html`<label for="${id}" class="visually-hidden">Node</label>
    <select id="${id}" data-switch>${state.nodes.map((n) => html`<option value="${n.id}" ${raw(n.id === state.current ? 'selected' : '')}>${n.name}${worst(n.id) ? ' (needs attention)' : ''}</option>`)}</select>`;
}
function railHTML() {
  const fleet = state.nodes.length > 1;
  return html`<div class="brand">${raw(ICON.mark)} Lattice</div>
    ${fleet ? html`<div class="switcher">${switcherHTML('switch-rail')}<a class="small" href="#/nodes">All nodes</a></div>` : html`<div class="node-label">${node().name}</div>`}
    <nav class="nav" aria-label="Sections">${navLinks(false)}</nav>
    <div class="rail-foot">
      <span id="fresh-rail"></span>
      ${fleet ? '' : html`<a href="#/nodes">Add another node</a>`}
      <button type="button" class="quiet small" data-signout>Sign out</button>
      ${fleet ? html`<button type="button" class="quiet small" data-signout-all>Sign out of all nodes</button>` : ''}
    </div>`;
}
function topHTML() {
  return html`<div class="brand-line"><span class="brand">${raw(ICON.mark)} ${state.nodes.length > 1 ? '' : node().name}</span>${switcherHTML('switch-top')}<span id="fresh-top"></span></div>
    <nav aria-label="Sections">${navLinks(true)}${state.nodes.length > 1 ? html`<a href="#/nodes" ${raw(state.route.name === 'nodes' ? 'aria-current="page"' : '')}>All nodes</a>` : ''}</nav>`;
}
function freshnessHTML() {
  const s = snap();
  if (s.error && s.at) return html`<span class="fresh stale"><span class="dot"></span>Offline: last heard ${ago(s.at)}</span>`;
  if (s.error) return html`<span class="fresh stale"><span class="dot"></span>Not reachable</span>`;
  if (s.busy && (!s.at || s.restored)) return html`<span class="fresh busy"><span class="dot"></span>Updating…</span>`;
  if (!s.at) return html`<span class="fresh busy"><span class="dot"></span>Loading…</span>`;
  return html`<span class="fresh ${s.busy ? 'busy' : ''}"><span class="dot"></span>Updated ${ago(s.at)}</span>`;
}
function paintFreshness() {
  for (const id of ['fresh-rail', 'fresh-top']) { const el = document.getElementById(id); if (el) el.innerHTML = freshnessHTML().s; }
}
setInterval(paintFreshness, 1000);

/** The restart banner, shown on every page while a written key waits. */
function restartBanner() {
  return html`<div id="restart-slot">${restartBannerInner()}</div>`;
}
function restartBannerInner() {
  const keys = restartKeys(snap());
  if (!keys.length) return '';
  return html`<div class="banner" role="status">
    ${raw(ICON.warn)}
    <div class="grow"><strong>Restart needed.</strong> ${keys.length === 1 ? 'One saved setting applies' : `${keys.length} saved settings apply`} only after the node restarts: ${keys.join(', ')}.</div>
    <button type="button" class="primary" data-restart>Restart now</button>
  </div>`;
}

// ---------------------------------------------------------------- sign in

function paintSignIn() {
  const n = node();
  const remote = !!n.url;
  $('#app').innerHTML = html`<div class="signin"><form id="signin" autocomplete="off">
    <div class="brand">${raw(ICON.mark)} Lattice node</div>
    <div>
      <h1>Sign in to ${n.name}</h1>
      <p class="soft mt-1">Paste an operator token. It stays in this tab unless you ask this browser to remember it, and is only ever sent to this node.</p>
    </div>
    ${signInReason ? html`<p class="error" role="alert">${signInReason}</p>` : ''}
    <div class="field"><label for="token" class="label-line">Token</label>
      <input id="token" type="password" required spellcheck="false" autocapitalize="off" placeholder="64 hexadecimal characters">
    </div>
    <label class="check"><input type="checkbox" id="remember" ${raw(n.remember ? 'checked' : '')}> Remember on this device</label>
    <div class="inline"><button class="primary" type="submit">Sign in</button>${state.nodes.length > 1 ? html`<button type="button" class="quiet" data-goto-fleet>Other nodes</button>` : ''}</div>
    <details><summary>Where do I get a token?</summary>
      <p class="mt-2">On the node's machine, make one (an admin token can change settings; a read token can only look):</p>
      <pre class="cmd">lattice tokens create dashboard --role admin --root &lt;root&gt;</pre>
      ${remote ? '' : html`<p class="mt-2">On the node's own loopback port you can paste its cookie instead. It changes every time the node restarts:</p>
      <pre class="cmd">cat &lt;root&gt;/chains/Nexus/.cookie</pre>`}
    </details>
  </form></div>`.s;
  $('#token').focus();
}

async function signIn(token, remember) {
  const n = node();
  n.token = cleanToken(token);
  try {
    await get(n, 'status');
  } catch (e) {
    n.token = null;
    signInReason = e.status === 401 ? "This node doesn't know that token." :
      e.status === 403 ? 'That token may not read this node’s status. Use an admin or read token.' :
      `${e.message} Check the address and that the node is running.`;
    paintSignIn();
    return;
  }
  n.remember = remember;
  signInReason = '';
  saveNodes();
  state.snaps[n.id] = state.snaps[n.id] || blankSnap();
  restoreSnap(n.id);
  snap().role = undefined;
  delete state.inflight[n.id]; // a read begun with the previous token
  $('#app').innerHTML = '';
  paint(true);
  refresh(n.id).then(() => schedule(n.id));
}
/** Every token, snapshot and setting this page stored, in both stores. */
function signOutAll() {
  for (const id of Object.keys(state.timers)) clearTimeout(state.timers[id]);
  for (const area of [local, session]) {
    if (!area) continue;
    try {
      for (const key of Object.keys(area)) if (key.startsWith('lattice.dashboard.')) area.removeItem(key);
    } catch { /* storage off */ }
  }
  state.nodes = loadNodes();
  state.snaps = {}; state.timers = {}; state.failures = {};
  state.current = LOCAL_ID;
  $('#app').innerHTML = '';
  location.hash = '#/';
  paint(true);
}
function signOut() {
  const n = node();
  n.token = null; n.remember = false;
  store.set(local, SNAP_KEY(n.id), null); sset(SNAP_KEY(n.id), null);
  clearTimeout(state.timers[n.id]);
  saveNodes();
  $('#app').innerHTML = '';
  paint(true);
}

// ---------------------------------------------------------------- views

const VIEWS = {};

// Overview -------------------------------------------------------------

VIEWS.overview = {
  render() {
    const s = snap(); const n = node();
    const items = attention();
    return html`
      <div class="page-head"><div class="titles"><h1>${n.name}</h1>${vitalsHTML(s)}</div></div>
      ${restartBanner()}
      ${items.length ? html`<section class="attention" aria-labelledby="att-h"><h2 id="att-h">Needs attention</h2>${items.map(issueHTML)}</section>` : ''}
      <section aria-labelledby="chains-h">
        <div class="section-head"><h2 id="chains-h">Chains</h2><a class="small" href="#/settings?focus=chains">Host another chain</a></div>
        ${s.status ? treeHTML(s) : html`<p class="empty">Reading the node…</p>`}
      </section>`;
  },
};
function vitalsHTML(s) {
  const peers = s.metrics && s.metrics.peers != null ? s.metrics.peers : s.chains.Nexus && s.chains.Nexus.peers;
  const m = s.mining;
  const mining = !m ? '–' : m.running ? 'On' : m.enabled ? 'On, not running' : 'Off';
  const parts = [
    ['Version', s.status && s.status.version ? s.status.version : '–'],
    ['Up for', s.metrics && s.metrics.start ? duration(Date.now() - s.metrics.start) : '–'],
    ['Peers', peers == null ? '–' : num(peers)],
    ['Disk free', s.disk ? bytes(s.disk.freeBytes) : '–'],
    ['Mining', mining],
    ['Waiting transactions', s.status ? num(s.status.mempoolCount) : '–'],
  ];
  return html`<dl class="vitals">${parts.map(([k, v]) => html`<div><dt>${k}</dt><dd>${v}</dd></div>`)}</dl>`;
}
function issueHTML(i) {
  const action = i.action ? (i.action.href ? html`<a class="button small" href="${i.action.href}">${i.action.label}</a>` : html`<button type="button" class="small" data-action="${i.action.run}">${i.action.label}</button>`) : '';
  return html`<div class="issue" role="group" aria-label="${LEVEL_WORD[i.level]}">${raw(ICON[i.level])}<div><div class="what">${i.what}</div>${i.why ? html`<div class="why">${i.why}</div>` : ''}</div><div class="act">${action}</div></div>`;
}

/** Chains as an always-open tree. A healthy row says nothing beyond its
 *  height; a row with a problem says what and since when. */
function treeHTML(s) {
  const paths = chainPaths(s);
  const children = (p) => paths.filter((c) => parentOf(c) === p);
  const problemsBelow = (p) => paths.filter((c) => c.startsWith(`${p}/`)).filter((c) => { const v = chainVerdict(s, c); return v && (v.level === 'bad' || v.level === 'warn'); }).length;
  const item = (p) => {
    const kids = children(p);
    return html`<li>${rowHTML(s, p, problemsBelow(p))}${kids.length ? html`<ul>${kids.map(item)}</ul>` : ''}</li>`;
  };
  return html`<ul class="tree">${item('Nexus')}</ul>`;
}
function rowHTML(s, path, below) {
  const c = s.chains[path]; const v = chainVerdict(s, path);
  const h = c && c.health;
  const height = h && h.height != null ? Number(h.height) : null;
  const level = v ? v.level : '';
  const last = c && c.latest && c.latest.timestamp ? Number(c.latest.timestamp) : null;
  const facts = height == null ? '' : html`<span class="h" title="Height of the newest block this node acts on">${num(height)}</span><span class="age">${last ? ago(last) : ''}</span>`;
  const name = lastSegment(path);
  // A problem the attention list explains is only named on its row.
  const covered = level === 'bad' || level === 'warn';
  return html`<a class="row ${level}" href="#/chain/${path}">
    <span class="name">${name}${level === 'quiet' && !quietAbove(s, path) ? html`<small>${v.text}</small>` : ''}</span>
    <span class="facts">${facts}</span>
    ${v && level !== 'quiet' ? html`<span class="verdict">${raw(ICON[level] || '')}${covered ? html`<span>${v.text}</span>` : html`<span><strong>${v.text}.</strong> ${v.detail || ''}</span>`}</span>` : ''}
    ${v && v.progress != null ? html`<span class="progress" role="progressbar" aria-label="Sync progress" aria-valuemin="0" aria-valuemax="100" aria-valuenow="${Math.round(v.progress * 100)}"><i data-w="${(v.progress * 100).toFixed(1)}%"></i></span>` : ''}
    ${below && !(v && (v.level === 'bad' || v.level === 'warn')) ? html`<span class="below">${below === 1 ? 'A chain below needs attention' : `${below} chains below need attention`}</span>` : ''}
  </a>`;
}

/** A solo chain says so once, at the top of its run of solo chains. */
function quietAbove(s, path) {
  const parent = parentOf(path);
  if (!parent) return false;
  const v = chainVerdict(s, parent);
  return !!(v && v.level === 'quiet');
}

// Chain detail ------------------------------------------------------------

VIEWS.chain = {
  render() {
    const s = snap(); const path = state.route.arg || 'Nexus';
    const c = s.chains[path]; const v = chainVerdict(s, path);
    const h = c && c.health;
    const rate = rateOf(s, path);
    const last = c && c.latest && c.latest.timestamp ? Number(c.latest.timestamp) : null;
    const p = s.progress[path];
    const cfg = (s.config && s.config.config) || {};
    const below = chainPaths(s).filter((x) => parentOf(x) === path);
    return html`
      <a class="back" href="#/">Overview</a>
      <div class="page-head"><div class="titles"><h1>${lastSegment(path)}</h1><p class="muted">${path.split('/').join(' / ')}</p></div></div>
      ${restartBanner()}
      ${v && v.level !== 'quiet' ? html`<p class="lede ${v.level}">${raw(v.level === 'note' ? '' : ICON[v.level])} ${v.text}. <span class="lede-detail">${v.detail}</span></p>` : ''}
      ${!c ? html`<p class="prose">This chain isn't running on this node.</p>` : html`
      <dl class="facts-grid">
        <div><dt>Height</dt><dd>${h && h.height != null ? num(Number(h.height)) : '–'} ${h && h.bestHeaderHeight != null && h.bestHeaderHeight !== h.height ? html`<small>of ${num(Number(h.bestHeaderHeight))}</small>` : ''}</dd></div>
        <div><dt>Last block</dt><dd>${last ? ago(last) : '–'}</dd></div>
        <div><dt>Last progress seen</dt><dd>${p ? ago(p.at) : '–'}</dd></div>
        <div><dt>Peers serving it</dt><dd>${c.peers == null ? '–' : num(c.peers)}</dd></div>
        <div><dt>Recent pace</dt><dd>${rate == null ? html`<small>measuring…</small>` : rate > 0 ? html`${num(Math.round(rate * 60))} <small>blocks/min</small>` : '0'}</dd></div>
        <div><dt>Target block time</dt><dd>${s.blockTime[path] ? duration(s.blockTime[path]) : '–'}</dd></div>
        <div><dt>Keeps state for</dt><dd>${retention(cfg, path)}</dd></div>
        <div><dt>Waiting transactions</dt><dd>${h ? num(h.mempoolCount) : '–'}</dd></div>
      </dl>`}
      <section aria-labelledby="bt-h"><h2 id="bt-h">Time between recent blocks</h2><div id="intervals">${s.blockCache && s.blockCache[path] ? intervalsHTML(s.blockCache[path], s.blockTime[path]) : html`<p class="empty">Reading recent blocks…</p>`}</div></section>
      <section aria-labelledby="log-h">
        <div class="section-head"><h2 id="log-h">Recent log lines about this chain</h2><a class="small" href="#/logs?chain=${encodeURIComponent(path)}">All logs for ${lastSegment(path)}</a></div>
        <div id="chain-log" class="log-mini ${s.logCache && s.logCache[path] && s.logCache[path].length ? '' : 'muted'}">${s.logCache && s.logCache[path] ? (s.logCache[path].length ? s.logCache[path].join('\n') : 'Nothing about this chain in the last 3,000 lines.') : 'Reading the log…'}</div>
      </section>
      <section aria-labelledby="act-h"><h2 id="act-h">Actions</h2>${chainActions(s, path, below)}</section>
      <details><summary class="small">Identifiers</summary>
        <dl class="facts-grid mt-3">
          <div><dt>Newest block</dt><dd>${cidView(h && h.tipCID)}</dd></div>
          <div><dt>Network genesis</dt><dd>${cidView(h && h.nexusGenesisCID)}</dd></div>
          ${h && h.waiting ? html`<div><dt>Waiting on</dt><dd class="small">${h.waiting}</dd></div>` : ''}
        </dl>
      </details>`;
  },
  async mount() {
    const path = state.route.arg || 'Nexus';
    const n = node(); const s = snap();
    try {
      const page = await get(n, q('api/blocks?limit=25', path));
      s.blockCache = { ...(s.blockCache || {}), [path]: page.blocks };
      const box = $('#intervals'); if (box) { box.innerHTML = intervalsHTML(page.blocks, s.blockTime[path]).s; mountSpark(box); }
    } catch (e) { const box = $('#intervals'); if (box) box.innerHTML = html`<p class="empty">Couldn't read recent blocks: ${e.message}</p>`.s; }
    try {
      const text = await get(n, 'logs?file=node&tail=3000', { text: true });
      const lines = text.split('\n').filter((l) => mentions(l, path)).slice(-12);
      s.logCache = { ...(s.logCache || {}), [path]: lines };
      const box = $('#chain-log');
      if (box) { box.classList.toggle('muted', !lines.length); box.textContent = lines.length ? lines.join('\n') : 'Nothing about this chain in the last 3,000 lines.'; }
    } catch (e) { const box = $('#chain-log'); if (box) box.textContent = e.status === 404 ? "This node's log goes to its standard output, not a file the dashboard can read." : `Couldn't read the log: ${e.message}`; }
  },
};
function retention(cfg, path) {
  const mode = cfg.state || 'recent';
  if (mode === 'all') return 'All history';
  if (mode === 'none') return 'Current state only';
  const w = (cfg.stateWindows && cfg.stateWindows[path]) || cfg.stateWindow || 64;
  return `${num(w)} recent blocks`;
}
function mentions(line, path) {
  if (path === 'Nexus') return /Nexus(?![/\w])/.test(line);
  return line.includes(path) && !line.includes(`${path}/`);
}
function chainActions(s, path, below) {
  if (path === 'Nexus') return html`<p class="prose">Nexus is the root chain; every node hosts it. To start it over from its peers, see <a href="#/danger">Restart and wipe</a>.</p>`;
  const blocked = below.length ? `Stop hosting ${below.map(lastSegment).join(', ')} first: a chain below it is hosted.` : '';
  return html`<div class="actions">
    <div class="action">
      <div class="grow"><strong>Stop hosting ${lastSegment(path)}</strong><p class="soft small">The node stops following it right away. What it stored stays, so hosting it again resumes where it left off.</p>${blocked ? html`<p class="why-not">${blocked}</p>` : ''}</div>
      <button type="button" class="danger" data-unhost="${path}" ${raw(blocked ? 'disabled' : '')}>Stop hosting</button>
    </div>
    <div class="action">
      <div class="grow"><strong>Commit a block on ${lastSegment(parentOf(path))}</strong>
      <p class="soft small mb-2">Asks ${parentOf(path)}'s miners to carry this chain's next block. It's a signed transaction, so it runs where your wallet key is, not here:</p>
      <pre class="cmd">lattice child commit ${path} --key ./wallet.json --fee 1 --root &lt;root&gt;</pre></div>
    </div>
  </div>`;
}

// Sparkline: one series (seconds between consecutive blocks), with the
// target block time as a dashed reference. Hover or focus a point for its value.
function intervalsHTML(blocks, target) {
  const rows = (blocks || []).filter((b) => b.timestamp).sort((a, b) => Number(a.height) - Number(b.height));
  const pts = [];
  for (let i = 1; i < rows.length; i += 1) pts.push({ height: Number(rows[i].height), ms: Number(rows[i].timestamp) - Number(rows[i - 1].timestamp) });
  if (pts.length < 2) return html`<p class="empty">Not enough blocks yet.</p>`;
  const W = 560; const H = 72; const pad = 6;
  const max = Math.max(...pts.map((p) => p.ms), target || 0) * 1.1 || 1;
  const x = (i) => pad + (i * (W - 2 * pad)) / (pts.length - 1);
  const y = (ms) => H - pad - (Math.max(0, ms) / max) * (H - 2 * pad);
  const d = pts.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.ms).toFixed(1)}`).join('');
  const sorted = pts.map((p) => p.ms).sort((a, b) => a - b);
  const median = sorted[Math.floor(sorted.length / 2)];
  const lastPt = pts[pts.length - 1];
  const label = `Time between the last ${pts.length} blocks: median ${duration(median)}${target ? `, target ${duration(target)}` : ''}, most recent ${duration(lastPt.ms)}.`;
  return html`<div class="spark-wrap">
    <svg class="spark" viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" role="img" aria-label="${label}">
      <line class="base" x1="0" x2="${W}" y1="${H - pad}" y2="${H - pad}"/>
      ${target ? html`<line class="ref" x1="0" x2="${W}" y1="${y(target).toFixed(1)}" y2="${y(target).toFixed(1)}"/>` : ''}
      <path class="line" d="${d}" vector-effect="non-scaling-stroke"/>
      <line class="cursor" x1="0" x2="0" y1="0" y2="${H}" visibility="hidden"/>
      ${pts.map((p, i) => html`<rect class="hit" x="${(x(i) - (W / pts.length) / 2).toFixed(1)}" y="0" width="${(W / pts.length).toFixed(1)}" height="${H}" data-i="${i}" data-x="${x(i).toFixed(1)}" data-tip="Block ${num(p.height)}: ${duration(p.ms)} after the one before"/>`)}
    </svg>
    <div class="tip" hidden></div>
    <div class="spark-legend"><span>Block ${num(pts[0].height)}</span><span>Median ${duration(median)}${target ? html`, target ${duration(target)} (dashed)` : ''}</span><span>Block ${num(lastPt.height)}</span></div>
    <details class="small"><summary>Show as a table</summary>
      <table class="fleet mt-2"><thead><tr><th>Block</th><th>Seconds after the one before</th></tr></thead>
      <tbody>${pts.slice().reverse().map((p) => html`<tr><td>${num(p.height)}</td><td>${(p.ms / 1000).toFixed(1)}</td></tr>`)}</tbody></table>
    </details>
  </div>`;
}
function mountSpark(root) {
  const svg = $('svg.spark', root); const tip = $('.tip', root); const cursor = svg && $('.cursor', svg);
  if (!svg) return;
  const show = (rect) => {
    const box = svg.getBoundingClientRect(); const wrap = root.querySelector('.spark-wrap').getBoundingClientRect();
    const vx = Number(rect.dataset.x);
    const px = (vx / svg.viewBox.baseVal.width) * box.width;
    cursor.setAttribute('x1', vx); cursor.setAttribute('x2', vx); cursor.setAttribute('visibility', 'visible');
    tip.textContent = rect.dataset.tip; tip.hidden = false;
    const half = tip.offsetWidth / 2;
    tip.style.left = `${Math.min(Math.max(px, half), box.width - half)}px`;
    tip.style.top = `${box.top - wrap.top}px`;
  };
  const hide = () => { tip.hidden = true; cursor.setAttribute('visibility', 'hidden'); };
  for (const r of $$('.hit', svg)) { r.addEventListener('mouseenter', () => show(r)); }
  svg.addEventListener('mouseleave', hide);
  // keyboard: arrow through points
  svg.tabIndex = 0;
  let at = -1; const rects = $$('.hit', svg);
  svg.addEventListener('keydown', (e) => {
    if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
    e.preventDefault();
    at = at < 0 ? rects.length - 1 : Math.max(0, Math.min(rects.length - 1, at + (e.key === 'ArrowRight' ? 1 : -1)));
    show(rects[at]);
  });
  svg.addEventListener('blur', hide);
}

// Logs ------------------------------------------------------------------------

const logs = { lines: [], file: 'node', timer: null, follow: true, fresh: 0, filter: '', level: 'all', chain: '', error: null };
function leaveLogs() { clearTimeout(logs.timer); logs.timer = null; }
function lineLevel(l) {
  const m = l.match(/^\S+\s+(trace|debug|info|notice|warning|error|critical)\b/);
  if (m) return m[1] === 'error' || m[1] === 'critical' ? 'bad' : m[1] === 'warning' ? 'warn' : '';
  if (/\b(error|fatal|panic)\b/i.test(l)) return 'bad';
  if (/\b(fail(ed|ure|s)?|refus(ed|es)|stall(ed)?|warning)\b/i.test(l)) return 'warn';
  return '';
}
VIEWS.logs = {
  form: true,
  render() {
    const s = snap(); const p = state.route.params;
    const file = p.file === 'mine' ? 'mine' : 'node';
    if (logs.file !== file) { logs.lines = []; logs.file = file; }
    if (p.chain !== undefined) logs.chain = p.chain;
    return html`
      <div class="page-head"><div class="titles"><h1>Logs</h1><p class="muted">The newest lines, kept up to date. Scroll up to pause.</p></div></div>
      ${restartBanner()}
      <div class="log-tools">
        <div class="seg" role="group" aria-label="Which log"><button type="button" data-logfile="node" aria-pressed="${String(file === 'node')}">Node</button><button type="button" data-logfile="mine" aria-pressed="${String(file === 'mine')}">Miner</button></div>
        <div class="chips" role="group" aria-label="Lines">
          <button type="button" class="chip" data-loglevel="all" aria-pressed="${String(logs.level === 'all')}">All lines</button>
          <button type="button" class="chip" data-loglevel="problems" aria-pressed="${String(logs.level === 'problems')}">Problems only</button>
        </div>
        <label class="visually-hidden" for="log-chain">Chain</label>
        <select id="log-chain"><option value="">Every chain</option>${chainPaths(s).map((c) => html`<option value="${c}" ${raw(c === logs.chain ? 'selected' : '')}>${c}</option>`)}</select>
        <label class="visually-hidden" for="log-search">Search</label>
        <input id="log-search" type="search" placeholder="Search the log" value="${logs.filter}">
        <button type="button" class="small" data-logfollow>${logs.follow ? 'Pause' : 'Follow'}</button>
      </div>
      <div class="log-wrap">
        <div class="logbox" id="logbox" tabindex="0" role="log" aria-label="${file === 'mine' ? 'Miner' : 'Node'} log"></div>
        <button type="button" class="newlines primary small" data-lognew hidden></button>
      </div>
      <p class="muted small" id="log-status"></p>`;
  },
  mount() {
    const box = $('#logbox');
    box.addEventListener('scroll', () => {
      const atBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 30;
      if (atBottom && !logs.follow) { logs.follow = true; logs.fresh = 0; paintLogMeta(); }
      else if (!atBottom && logs.follow && !logs.autoScrolling) { logs.follow = false; paintLogMeta(); }
    });
    $('#log-search').addEventListener('input', (e) => { logs.filter = e.target.value; paintLog(true); });
    $('#log-chain').addEventListener('change', (e) => { logs.chain = e.target.value; paintLog(true); });
    paintLog(true);
    pollLogs();
  },
  update() { paintLogMeta(); },
};
async function pollLogs() {
  clearTimeout(logs.timer);
  const n = node();
  try {
    const text = await get(n, `logs?file=${logs.file}&tail=1500`, { text: true });
    const got = text.split('\n'); if (got[got.length - 1] === '') got.pop();
    let added = got;
    if (logs.lines.length) {
      const anchor = logs.lines.slice(-3).join('\n');
      added = got;
      for (let i = got.length - 1; i >= 2; i -= 1) {
        if (got.slice(i - 2, i + 1).join('\n') === anchor) { added = got.slice(i + 1); break; }
      }
      if (added === got && got.length && logs.lines.length && got.join('\n').includes(anchor)) added = [];
    }
    if (added.length) {
      logs.lines = logs.lines.concat(added).slice(-5000);
      if (!logs.follow) logs.fresh += added.filter(matchesLog).length;
      paintLog(false);
    }
    logs.error = null;
  } catch (e) {
    logs.error = e.status === 404 ? (logs.file === 'mine' ? 'No miner log yet: mining has not run on this node.' : "This node's log goes to its standard output, not a file the dashboard can read.") : `Couldn't read the log: ${e.message}`;
  }
  paintLogMeta();
  if (state.route.name === 'logs') logs.timer = setTimeout(pollLogs, document.hidden ? 10000 : 2000);
}
function matchesLog(l) {
  if (logs.level === 'problems' && !lineLevel(l)) return false;
  if (logs.chain && !mentions(l, logs.chain)) return false;
  if (logs.filter && !l.toLowerCase().includes(logs.filter.toLowerCase())) return false;
  return true;
}
function highlight(line) {
  if (!logs.filter) return esc(line);
  const i = line.toLowerCase().indexOf(logs.filter.toLowerCase());
  if (i < 0) return esc(line);
  return esc(line.slice(0, i)) + '<mark>' + esc(line.slice(i, i + logs.filter.length)) + '</mark>' + highlight(line.slice(i + logs.filter.length));
}
function paintLog() {
  const box = $('#logbox'); if (!box) return;
  const shown = logs.lines.filter(matchesLog).slice(-2000);
  const keep = box.scrollTop;
  box.innerHTML = shown.length
    ? shown.map((l) => { const lv = lineLevel(l); return `<div class="ln ${lv}">${lv ? `<span class="visually-hidden">${LEVEL_WORD[lv]}: </span>` : ''}${highlight(l)}</div>`; }).join('')
    : `<div class="ln muted">${logs.lines.length ? 'No lines match.' : 'Reading…'}</div>`;
  if (logs.follow) { logs.autoScrolling = true; box.scrollTop = box.scrollHeight; requestAnimationFrame(() => { logs.autoScrolling = false; }); } else box.scrollTop = keep;
}
function paintLogMeta() {
  const btn = $('[data-lognew]'); const st = $('#log-status'); const f = $('[data-logfollow]');
  if (btn) { btn.hidden = logs.follow || !logs.fresh; btn.textContent = `${plural(logs.fresh, 'new line')} ↓`; }
  if (f) f.textContent = logs.follow ? 'Pause' : 'Follow';
  if (st) st.textContent = logs.error || (logs.follow ? `Following. ${plural(logs.lines.filter(matchesLog).length, 'line')} shown.` : 'Paused. New lines collect below.');
}

// Mining ------------------------------------------------------------------------

VIEWS.mining = {
  render() {
    const s = snap(); const m = s.mining || {};
    const cfg = (s.config && s.config.config) || {};
    const mine = cfg.mine || {};
    const recipients = m.recipients || mine.recipients || {};
    const chains = chainPaths(s);
    const sentence = !s.mining ? 'Reading…'
      : m.running ? `The miner is running${m.pid ? ` (process ${m.pid})` : ''}.`
        : m.enabled ? "Mining is on, but the miner isn't running right now." : 'Mining is off.';
    return html`
      <div class="page-head"><div class="titles"><h1>Mining</h1><p class="lede sub ${m.enabled && !m.running ? 'warn' : ''}">${sentence}</p></div>
        ${s.config && !s.config.flags ? html`<button type="button" class="${m.enabled ? '' : 'primary'}" data-mine="${m.enabled ? 'off' : 'on'}">${m.enabled ? 'Stop mining' : 'Start mining'}</button>` : ''}
      </div>
      ${restartBanner()}
      <dl class="facts-grid">
        <div><dt>Restarts since the node started</dt><dd>${num(m.restarts || 0)}</dd></div>
        <div><dt>Last exit</dt><dd>${m.lastExit || html`<small>none</small>`}</dd></div>
        <div><dt>Workers</dt><dd>${mine.workers ?? html`<small>default</small>`}</dd></div>
        <div><dt>Least time between blocks</dt><dd>${mine.minBlockIntervalSeconds ? `${mine.minBlockIntervalSeconds} s` : html`<small>none</small>`}</dd></div>
      </dl>
      <section aria-labelledby="rec-h">
        <div class="section-head"><h2 id="rec-h">Who each chain pays</h2><a class="small" href="#/settings?focus=mining">Change in Settings</a></div>
        <ul class="list">${chains.map((c) => html`<li><span class="grow"><strong>${c}</strong></span>${recipients[c] ? cidView(recipients[c]) : html`<span class="muted small">No one: its block reward is burned</span>`}</li>`)}</ul>
      </section>
      <section aria-labelledby="ml-h">
        <div class="section-head"><h2 id="ml-h">Miner log</h2><a class="small" href="#/logs?file=mine">Open the full log</a></div>
        <div id="mine-log" class="log-mini ${s.mineLog ? '' : 'muted'}">${s.mineLog || 'Reading…'}</div>
      </section>`;
  },
  async mount() {
    try {
      const text = await get(node(), 'logs?file=mine&tail=12', { text: true });
      snap().mineLog = text.trim() || 'Empty.';
    } catch (e) { snap().mineLog = e.status === 404 ? 'No miner log: mining has not run on this node.' : e.message; }
    const box = $('#mine-log'); if (box) { box.textContent = snap().mineLog; box.classList.remove('muted'); box.scrollTop = box.scrollHeight; }
  },
};

// Storage ----------------------------------------------------------------------

const STORE_GROUPS = [
  [/^state\.db/, 'Chain state', 'Accounts and balances, as many blocks back as the node keeps'],
  [/^volumes\.db/, 'Blocks and content', 'Blocks, transactions and pinned content'],
  [/^volume-bundles\.db/, 'Bundles', 'Content grouped for serving'],
];
VIEWS.storage = {
  render() {
    const s = snap(); const d = s.disk;
    const cfg = (s.config && s.config.config) || {};
    const groups = [];
    if (d) {
      const by = new Map();
      for (const st of d.stores) {
        const g = STORE_GROUPS.find(([re]) => re.test(st.name)) || [null, 'Other files', 'Peers, cookie, locks'];
        const cur = by.get(g[1]) || { name: g[1], about: g[2], bytes: 0 };
        cur.bytes += st.bytes; by.set(g[1], cur);
      }
      groups.push(...[...by.values()].sort((a, b) => b.bytes - a.bytes));
    }
    const max = Math.max(1, ...groups.map((g) => g.bytes));
    return html`
      <div class="page-head"><div class="titles"><h1>Storage</h1>${d ? html`<p class="lede sub">${bytes(d.totalBytes)} used, ${bytes(d.freeBytes)} free on the data volume.</p>` : ''}</div></div>
      ${restartBanner()}
      ${d ? html`<ul class="meters" aria-label="Space by store">${groups.map((g) => html`<li><span><strong>${g.name}</strong><br><span class="muted small">${g.about}</span></span><span class="bar" aria-hidden="true"><i data-w="${((g.bytes / max) * 100).toFixed(1)}%"></i></span><span class="val">${bytes(g.bytes)}</span></li>`)}</ul>
        <p class="muted small">Data directory: <code>${d.storage}</code></p>` : html`<p class="empty">Reading…</p>`}
      <section aria-labelledby="ret-h">
        <div class="section-head"><h2 id="ret-h">What the node keeps</h2><a class="small" href="#/settings?focus=retention">Change in Settings</a></div>
        <dl class="facts-grid">
          <div><dt>State</dt><dd>${retention(cfg, 'Nexus')}</dd></div>
          <div><dt>Block bodies</dt><dd>${cfg.blockBodies === 'none' ? 'Not kept after use' : 'All'}</dd></div>
          <div><dt>Finality window</dt><dd>${cfg.finalityWindow ? `${num(cfg.finalityWindow)} blocks` : 'Off'}</dd></div>
        </dl>
      </section>
      <section aria-labelledby="pins-h"><h2 id="pins-h">Pinned content</h2><div id="pins">${pinsHTML(s.pinsCache)}</div></section>`;
  },
  async mount() {
    const s = snap();
    try {
      s.pinsCache = { pins: (await get(node(), 'pins')).pins };
    } catch (e) {
      s.pinsCache = { error: e.status === 403 || e.status === 404 ? 'Pins are managed on the node’s own loopback port, not through this listener.' : e.message };
    }
    const box = $('#pins'); if (box) box.innerHTML = pinsHTML(s.pinsCache).s;
  },
};
function pinsHTML(c) {
  if (!c) return html`<p class="empty">Reading…</p>`;
  if (c.error) return html`<p class="empty">${c.error}</p>`;
  return c.pins.length
    ? html`<p class="muted small">Kept and served until you unpin them, whatever the node otherwise keeps.</p><ul class="list">${c.pins.map((cid) => html`<li><span class="grow">${cidView(cid)}</span><button type="button" class="small danger" data-unpin="${cid}">Unpin</button></li>`)}</ul>`
    : html`<p class="empty">Nothing is pinned. Apps pin content with <code>lattice pins add</code>.</p>`;
}

// Settings ------------------------------------------------------------------

const LIVE_KEYS = new Set(['hostedChains', 'peers', 'mine']);
const settings = { tab: 'form', original: null, draft: null, review: null, result: null, rawError: null, loading: false };
function isLive(key, patch) {
  if (key === 'peers') {
    const p = patch && patch.peers;
    return !(Array.isArray(p) || p === null || (isPlainObject(p) && 'Nexus' in p));
  }
  return LIVE_KEYS.has(key);
}
function liveTag(key, patch) {
  return isLive(key, patch) ? html`<span class="tag live">Applies now</span>` : html`<span class="tag restart">Needs restart</span>`;
}
/** RFC 7396 merge patch turning `from` into `to`. */
function mergePatch(from, to) {
  const patch = {};
  for (const k of Object.keys(to)) {
    if (deepEqual(from[k], to[k])) continue;
    if (isPlainObject(from[k]) && isPlainObject(to[k])) {
      const inner = mergePatch(from[k], to[k]);
      if (Object.keys(inner).length) patch[k] = inner;
    } else patch[k] = clone(to[k]);
  }
  for (const k of Object.keys(from)) if (!(k in to)) patch[k] = null;
  return patch;
}
function flatten(patch, from, prefix = '') {
  const out = [];
  for (const [k, v] of Object.entries(patch)) {
    const key = prefix ? `${prefix}.${k}` : k;
    const old = from ? from[k] : undefined;
    if (isPlainObject(v) && isPlainObject(old)) out.push(...flatten(v, old, key));
    else out.push({ key, old, value: v });
  }
  return out;
}
const show = (v) => (v === undefined || v === null ? '(not set)' : typeof v === 'string' ? v : JSON.stringify(v));
function getPath(obj, path) { return path.split('.').reduce((o, k) => (o == null ? undefined : o[k]), obj); }
function setPath(obj, path, value) {
  const keys = path.split('.');
  const holders = [obj];
  for (const k of keys.slice(0, -1)) { const o = holders[holders.length - 1]; if (!isPlainObject(o[k])) o[k] = {}; holders.push(o[k]); }
  const last = keys[keys.length - 1];
  const target = holders[holders.length - 1];
  if (value === undefined || value === '' || (Array.isArray(value) && !value.length)) delete target[last]; else target[last] = value;
  // An object left empty goes with its last member.
  for (let i = holders.length - 1; i > 0; i -= 1) {
    if (Object.keys(holders[i]).length) break;
    delete holders[i - 1][keys[i - 1]];
  }
}

const FIELDS = [
  { group: 'retention', key: 'state', label: 'State to keep', type: 'select', options: [['', 'Recent blocks (default)'], ['all', 'All history'], ['recent', 'Recent blocks'], ['none', 'Current state only']], hint: 'Older state is what lets the node answer questions about past blocks.' },
  { group: 'retention', key: 'stateWindow', label: 'Recent window', type: 'number', unit: 'blocks', placeholder: '64', hint: 'How many recent blocks of state to keep. Setting it chooses "Recent blocks".' },
  { group: 'retention', key: 'blockBodies', label: 'Block bodies', type: 'select', options: [['', 'Keep all (default)'], ['all', 'Keep all'], ['none', 'Drop after use']] },
  { group: 'retention', key: 'finalityWindow', label: 'Finality window', type: 'number', unit: 'blocks', placeholder: 'Off', hint: 'Ignore forks deeper than this. Empty is off.' },
  { group: 'serving', key: 'publicReadURL', label: 'Public read address', type: 'url', placeholder: 'https://reads.example.org', hint: 'Told to other nodes and explorers as where to read these chains.' },
  { group: 'serving', key: 'publicRead', label: 'Public read port', type: 'number', placeholder: 'Off' },
  { group: 'serving', key: 'servingMaxConcurrent', label: 'Content served at once', type: 'number', unit: 'requests', placeholder: 'Default' },
  { group: 'serving', key: 'servingMaxInFlightVolumeBytes', label: 'Content in flight', type: 'number', unit: 'bytes', placeholder: '128000000' },
  { group: 'serving', key: 'publicReadFetches', label: 'Peer reads for public readers', type: 'number', placeholder: '4', hint: '0 serves only what this node holds.' },
];

VIEWS.settings = {
  form: true,
  render() {
    const s = snap();
    if (s.config && s.config.flags) return html`<div class="page-head"><div class="titles"><h1>Settings</h1></div></div><p class="prose">This node was started with command-line flags, so it has no configuration file to change here. Start it with <code>lattice up</code> (a root made by <code>lattice init</code>) to manage settings from the dashboard.</p>`;
    if (!settings.original) {
      return html`<div class="page-head"><div class="titles"><h1>Settings</h1></div></div><p class="empty">Reading the configuration…</p>`;
    }
    const patch = mergePatch(settings.original, settings.draft || {});
    const changes = flatten(patch, settings.original);
    return html`
      <div class="page-head"><div class="titles"><h1>Settings</h1><p class="muted">The node's <code>lattice.json</code>. Some changes apply at once; the rest wait for a restart, and each one says which.</p></div></div>
      ${restartBanner()}
      <div class="tabs" role="tablist"><button type="button" role="tab" data-tab="form" aria-selected="${String(settings.tab === 'form')}">Common settings</button><button type="button" role="tab" data-tab="raw" aria-selected="${String(settings.tab === 'raw')}">Raw JSON</button></div>
      ${settings.result ? resultHTML() : ''}
      ${settings.tab === 'form' ? settingsForm(s) : rawForm()}
      ${changes.length && !settings.review ? html`<div class="staged" role="region" aria-label="Unsaved changes"><span class="grow"><strong>${plural(changes.length, 'change')}</strong> not applied yet.</span><button type="button" class="quiet" data-discard>Discard</button><button type="button" class="primary" data-review>Review changes</button></div>` : ''}
      ${settings.review ? reviewHTML(changes, patch) : ''}`;
  },
  mount(main) {
    const s = snap();
    if (!settings.original && s.config && !s.config.flags) loadSettings();
    const focus = state.route.params.focus;
    if (focus) { const el = document.getElementById(`set-${focus}`); if (el) el.scrollIntoView({ block: 'start' }); }
    main.addEventListener('input', onSettingsInput);
    main.addEventListener('change', onSettingsInput);
  },
};
async function loadSettings() {
  try {
    const r = await get(node(), 'config');
    snap().config = r;
    settings.original = r.config; settings.draft = clone(r.config); settings.review = null;
  } catch (e) { toast(`Couldn't read settings: ${e.message}`); }
  rerender();
}
function rerender() {
  const main = $('main'); const view = VIEWS[state.route.name];
  if (!main || !view) return;
  const y = window.scrollY;
  main.innerHTML = `<div class="page">${view.render().s}</div>`;
  applyWidths(main);
  window.scrollTo(0, y);
}
function fieldHTML(f) {
  const d = settings.draft || {}; const o = settings.original || {};
  const value = getPath(d, f.key);
  const changed = !deepEqual(value, getPath(o, f.key));
  const id = `f-${f.key.replace(/\W/g, '-')}`;
  let control;
  if (f.type === 'select') control = html`<select id="${id}" data-key="${f.key}" data-type="select">${f.options.map(([v, l]) => html`<option value="${v}" ${raw((value ?? '') === v ? 'selected' : '')}>${l}</option>`)}</select>`;
  else control = html`<input id="${id}" type="${f.type === 'number' ? 'number' : f.type === 'url' ? 'url' : 'text'}" ${raw(f.type === 'number' ? 'min="0" inputmode="numeric"' : '')} data-key="${f.key}" data-type="${f.type}" value="${value ?? ''}" placeholder="${f.placeholder || ''}">`;
  return html`<div class="field ${changed ? 'changed' : ''}"><label for="${id}" class="label-line">${f.label}${f.unit ? html`<span class="muted small">${f.unit}</span>` : ''} ${liveTag(f.key)}</label>${control}${f.hint ? html`<span class="hint">${f.hint}</span>` : ''}</div>`;
}
function settingsForm(s) {
  const d = settings.draft || {}; const o = settings.original || {};
  const hosted = d.hostedChains || [];
  const peers = Array.isArray(d.peers) ? { Nexus: d.peers } : (d.peers || {});
  const chains = ['Nexus', ...hosted];
  const mine = d.mine || {};
  const origins = d.operatorAllowedOrigins || [];
  return html`
    <section id="set-chains" aria-labelledby="sc-h">
      <div class="section-head"><h2 id="sc-h">Chains this node hosts</h2>${liveTag('hostedChains')}</div>
      <p class="prose small">Nexus is always hosted. A chain added by its path is synced from peers that host it; its parent must be hosted too.</p>
      <ul class="list">${hosted.length ? hosted.map((c) => html`<li><span class="grow"><strong>${c}</strong>${(o.hostedChains || []).includes(c) ? '' : html` <span class="tag live">new</span>`}</span><button type="button" class="small" data-remove-chain="${c}">Remove</button></li>`) : html`<li class="muted">No chains besides Nexus.</li>`}</ul>
      <form class="inline" data-add-chain><label class="visually-hidden" for="add-chain">Chain path</label><input id="add-chain" type="text" placeholder="Nexus/Name" spellcheck="false" pattern="Nexus(/[^/\\s]+)+"><button type="submit">Add chain</button></form>
    </section>
    <section id="set-mining" aria-labelledby="sm-h">
      <div class="section-head"><h2 id="sm-h">Mining</h2>${liveTag('mine')}</div>
      <label class="check"><input type="checkbox" data-key="mine.enabled" data-type="bool" ${raw(mine.enabled ? 'checked' : '')}> Mine on this node</label>
      <div class="form-grid">${chains.map((c) => {
        const id = `rec-${c.replace(/\W/g, '-')}`; const v = (mine.recipients || {})[c] || '';
        const changed = v !== (((o.mine || {}).recipients || {})[c] || '');
        return html`<div class="field ${changed ? 'changed' : ''}"><label for="${id}" class="label-line">${c} pays</label><input id="${id}" type="text" spellcheck="false" placeholder="Address (empty burns the reward)" data-key="mine.recipients.${c}" data-type="text" value="${v}"></div>`;
      })}</div>
    </section>
    <section id="set-peers" aria-labelledby="sp-h">
      <div class="section-head"><h2 id="sp-h">Peers</h2></div>
      <p class="prose small">Nodes to connect to, one per line, as <code>publicKey@host:port</code>.</p>
      <div class="form-grid">${chains.map((c) => {
        const id = `peers-${c.replace(/\W/g, '-')}`; const v = (peers[c] || []).join('\n');
        const was = (Array.isArray(o.peers) ? { Nexus: o.peers } : (o.peers || {}))[c] || [];
        return html`<div class="field ${same(peers[c] || [], was) ? '' : 'changed'}"><label for="${id}" class="label-line">${c} ${c === 'Nexus' ? html`<span class="tag restart">Needs restart</span>` : html`<span class="tag live">Applies now</span>`}</label><textarea id="${id}" rows="3" data-peers="${c}" spellcheck="false">${v}</textarea></div>`;
      })}</div>
    </section>
    <section id="set-retention" aria-labelledby="sr-h"><h2 id="sr-h">What the node keeps</h2><div class="form-grid">${FIELDS.filter((f) => f.group === 'retention').map(fieldHTML)}</div></section>
    <section id="set-serving" aria-labelledby="sv-h"><h2 id="sv-h">Serving others</h2><div class="form-grid">${FIELDS.filter((f) => f.group === 'serving').map(fieldHTML)}</div></section>
    <section id="set-access" aria-labelledby="sa-h">
      <div class="section-head"><h2 id="sa-h">Dashboards allowed to connect</h2>${liveTag('operatorAllowedOrigins')}</div>
      <p class="prose small">Another node's dashboard can manage this node only if its address is listed here, one per line, exactly as the browser shows it (for example <code>http://10.0.0.6:8090</code>). This page, served by this node, needs no entry.</p>
      <div class="field ${same(origins, o.operatorAllowedOrigins || []) ? '' : 'changed'}"><label class="visually-hidden" for="origins">Allowed dashboard addresses</label><textarea id="origins" rows="3" data-lines="operatorAllowedOrigins" spellcheck="false">${origins.join('\n')}</textarea></div>
    </section>`;
}
function rawForm() {
  return html`<div class="field"><label for="raw" class="label-line">lattice.json <span class="muted small">edit, then review</span></label>
    <textarea id="raw" rows="24" data-raw spellcheck="false">${JSON.stringify(settings.draft, null, 2)}</textarea>
    <span class="error" id="raw-error" role="alert">${settings.rawError || ''}</span></div>`;
}
function reviewHTML(changes, patch) {
  const restart = changes.some((c) => !isLive(c.key.split('.')[0], patch));
  return html`<section class="attention review" aria-labelledby="rv-h">
    <h2 id="rv-h">Review ${plural(changes.length, 'change')}</h2>
    <div class="review-body">
      <ul class="diff">${changes.map((c) => html`<li><span class="key">${c.key}</span>${liveTag(c.key.split('.')[0], patch)}<span class="vals"><del>${show(c.old)}</del><ins>${show(c.value)}</ins></span></li>`)}</ul>
      ${restart ? html`<p class="soft small">Changes marked "Needs restart" are saved now and take effect when the node restarts. You can restart right after.</p>` : ''}
      <div class="inline"><button type="button" class="primary" data-apply>Apply ${plural(changes.length, 'change')}</button><button type="button" data-cancel-review>Keep editing</button></div>
    </div>
  </section>`;
}
function resultHTML() {
  const r = settings.result;
  if (r.error) return html`<div class="banner bad" role="alert">${raw(ICON.bad)}<div class="grow"><strong>Nothing was changed.</strong> ${r.error}</div>${r.conflict ? html`<button type="button" data-restart>Restart to load the file</button>` : ''}<button type="button" class="quiet" data-dismiss-result>Dismiss</button></div>`;
  const failed = r.failed || [];
  return html`<div class="banner ${failed.length ? 'bad' : 'info'}" role="status"><div class="grow">
    ${failed.length ? html`<strong>Part of the change failed.</strong> What failed was left out of the file.` : html`<strong>Saved.</strong>`}
    ${r.applied.length ? html` Applied now: ${r.applied.join(', ')}.` : ''}
    ${r.restartRequired.length ? html` Waiting for a restart: ${r.restartRequired.join(', ')}.` : ''}
    ${failed.length ? html`<ul class="failures">${failed.map((f) => html`<li><strong>${f.key}${f.chain ? ` (${f.chain})` : ''}</strong>: ${f.error}</li>`)}</ul>` : ''}
  </div><button type="button" class="quiet" data-dismiss-result>Dismiss</button></div>`;
}
function onSettingsInput(e) {
  const t = e.target;
  if (!settings.draft || state.route.name !== 'settings') return;
  const d = settings.draft;
  if (t.dataset.raw !== undefined) {
    if (e.type !== 'input') return;
    try { const v = JSON.parse(t.value); if (!isPlainObject(v)) throw new Error('The file must be one JSON object.'); settings.draft = v; settings.rawError = null; } catch (err) { settings.rawError = err.message; }
    const errBox = $('#raw-error'); if (errBox) errBox.textContent = settings.rawError || '';
    paintStaged();
    return;
  }
  if (t.dataset.key) {
    let v;
    if (t.dataset.type === 'bool') v = t.checked;
    else if (t.dataset.type === 'number') v = t.value === '' ? undefined : Number(t.value);
    else v = t.value.trim() === '' ? undefined : t.value.trim();
    if (t.dataset.key.startsWith('mine.recipients.')) {
      const chain = t.dataset.key.slice('mine.recipients.'.length);
      d.mine = d.mine || {}; d.mine.recipients = d.mine.recipients || {};
      if (v === undefined) delete d.mine.recipients[chain]; else d.mine.recipients[chain] = v;
      if (!Object.keys(d.mine.recipients).length) delete d.mine.recipients;
    } else if (t.dataset.type === 'bool' && t.dataset.key === 'mine.enabled') {
      d.mine = d.mine || {}; d.mine.enabled = v;
    } else setPath(d, t.dataset.key, v);
    // A window is only valid with state "recent"; say so in the file.
    if (t.dataset.key === 'stateWindow' && v !== undefined && !d.state) {
      d.state = 'recent';
      const sel = document.getElementById('f-state'); if (sel) { sel.value = 'recent'; sel.closest('.field').classList.add('changed'); }
    }
  } else if (t.dataset.peers) {
    const list = t.value.split('\n').map((x) => x.trim()).filter(Boolean);
    const cur = Array.isArray(d.peers) ? { Nexus: d.peers } : { ...(d.peers || {}) };
    if (list.length) cur[t.dataset.peers] = list; else delete cur[t.dataset.peers];
    const keys = Object.keys(cur);
    if (!keys.length) delete d.peers;
    else if (keys.length === 1 && keys[0] === 'Nexus' && Array.isArray(settings.original.peers)) d.peers = cur.Nexus;
    else d.peers = cur;
  } else if (t.dataset.lines) {
    const list = t.value.split('\n').map((x) => x.trim()).filter(Boolean);
    if (list.length) d[t.dataset.lines] = list; else delete d[t.dataset.lines];
  } else return;
  const field = t.closest('.field');
  if (field) field.classList.add('changed');
  paintStaged();
}
function paintStaged() {
  const patch = mergePatch(settings.original, settings.draft || {});
  const changes = flatten(patch, settings.original);
  let bar = $('.staged');
  if (!changes.length) { if (bar) bar.remove(); return; }
  if (settings.review) return;
  const markup = html`<span class="grow"><strong>${plural(changes.length, 'change')}</strong> not applied yet.</span><button type="button" class="quiet" data-discard>Discard</button><button type="button" class="primary" data-review>Review changes</button>`.s;
  if (!bar) { bar = document.createElement('div'); bar.className = 'staged'; bar.setAttribute('role', 'region'); bar.setAttribute('aria-label', 'Unsaved changes'); $('main .page').append(bar); }
  bar.innerHTML = markup;
}
function removeChainFromDraft(path) {
  const d = settings.draft;
  const gone = (c) => c === path || c.startsWith(`${path}/`);
  d.hostedChains = (d.hostedChains || []).filter((c) => !gone(c));
  if (!d.hostedChains.length) delete d.hostedChains;
  for (const key of ['stateWindows', 'finalityWindows']) {
    if (isPlainObject(d[key])) { for (const c of Object.keys(d[key])) if (gone(c)) delete d[key][c]; if (!Object.keys(d[key]).length) delete d[key]; }
  }
  if (isPlainObject(d.peers)) { for (const c of Object.keys(d.peers)) if (gone(c)) delete d.peers[c]; }
  if (d.mine) for (const key of ['recipients', 'minWork']) {
    if (isPlainObject(d.mine[key])) { for (const c of Object.keys(d.mine[key])) if (gone(c)) delete d.mine[key][c]; if (!Object.keys(d.mine[key]).length) delete d.mine[key]; }
  }
}
async function applySettings() {
  const patch = mergePatch(settings.original, settings.draft);
  const btn = $('[data-apply]'); if (btn) { btn.disabled = true; btn.textContent = 'Applying…'; }
  try {
    const r = await api(node(), 'config', { method: 'PATCH', body: patch, contentType: 'application/merge-patch+json', accept: [500] });
    const body = r.data;
    settings.result = { applied: body.applied || [], failed: body.failed || [], restartRequired: body.restartRequired || [] };
    settings.original = body.config; settings.draft = clone(body.config); settings.review = null;
    snap().config = { config: body.config, restartRequired: body.restartRequired || [] };
    toast(body.failed && body.failed.length ? 'Part of the change failed' : 'Settings saved');
  } catch (e) {
    settings.result = { error: e.status === 409 ? "lattice.json was edited by hand since the node last wrote it. Restart the node to load that edit, then make this change again." : e.message, conflict: e.status === 409 };
    settings.review = null;
  }
  rerender();
  paintChrome();
  refresh(state.current);
}

// Access (tokens) -------------------------------------------------------------

VIEWS.access = {
  form: true,
  render() {
    const s = snap();
    return html`
      <div class="page-head"><div class="titles"><h1>Access</h1><p class="muted">Tokens let a dashboard or the <code>lattice</code> command manage this node from another machine.</p></div></div>
      ${restartBanner()}
      ${s.role === 'limited' ? html`<p class="prose">Only an admin token can see or change tokens; this one can't.</p>` : html`
      <section aria-labelledby="tok-h"><h2 id="tok-h">Tokens</h2><div id="tokens"><p class="empty">Reading…</p></div></section>
      <section aria-labelledby="new-h">
        <h2 id="new-h">Make a token</h2>
        <form id="new-token" class="stack">
          <div class="field"><label for="tok-name" class="label-line">Name</label><input id="tok-name" type="text" required pattern="[^/]+" placeholder="laptop, seller, monitoring" spellcheck="false"><span class="hint">So you can tell tokens apart later. No slashes.</span></div>
          <fieldset class="radio-group"><legend>It may</legend>
            <label><input type="radio" name="role" value="admin" checked> <span><strong>Do everything</strong><br><span class="soft small">Change settings, restart, wipe, make tokens.</span></span></label>
            <label><input type="radio" name="role" value="read"> <span><strong>Look, not change</strong><br><span class="soft small">Every read, nothing that changes the node.</span></span></label>
            <label><input type="radio" name="role" value="routes"> <span><strong>Use only some routes</strong><br><span class="soft small">For a program that needs one or two things.</span></span></label>
          </fieldset>
          <div class="field" id="routes-field" hidden><label for="tok-routes" class="label-line">Routes, one per line</label><textarea id="tok-routes" rows="3" placeholder="GET /hosted-chains&#10;POST /hosted-chains" spellcheck="false"></textarea></div>
          <div><button class="primary" type="submit">Make token</button></div>
        </form>
      </section>`}
      <section aria-labelledby="org-h">
        <h2 id="org-h">Dashboards allowed to connect</h2>
        <p class="prose small">${originsSentence(s)} <a href="#/settings?focus=access">Change in Settings</a>.</p>
      </section>`;
  },
  mount() { if (snap().role !== 'limited') loadTokens(); },
};
function originsSentence(s) {
  const list = (s.config && s.config.config && s.config.config.operatorAllowedOrigins) || [];
  return list.length ? `Besides this page, dashboards at ${list.join(', ')} may connect.` : 'Only this page may connect; no other dashboard is listed.';
}
async function loadTokens() {
  const box = $('#tokens'); if (!box) return;
  try {
    const r = await get(node(), 'tokens');
    box.innerHTML = r.tokens.length ? html`<ul class="list">${r.tokens.map((t) => html`<li><span class="grow"><strong>${t.name}</strong> <span class="muted small">${t.role === 'admin' ? 'Does everything' : t.role === 'read' ? 'Looks, not changes' : `Only ${(t.routes || []).join(', ')}`}</span></span><button type="button" class="small danger" data-revoke="${t.name}">Revoke</button></li>`)}</ul>`.s : html`<p class="empty">No tokens yet.</p>`.s;
  } catch (e) {
    box.innerHTML = html`<p class="empty">${e.status === 409 ? 'This node has no token file yet. Set operatorListen and operatorTokens in Settings, restart, then make tokens here.' : e.message}</p>`.s;
  }
}

// Restart and wipe ---------------------------------------------------------------

const restartSeconds = () => lget(`lattice.dashboard.restart.${state.current}`, 10);
VIEWS.danger = {
  form: true,
  render() {
    const s = snap(); const n = node();
    return html`
      <div class="page-head"><div class="titles"><h1>Restart and wipe</h1></div></div>
      ${restartBanner()}
      <section aria-labelledby="rs-h">
        <h2 id="rs-h">Restart the node</h2>
        <p class="prose">The node stops and starts again in the same process, reading its settings afresh. It's offline for about ${restartSeconds()} seconds; every chain then resumes where it was.${restartKeys(s).length ? ` This applies ${restartKeys(s).join(', ')}.` : ''}</p>
        <div><button type="button" data-restart>Restart…</button></div>
      </section>
      <section aria-labelledby="wp-h" class="ruled">
        <h2 id="wp-h">Wipe chain data</h2>
        <div class="prose"><p>Deletes everything this node stored for every chain, then restarts. It downloads Nexus again from its peers, and each hosted chain from that chain's peers. That can take a long time.</p>
        <p><strong>Kept:</strong> the node's identity, its settings, chain specs, tokens and logs. <strong>Deleted:</strong> blocks, state, and pinned content.</p></div>
        <div><button type="button" class="danger" data-wipe ${raw(s.config && s.config.flags ? 'disabled' : '')}>Wipe…</button></div>
        ${s.config && s.config.flags ? html`<p class="why-not">A wipe needs a node started with <code>lattice up</code>.</p>` : ''}
      </section>
      <p class="muted small">This node: ${n.name}</p>`;
  },
};

// Fleet ------------------------------------------------------------------------

function fleetTable() {
    const rows = state.nodes.map((n) => {
      const s = snap(n.id); const w = n.token ? worst(n.id) : null;
      const items = n.token ? attention(n.id) : [];
      const h = s.status;
      return { n, s, w, items, h, rank: !n.token ? 1 : w === 'bad' ? 0 : w === 'warn' ? 0.5 : 2 };
    }).sort((a, b) => a.rank - b.rank);
    return state.nodes.length > 1 ? html`<table class="fleet"><thead><tr><th>Node</th><th>Status</th><th class="hide-narrow num">Nexus height</th><th class="hide-narrow num">Last heard</th></tr></thead><tbody>
        ${rows.map(({ n, s, w, items, h }) => html`<tr class="${n.id === state.current ? 'current' : ''}">
          <td><a href="#/" data-switch-to="${n.id}"><strong>${n.name}</strong></a><br><span class="muted small">${n.url || 'this page'}</span></td>
          <td>${!n.token ? html`<span class="soft">Not signed in</span>` : w ? html`<span class="flagged">${raw(ICON[w])}<span>${items[0].what}${items.length > 1 ? html` <span class="muted">and ${items.length - 1} more</span>` : ''}</span></span>` : html`<span class="muted">${s.at ? '' : 'Reading…'}</span>`}</td>
          <td class="num hide-narrow">${h ? num(Number(h.height)) : '–'}</td>
          <td class="num hide-narrow">${s.at ? ago(s.at) : '–'}</td>
        </tr>`)}
      </tbody></table>` : '';
}
VIEWS.nodes = {
  form: true,
  update() { const box = $('#fleet-table'); if (box) box.innerHTML = part(fleetTable()); },
  render() {
    return html`
      <div class="page-head"><div class="titles"><h1>All nodes</h1><p class="muted">Problems first. Added nodes and their tokens are stored in this browser only.</p></div></div>
      <div id="fleet-table">${fleetTable()}</div>
      <section aria-labelledby="add-h">
        <h2 id="add-h">Add a node</h2>
        <p class="prose small">The node must run an operator listener and list this page's address, <code>${location.origin}</code>, under "Dashboards allowed to connect" in its settings.</p>
        <form id="add-node" class="stack">
          <div class="field"><label for="node-url" class="label-line">Operator listener address</label><input id="node-url" type="url" required placeholder="http://10.0.0.6:8090" spellcheck="false"></div>
          <div class="field"><label for="node-name" class="label-line">Name</label><input id="node-name" type="text" placeholder="Defaults to the address" spellcheck="false"></div>
          <div class="field"><label for="node-token" class="label-line">Token</label><input id="node-token" type="password" required spellcheck="false"></div>
          <label class="check"><input type="checkbox" id="node-remember"> Remember on this device</label>
          <p class="error" id="add-error" role="alert"></p>
          <div><button class="primary" type="submit">Add node</button></div>
        </form>
      </section>
      ${state.nodes.length > 1 ? html`<section aria-labelledby="rm-h"><h2 id="rm-h">Remove a node from this browser</h2><ul class="list">${state.nodes.filter((n) => n.id !== LOCAL_ID).map((n) => html`<li><span class="grow">${n.name}</span><button type="button" class="small" data-forget="${n.id}">Remove</button></li>`)}</ul>
        <p class="mt-1"><button type="button" data-signout-all>Sign out of all nodes</button></p><p class="soft small">Forgets every node and token this browser kept for the dashboard.</p></section>` : ''}`;
  },
};

// ---------------------------------------------------------------- dialogs

function dialog({ title, body, confirm, danger = false, typed = null, cancel = true }) {
  return new Promise((resolve) => {
    const d = document.createElement('dialog');
    d.innerHTML = html`<form method="dialog"><div class="dialog-body"><h2>${title}</h2>${raw(body.s || body)}
      ${typed ? html`<div class="field"><label for="typed" class="label-line">Type <strong>${typed}</strong> to confirm</label><input id="typed" type="text" autocomplete="off" spellcheck="false"></div>` : ''}
    </div><div class="dialog-actions">${cancel ? html`<button value="cancel" type="submit">Cancel</button>` : ''}<button value="ok" type="submit" class="${danger ? 'danger solid' : 'primary'}" ${raw(typed ? 'disabled' : '')}>${confirm}</button></div></form>`.s;
    document.body.append(d);
    if (typed) {
      const input = $('#typed', d); const ok = $('button[value="ok"]', d);
      input.addEventListener('input', () => { ok.disabled = input.value.trim() !== typed; });
    }
    d.addEventListener('close', () => { resolve(d.returnValue === 'ok'); d.remove(); });
    d.showModal();
    const first = typed ? $('#typed', d) : $('button[value="cancel"]', d) || $('button[value="ok"]', d);
    first.focus();
  });
}

async function restartFlow({ wipe = false } = {}) {
  const n = node();
  const ok = wipe
    ? await dialog({ title: `Wipe ${n.name}?`, body: html`<p class="soft">Every chain's blocks, state and pinned content on this node are deleted, and it restarts empty. It downloads everything again from its peers. Identity, settings, specs, tokens and logs stay.</p>`, confirm: 'Wipe and restart', danger: true, typed: n.name })
    : await dialog({ title: `Restart ${n.name}?`, body: html`<p class="soft">It's offline for about ${restartSeconds()} seconds while it restarts. Every chain resumes where it was${snap().mining && snap().mining.enabled ? ', and mining starts again' : ''}.${restartKeys(snap()).length ? ` It then uses the saved ${restartKeys(snap()).join(', ')}.` : ''}</p>`, confirm: 'Restart' });
  if (!ok) return;
  // Back means a new process: its start time differs, or it was seen down.
  const startOf = async () => parseMetrics(await get(n, 'metrics', { text: true, timeout: 2000 })).start;
  const before = await startOf().catch(() => undefined);
  const started = Date.now();
  try {
    await api(n, wipe ? 'wipe' : 'restart', { method: 'POST', body: {} });
  } catch (e) { toast(`${wipe ? 'Wipe' : 'Restart'} refused: ${e.message}`); return; }
  const overlay = document.createElement('dialog');
  overlay.innerHTML = html`<div class="dialog-body"><h2>${wipe ? 'Wiping and restarting' : 'Restarting'} ${n.name}</h2><p class="soft" id="rs-status">Waiting for the node to stop…</p></div>`.s;
  document.body.append(overlay); overlay.showModal();
  const status = $('#rs-status', overlay);
  await new Promise((r) => setTimeout(r, 1200));
  let back = false; let cookieChanged = false; let seenDown = false;
  while (Date.now() - started < 180000) {
    try {
      const now = await startOf();
      if (seenDown || (before != null && now != null && now !== before)) { back = true; break; }
    } catch (e) {
      if (e.status === 401) { cookieChanged = true; back = true; break; }
      seenDown = true;
      status.textContent = `Offline for ${duration(Date.now() - started)}. Waiting for it to answer…`;
    }
    await new Promise((r) => setTimeout(r, 1000));
  }
  overlay.close(); overlay.remove();
  const took = Math.max(2, Math.round((Date.now() - started) / 1000));
  if (back && !wipe) lset(`lattice.dashboard.restart.${n.id}`, took);
  if (!back) { toast("The node hasn't come back after 3 minutes. Check its log or supervisor."); return; }
  if (cookieChanged || !n.url) {
    // The loopback cookie changes at every start.
    try { await get(n, 'status'); } catch (e) { if (e.status === 401) { n.token = null; signInReason = 'The node restarted and made a new cookie. Paste the new one.'; saveNodes(); paint(true); return; } }
  }
  if (wipe) state.snaps[n.id] = blankSnap();
  settings.original = null; settings.result = null;
  toast(wipe ? `Wiped. ${n.name} is syncing again from its peers.` : `Restarted in ${took} s.`);
  await refresh(n.id);
  paint(true);
}

// ---------------------------------------------------------------- events

document.addEventListener('click', async (e) => {
  const t = e.target.closest('button, a');
  if (!t) return;
  const ds = t.dataset;
  if (ds.copy) { copy(ds.copy); return; }
  if ('signout' in ds) { signOut(); return; }
  if ('signoutAll' in ds) { signOutAll(); return; }
  if ('restart' in ds) { restartFlow(); return; }
  if ('wipe' in ds) { restartFlow({ wipe: true }); return; }
  if (ds.action === 'retry') { refresh(state.current); return; }
  if ('gotoFleet' in ds) { location.hash = '#/nodes'; return; }
  if (ds.switchTo) { switchTo(ds.switchTo); return; }
  if (ds.logfile) { location.hash = `#/logs?file=${ds.logfile}`; return; }
  if (ds.loglevel) { logs.level = ds.loglevel; $$('[data-loglevel]').forEach((b) => b.setAttribute('aria-pressed', String(b.dataset.loglevel === logs.level))); paintLog(); paintLogMeta(); return; }
  if ('logfollow' in ds) { logs.follow = !logs.follow; if (logs.follow) { logs.fresh = 0; paintLog(); } paintLogMeta(); return; }
  if ('lognew' in ds) { logs.follow = true; logs.fresh = 0; paintLog(); paintLogMeta(); return; }
  if (ds.mine) {
    try {
      await api(node(), 'config', { method: 'PATCH', body: { mine: { enabled: ds.mine === 'on' } }, contentType: 'application/merge-patch+json' });
      toast(ds.mine === 'on' ? 'Mining started' : 'Mining stopped'); settings.original = null;
    } catch (err) { toast(err.status === 409 ? 'lattice.json was edited by hand; restart the node first.' : `Couldn't change mining: ${err.message}`); }
    await refresh(state.current); paint(true); return;
  }
  if (ds.unhost) {
    const path = ds.unhost;
    if (!await dialog({ title: `Stop hosting ${lastSegment(path)}?`, body: html`<p class="soft">This node stops following ${path} now and drops it from its settings, with the recipient and peers set for it. What it stored stays: hosting it again resumes it.</p>`, confirm: 'Stop hosting', danger: true })) return;
    try {
      const r = await api(node(), `hosted-chains?chainPath=${encodeURIComponent(path)}`, { method: 'DELETE', accept: [500] });
      toast(r.data.failed && r.data.failed.length ? `Part of it failed: ${r.data.failed[0].error}` : `Stopped hosting ${path}`);
      settings.original = null;
      await refresh(state.current); location.hash = '#/';
    } catch (err) { toast(`Couldn't stop hosting: ${err.message}`); }
    return;
  }
  if (ds.unpin) {
    if (!await dialog({ title: 'Unpin this content?', body: html`<p class="soft">The node stops keeping ${shortCid(ds.unpin)} for you. It's deleted unless something else the node keeps uses it.</p>`, confirm: 'Unpin', danger: true })) return;
    try { await api(node(), `pins/${encodeURIComponent(ds.unpin)}`, { method: 'DELETE' }); toast('Unpinned'); VIEWS.storage.mount(); } catch (err) { toast(`Couldn't unpin: ${err.message}`); }
    return;
  }
  if (ds.revoke) {
    if (!await dialog({ title: `Revoke ${ds.revoke}?`, body: html`<p class="soft">Anything using this token is refused from its next request. If it's the token you signed in with, you'll be signed out.</p>`, confirm: 'Revoke', danger: true })) return;
    try { await api(node(), `tokens/${encodeURIComponent(ds.revoke)}`, { method: 'DELETE' }); toast(`Revoked ${ds.revoke}`); loadTokens(); } catch (err) { toast(`Couldn't revoke: ${err.message}`); if (err.status === 401) paint(true); }
    return;
  }
  if (ds.forget) {
    state.nodes = state.nodes.filter((n) => n.id !== ds.forget);
    clearTimeout(state.timers[ds.forget]); store.set(local, SNAP_KEY(ds.forget), null); sset(SNAP_KEY(ds.forget), null);
    delete state.snaps[ds.forget];
    if (state.current === ds.forget) state.current = LOCAL_ID;
    saveNodes(); $('#app').innerHTML = ''; paint(true); return;
  }
  // settings
  if (ds.tab) { settings.tab = ds.tab; settings.rawError = null; rerender(); return; }
  if ('review' in ds) { settings.review = true; rerender(); $('#rv-h') && $('#rv-h').scrollIntoView({ block: 'center' }); return; }
  if ('cancelReview' in ds) { settings.review = null; rerender(); return; }
  if ('discard' in ds) { settings.draft = clone(settings.original); settings.review = null; settings.rawError = null; rerender(); return; }
  if ('apply' in ds) { applySettings(); return; }
  if ('dismissResult' in ds) { settings.result = null; rerender(); return; }
  if (ds.removeChain) { removeChainFromDraft(ds.removeChain); rerender(); return; }
});

document.addEventListener('change', (e) => {
  if (e.target.matches('[data-switch]')) switchTo(e.target.value);
  if (e.target.name === 'role') { const f = $('#routes-field'); if (f) f.hidden = e.target.value !== 'routes'; }
});

document.addEventListener('submit', async (e) => {
  const f = e.target;
  if (f.id === 'signin') { e.preventDefault(); signIn($('#token').value, $('#remember').checked); return; }
  if (f.matches('[data-add-chain]')) {
    e.preventDefault();
    const input = $('#add-chain'); const path = input.value.trim().replace(/\/+$/, '');
    const d = settings.draft; const hosted = d.hostedChains || [];
    if (!/^Nexus(\/[^/\s]+)+$/.test(path)) { toast('A chain path starts with Nexus/, like Nexus/Name'); return; }
    if (hosted.includes(path)) { toast(`${path} is already listed`); return; }
    const parent = parentOf(path);
    if (parent !== 'Nexus' && !hosted.includes(parent)) { toast(`Host ${parent} first: a chain's parent must be hosted`); return; }
    d.hostedChains = [...hosted, path].sort((a, b) => a.split('/').length - b.split('/').length || a.localeCompare(b));
    rerender(); const again = $('#add-chain'); if (again) again.focus();
    return;
  }
  if (f.id === 'new-token') {
    e.preventDefault();
    const name = $('#tok-name').value.trim();
    const role = f.querySelector('input[name="role"]:checked').value;
    const body = role === 'routes' ? { name, routes: $('#tok-routes').value.split('\n').map((x) => x.trim()).filter(Boolean) } : { name, role };
    try {
      const r = await get(node(), 'tokens', { method: 'POST', body });
      f.reset(); $('#routes-field').hidden = true;
      loadTokens();
      await dialog({ title: `Token ${r.name}`, body: html`<p class="soft">Copy it now. It isn't shown again: the node keeps only a fingerprint of it.</p><div class="secret"><code>${r.token}</code><button type="button" data-copy="${r.token}">Copy</button></div>`, confirm: 'Done', cancel: false });
    } catch (err) { toast(err.status === 409 ? (err.message.includes('exists') ? `A token named ${name} exists; revoke it first.` : 'This node has no token file yet.') : `Couldn't make the token: ${err.message}`); }
    return;
  }
  if (f.id === 'add-node') {
    e.preventDefault();
    const url = $('#node-url').value.trim().replace(/\/+$/, '');
    const n = { id: `n${Date.now().toString(36)}`, name: $('#node-name').value.trim() || new URL(url).host, url, token: cleanToken($('#node-token').value), remember: $('#node-remember').checked };
    const err = $('#add-error');
    try { await get(n, 'status'); } catch (ex) {
      err.textContent = ex.status === 401 ? "That node doesn't know this token." : ex.status === 403 ? `That node refused this page. List ${location.origin} under "Dashboards allowed to connect" on it, then restart it.` : `${ex.message} If it's running, it may not list ${location.origin} as an allowed dashboard.`;
      return;
    }
    state.nodes.push(n); saveNodes();
    state.snaps[n.id] = blankSnap();
    refresh(n.id).then(() => schedule(n.id));
    toast(`Added ${n.name}`);
    $('#app').innerHTML = ''; paint(true);
  }
});

function switchTo(id) {
  if (!node(id)) return;
  state.current = id; sset(CURRENT_KEY, id);
  settings.original = null; settings.result = null; logs.lines = [];
  for (const n of state.nodes) if (n.token) schedule(n.id);
  $('#app').innerHTML = '';
  location.hash = '#/';
  paint(true);
  if (node().token) refresh(id);
}

// ---------------------------------------------------------------- start

state.nodes = loadNodes();
restoreTokens();
state.current = node(sget(CURRENT_KEY, LOCAL_ID)) ? sget(CURRENT_KEY, LOCAL_ID) : LOCAL_ID;
state.route = parseRoute();
for (const n of state.nodes) restoreSnap(n.id);
paint(true);
startPolling();
})();
