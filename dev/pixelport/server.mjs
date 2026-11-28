import http from 'node:http';
import fs from 'node:fs/promises';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..', 'templates', 'pixelport');
const args = process.argv.slice(2);
const getArg = (name, def) => {
  const i = args.indexOf('--' + name);
  return i > -1 && args[i + 1] ? args[i + 1] : def;
};
const PORT = Number(getArg('port', process.env.PORT || 8787));
const RATE_MBPS = Number(getArg('rate', 8)); // per-connection cap, Mbit/s
const CHUNK = 64 * 1024;

const stats = { connections: 0, totalBytes: 0, startedAt: Date.now(), requests: 0 };

const NOISE = Buffer.alloc(CHUNK, 0);
for (let i = 0; i < NOISE.length; i += 4) NOISE.writeUInt32LE((Math.random() * 0xffffffff) >>> 0, i);

function cors(res) {
  res.setHeader('Access-Control-Allow-Origin', '*');
  res.setHeader('Access-Control-Allow-Headers', '*');
  res.setHeader('Access-Control-Allow-Methods', 'GET,HEAD,OPTIONS');
  res.setHeader('Timing-Allow-Origin', '*');
}

function stream(req, res) {
  if (req.method === 'OPTIONS') { cors(res); res.writeHead(204); return res.end(); }
  cors(res);
  res.writeHead(200, {
    'Content-Type': 'application/octet-stream',
    'Cache-Control': 'no-store, no-transform',
    'X-Accel-Buffering': 'no',
    'X-Pixelport-Edge': 'MSK-01',
    'Content-Disposition': 'inline'
  });

  const rate = (RATE_MBPS * 1024 * 1024) / 8; // bytes/s
  const delay = Math.max(1, Math.round((CHUNK / rate) * 1000));
  let done = false;
  stats.connections++;

  const stop = () => {
    if (done) return;
    done = true;
    stats.connections--;
    try { res.end(); } catch {}
  };
  req.on('close', stop);
  res.on('error', stop);

  let sent = 0;
  const t0 = Date.now();
  const tick = () => {
    if (done) return;
    try {
      res.write(NOISE);
      stats.totalBytes += CHUNK;
      sent++;
    } catch { return stop(); }
    if (res.writableLength > 4 * 1024 * 1024) {
      res.once('drain', tick);
      return;
    }
    const target = sent * delay;
    const wait = Math.max(1, target - (Date.now() - t0));
    setTimeout(tick, wait);
  };
  tick();
}

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg', '.svg': 'image/svg+xml', '.webm': 'video/webm',
  '.mp4': 'video/mp4', '.ico': 'image/x-icon'
};

// то же, что создаёт install.sh через truncate: заявленный вес, нули внутри
const PACKS = {
  'PIXEL_RUNNER': 1503238554,
  'DUNGEON_OF_BYTES': 2254857830,
  'NEON_DRIFT_92': 901775360,
  'SIBERIA_TRADER': 1181116006,
  'GHOST_CARTRIDGE': 671088640,
  'ROUTE_7_BERLIN': 1932735283
};
const ZEROS = Buffer.alloc(65536);

function packFile(req, res, name) {
  cors(res);
  const base = name.replace(/\.(torent|iso)$/i, '');
  const size = PACKS[base];
  if (!size) { res.writeHead(404, { 'Content-Type': 'text/plain' }); return res.end('404'); }

  // как в install.sh: .torent начинается с bencode-заголовка, .iso — с нулей
  const head = /\.torent$/i.test(name)
    ? Buffer.from('d8:announce45:udp://tracker.pixelport.example:6969/announce4:infod6:lengthi' +
        size + 'e4:name' + Buffer.byteLength(name) + ':' + name +
        '12:piece lengthi1048576e6:pieces20:')
    : Buffer.alloc(0);

  res.writeHead(200, {
    'Content-Type': 'application/octet-stream',
    'Content-Length': String(size),
    'Cache-Control': 'no-store',
    'Accept-Ranges': 'none'
  });
  if (req.method === 'HEAD') return res.end();

  let sent = 0, closed = false;
  res.on('close', () => { closed = true; });
  if (head.length && head.length <= size) {
    res.write(head);
    sent = head.length;
    stats.totalBytes += sent;
  }
  const tick = () => {
    if (closed) return;
    const n = Math.min(ZEROS.length, size - sent);
    if (n <= 0) return res.end();
    sent += n;
    stats.totalBytes += n;
    const ok = res.write(n === ZEROS.length ? ZEROS : ZEROS.subarray(0, n));
    if (ok) setImmediate(tick);
    else res.once('drain', tick);
  };
  tick();
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  stats.requests++;

  if (url.pathname === '/api/health') {
    cors(res);
    res.writeHead(200, { 'Content-Type': 'application/json' });
    return res.end(JSON.stringify({ ...stats, uptime: (Date.now() - stats.startedAt) / 1000, rateMbps: RATE_MBPS }));
  }
  if (url.pathname.startsWith('/stream/')) return stream(req, res);

  if (url.pathname.startsWith('/dl/')) return packFile(req, res, decodeURIComponent(url.pathname.slice(4)));

  let file = url.pathname === '/' ? '/index.html' : url.pathname;
  file = path.normalize(file).replace(/^(\.\.[/\\])+/, '');
  const full = path.join(ROOT, file);
  if (!full.startsWith(ROOT)) { res.writeHead(403); return res.end('forbidden'); }
  try {
    const data = await fs.readFile(full);
    cors(res);
    res.writeHead(200, {
      'Content-Type': MIME[path.extname(full)] || 'application/octet-stream',
      'Cache-Control': 'no-cache',
      'X-Pixelport-Origin': 'FRA-01'
    });
    res.end(data);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
    res.end('404');
  }
});

setInterval(() => {
  if (!stats.totalBytes) return;
  console.log(`[pixelport] live conns=${stats.connections} served=${(stats.totalBytes / 1048576).toFixed(1)} MB`);
}, 5000).unref();

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[pixelport] cover site  http://127.0.0.1:${PORT}/`);
  console.log(`[pixelport] stream      http://127.0.0.1:${PORT}/stream/8bit.bin`);
  console.log(`[pixelport] ${RATE_MBPS} Mbit/s per connection, ${os.platform()}`);
});
