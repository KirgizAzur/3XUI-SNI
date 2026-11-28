import { spawn } from 'node:child_process';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const argv = process.argv.slice(2);
const url = argv[0];
const out = argv[1];
const opt = (name, def) => {
  const hit = argv.find((a) => a.startsWith('--' + name + '='));
  return hit ? hit.slice(name.length + 3) : def;
};
const flag = (name) => argv.includes('--' + name);
const W = Number(opt('w', 1440));
const H = Number(opt('h', 900));
const WAIT = Number(opt('wait', 2600));
const FULL = flag('full');
const EVAL = opt('eval', '');

const profile = await fs.mkdtemp(path.join(os.tmpdir(), 'pp-chrome-'));
const chrome = spawn(CHROME, [
  '--headless=new',
  '--remote-debugging-port=0',
  '--user-data-dir=' + profile,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-gpu',
  '--hide-scrollbars',
  '--disable-extensions',
  '--force-device-scale-factor=1',
  '--window-size=' + W + ',' + H,
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
const logs = [];
ws.addEventListener('message', (ev) => {
  const msg = JSON.parse(ev.data);
  if (msg.id && pending.has(msg.id)) {
    const { resolve, reject } = pending.get(msg.id);
    pending.delete(msg.id);
    msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
    return;
  }
  if (msg.method === 'Runtime.exceptionThrown') {
    const d = msg.params.exceptionDetails;
    logs.push('EXCEPTION: ' + (d.exception?.description || d.text));
  }
  if (msg.method === 'Runtime.consoleAPICalled') {
    const t = msg.params.type;
    if (t === 'error' || t === 'warning') {
      logs.push(t.toUpperCase() + ': ' + msg.params.args.map((a) => a.value ?? a.description ?? a.type).join(' '));
    }
  }
  if (msg.method === 'Log.entryAdded') {
    const e = msg.params.entry;
    if (e.level === 'error' && !/favicon/i.test(e.text)) logs.push('LOG: ' + e.text + ' ' + (e.url || ''));
  }
});
const send = (method, params = {}) => new Promise((resolve, reject) => {
  const mid = ++id;
  pending.set(mid, { resolve, reject });
  ws.send(JSON.stringify({ id: mid, method, params }));
});

await send('Page.enable');
await send('Runtime.enable');
await send('Log.enable');
await send('Emulation.setDeviceMetricsOverride', { width: W, height: H, deviceScaleFactor: 1, mobile: W < 700 });
await send('Page.navigate', { url });
await new Promise((r) => setTimeout(r, WAIT));

let evalOut = null;
if (EVAL) {
  const r = await send('Runtime.evaluate', { expression: EVAL, awaitPromise: true, returnByValue: true });
  evalOut = r.result?.value ?? r.result?.description ?? null;
}

const metrics = await send('Page.getLayoutMetrics');
const fullH = Math.ceil(metrics.cssContentSize?.height || H);
const crop = opt('crop', '');
const shotParams = { format: 'png' };
if (crop) {
  const [x, y, cw, ch] = crop.split(',').map(Number);
  shotParams.clip = { x, y, width: cw, height: ch, scale: 1 };
  shotParams.captureBeyondViewport = true;
} else if (FULL) {
  shotParams.captureBeyondViewport = true;
  shotParams.clip = { x: 0, y: 0, width: W, height: Math.min(fullH, 20000), scale: 1 };
}
const shot = await send('Page.captureScreenshot', shotParams);
await fs.writeFile(out, Buffer.from(shot.data, 'base64'));

console.log(JSON.stringify({ out, height: fullH, logs, evalOut }, null, 2));
ws.close();
chrome.kill();
setTimeout(() => process.exit(0), 250);
