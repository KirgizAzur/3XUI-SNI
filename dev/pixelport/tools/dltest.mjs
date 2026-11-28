// Проверка скачивания: жмём кнопку на карточке и смотрим, что реально легло на диск.
//   node tools/dltest.mjs <url> <downloadDir> [buttonIndex] [--timeout=180]
import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const argv = process.argv.slice(2);
const url = argv[0];
const outDir = argv[1];
const idx = Number(argv[2] || 0);
const toArg = argv.find((a) => a.startsWith('--timeout='));
const TIMEOUT = toArg ? Number(toArg.split('=')[1]) * 1000 : 180000;

await fs.mkdir(outDir, { recursive: true });
const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'pp-dl-'));
const chrome = spawn(CHROME, [
  '--headless=new',
  '--remote-debugging-port=0',
  '--user-data-dir=' + profile,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-gpu',
  '--disable-extensions',
  '--window-size=1440,900',
  'about:blank'
], { stdio: 'ignore' });

async function waitPort(file) {
  for (let i = 0; i < 150; i++) {
    try {
      const txt = (await fs.readFile(file, 'utf8')).trim();
      if (txt) return txt.split('\n')[0].trim();
    } catch {}
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('DevToolsActivePort not found');
}

const port = await waitPort(path.join(profile, 'DevToolsActivePort'));
const list = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
const page = list.find((t) => t.type === 'page');
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => ws.addEventListener('open', r, { once: true }));

let id = 0;
const pending = new Map();
const events = [];
ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    return;
  }
  if (msg.method && msg.method.startsWith('Browser.download')) events.push(msg);
});
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const mid = ++id;
  pending.set(mid, { resolve, reject });
  ws.send(JSON.stringify({ id: mid, method, params }));
});

await send('Page.enable');
await send('Runtime.enable');
await send('Browser.setDownloadBehavior', { behavior: 'allow', downloadPath: outDir, eventsEnabled: true });
await send('Page.navigate', { url });
await new Promise((r) => setTimeout(r, 2500));

// состояние service worker (в этой версии его быть не должно)
const swReady = await send('Runtime.evaluate', {
  expression: `(async()=>{
    try {
      const r = await navigator.serviceWorker.getRegistration('/');
      return JSON.stringify({active: !!(r && r.active)});
    } catch(e) { return JSON.stringify({err:String(e)}); }
  })()`,
  awaitPromise: true, returnByValue: true, timeout: 5000
});
console.log('sw:', swReady.result.value);

await send('Runtime.evaluate', {
  expression: `(document.querySelectorAll('[data-dl]')[${idx}].click(), 'clicked')`,
  returnByValue: true
});

const t0 = Date.now();
let last = null;
while (Date.now() - t0 < TIMEOUT) {
  await new Promise((r) => setTimeout(r, 500));
  const prog = events.filter((e) => e.method === 'Browser.downloadProgress');
  if (prog.length) last = prog[prog.length - 1].params;
  if (last && (last.state === 'completed' || last.state === 'canceled')) break;
}

const willBegin = events.find((e) => e.method === 'Browser.downloadWillBegin');
const files = await fs.readdir(outDir);
const report = { willBegin: willBegin ? willBegin.params : null, last, files: [] };
for (const f of files) {
  const st = await fs.stat(path.join(outDir, f));
  const fh = await fs.open(path.join(outDir, f), 'r');
  const head = Buffer.alloc(96);
  await fh.read(head, 0, 96, 0);
  await fh.close();
  report.files.push({ name: f, bytes: st.size, head: head.toString('latin1').slice(0, 80) });
}

// опционально: после завершения нажать другую карточку и убедиться,
// что кнопки не остались заблокированными
const secondArg = argv.find((a) => a.startsWith('--second='));
if (secondArg) {
  const sIdx = Number(secondArg.split('=')[1]);
  const r = await send('Runtime.evaluate', {
    expression: `(async()=>{
      await new Promise(x=>setTimeout(x,3200));
      const b=document.querySelectorAll('[data-dl]')[${sIdx}];
      b.click(); await new Promise(x=>setTimeout(x,900));
      return JSON.stringify({text:b.textContent, disabled:b.disabled});
    })()`,
    awaitPromise: true, returnByValue: true
  });
  report.second = JSON.parse(r.result.value);
}
console.log(JSON.stringify(report, null, 2));

ws.close();
chrome.kill();
setTimeout(() => process.exit(0), 300);
