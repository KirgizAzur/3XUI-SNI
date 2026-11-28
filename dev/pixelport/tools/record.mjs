// Записывает анимацию сцены в настоящий webm через MediaRecorder.
//   node record.mjs <url> <outDir> [seconds]
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const url = process.argv[2];
const outDir = process.argv[3];
const SECS = Number(process.argv[4] || 30);
await fs.mkdir(outDir, { recursive: true });
const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'pp-rec2-'));

const chrome = spawn(CHROME, ['--headless=new', '--remote-debugging-port=0',
  '--user-data-dir=' + profile, '--no-first-run', '--disable-gpu',
  '--hide-scrollbars', '--window-size=1440,900',
  '--autoplay-policy=no-user-gesture-required', 'about:blank'], { stdio: 'ignore' });

async function waitPort(file) {
  for (let i = 0; i < 150; i++) {
    try { const t = (await fs.readFile(file, 'utf8')).trim(); if (t) return t.split('\n')[0].trim(); } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('no port');
}
const port = await waitPort(path.join(profile, 'DevToolsActivePort'));
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = list.find((t) => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r, { once: true }));
let id = 0; const pending = new Map(); const events = [];
ws.addEventListener('message', (ev) => {
  const m = JSON.parse(ev.data);
  if (m.id && pending.has(m.id)) { const p = pending.get(m.id); pending.delete(m.id); m.error ? p.reject(new Error(JSON.stringify(m.error))) : p.resolve(m.result); return; }
  if (m.method && m.method.startsWith('Browser.download')) events.push(m);
});
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const mid = ++id; pending.set(mid, { resolve, reject });
  ws.send(JSON.stringify({ id: mid, method, params }));
});

await send('Page.enable');
await send('Runtime.enable');
await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: outDir, eventsEnabled: true });
await send('Page.navigate', { url });
await new Promise((r) => setTimeout(r, 3000));

// кадр для постера
const poster = await send('Runtime.evaluate', {
  expression: `(() => {
    const src = document.getElementById('runner');
    const c = document.createElement('canvas');
    c.width = 1280; c.height = 720;
    const g = c.getContext('2d');
    g.imageSmoothingEnabled = false;
    g.drawImage(src, 0, 0, 1280, 720);
    return c.toDataURL('image/jpeg', 0.86);
  })()`,
  returnByValue: true
});
const posterData = poster.result.value;
await fs.writeFile(path.join(outDir, 'poster.jpg'), Buffer.from(posterData.split(',')[1], 'base64'));

const record = `(async () => {
  const src = document.getElementById('runner');
  const c = document.createElement('canvas');
  c.width = 1280; c.height = 720;
  const g = c.getContext('2d');
  g.imageSmoothingEnabled = false;
  let running = true;
  const pump = () => {
    if (!running) return;
    g.drawImage(src, 0, 0, 1280, 720);
    requestAnimationFrame(pump);
  };
  requestAnimationFrame(pump);
  const stream = c.captureStream(30);
  const rec = new MediaRecorder(stream, { mimeType: 'video/webm;codecs=vp8', videoBitsPerSecond: 1400000 });
  const chunks = [];
  rec.ondataavailable = (e) => { if (e.data.size) chunks.push(e.data); };
  const stopped = new Promise((r) => { rec.onstop = r; });
  rec.start();
  await new Promise((r) => setTimeout(r, ${SECS * 1000}));
  rec.stop(); running = false; await stopped;
  const blob = new Blob(chunks, { type: 'video/webm' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob); a.download = 'pixel-runner.webm';
  document.body.appendChild(a); a.click();
  return JSON.stringify({ size: blob.size });
})()`;

const r = await send('Runtime.evaluate', { expression: record, awaitPromise: true, returnByValue: true, timeout: (SECS + 30) * 1000 });
console.log('recorded:', r.result && r.result.value);
await new Promise((r) => setTimeout(r, 2500));
for (const f of await fs.readdir(outDir)) {
  console.log(' ', f, (await fs.stat(path.join(outDir, f))).size);
}
ws.close(); chrome.kill(); setTimeout(() => process.exit(0), 200);
