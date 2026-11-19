import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, rm } from 'node:fs/promises';
import { createServer } from 'node:http';
import { once } from 'node:events';
import { extname, join, resolve } from 'node:path';
import { tmpdir } from 'node:os';
import { setTimeout as delay } from 'node:timers/promises';

// Run against a Vite build or the web directory copied from a release bundle.
const assets = resolve(process.argv[2] || 'build/assets/web');
const mountOnly = process.argv.includes('--mount-only');
const pages = ['/', '/config', '/troubleshooting', '/apps', '/pin', '/password', '/welcome'];
const profile = await mkdtemp(join(tmpdir(), 'moonwalk-browser-'));
const settings = {
  status: true, platform: 'macos', version: 'engine', host_version: 'host',
  source_revision: 'synthetic-source', sunshine_name: 'Example Mac', extra_setting: 'retained',
};
let loadStatus = 200;
let localeStatus = 200;
let selectedLocale = 'en';
let saveReply = { status: false };
let restartReply = { status: false };
const saves = [];
let restarts = 0;
let appTag = '"initial"';
let acceptAppChanges = false;
const apps = [{name: 'Example Desktop'}, {name: 'Missing cover', 'image-path': 'missing.png'}];
const appChanges = [];
const pairingRequests = [];
let pendingPairings = [];
let pairingReply = { status: false };
const contentTypes = {
  '.html': 'text/html', '.js': 'application/javascript', '.css': 'text/css',
  '.json': 'application/json', '.png': 'image/png', '.svg': 'image/svg+xml',
};
function sendJSON(res, body, status = 200, headers = {}) {
  res.writeHead(status, {'Content-Type': 'application/json', ...headers}).end(JSON.stringify(body));
}
const server = createServer(async (req, res) => {
  const path = new URL(req.url, 'http://localhost').pathname;
  try {
    if (path === '/api/configLocale') {
      if (localeStatus !== 200) return res.writeHead(localeStatus).end('Temporarily unavailable');
      return sendJSON(res, { locale: selectedLocale });
    }
    if (path === '/api/config' && req.method === 'POST') {
      let body = '';
      for await (const chunk of req) body += chunk;
      saves.push(JSON.parse(body));
      await delay(160);
      return sendJSON(res, saveReply);
    }
    if (path === '/api/config') return sendJSON(res, settings, loadStatus);
    if (path === '/api/restart' && req.method === 'POST') {
      restarts++;
      await delay(160);
      if (restartReply === 'drop') {
        res.writeHead(200, {'Content-Type': 'application/json', 'Content-Length': '64'}).write('{');
        await delay(100);
        return req.socket.destroy();
      }
      return sendJSON(res, restartReply);
    }
    if (path === '/api/clients/list') return sendJSON(res, { status: true, named_certs: [] });
    if (path === '/api/pending-pairings') return sendJSON(res, { status: true, pending: pendingPairings });
    if (path === '/api/pin' && req.method === 'POST') {
      let body = '';
      for await (const chunk of req) body += chunk;
      pairingRequests.push(JSON.parse(body));
      await delay(160);
      if (pairingReply === 'drop') {
        res.writeHead(200, {'Content-Type': 'application/json', 'Content-Length': '64'}).write('{');
        await delay(100);
        return req.socket.destroy();
      }
      return sendJSON(res, pairingReply);
    }
    if (path === '/api/apps' && req.method === 'GET') {
      return sendJSON(res, { apps, env: {} }, 200, {'ETag': appTag, 'Cache-Control': 'no-store'});
    }
    if ((path === '/api/apps' && req.method === 'POST') ||
        (path.startsWith('/api/apps/') && req.method === 'DELETE')) {
      let body = '';
      for await (const chunk of req) body += chunk;
      const tag = req.headers['if-match'];
      const edit = body ? JSON.parse(body) : null;
      appChanges.push({method: req.method, tag, edit});
      if (tag !== appTag) return res.writeHead(412).end();
      if (!acceptAppChanges) return sendJSON(res, { status: false });
      if (edit) apps[edit.index] = {name: edit.name};
      else apps.splice(Number(path.split('/').at(-1)), 1);
      appTag = '"updated"';
      return sendJSON(res, { status: true });
    }
    if (path.startsWith('/api/covers/')) return res.writeHead(404).end();
    if (path === '/api/logs') return res.end('');
    if (path.startsWith('/api/')) return sendJSON(res, { status: true });
    if (!(pages.includes(path) || path.startsWith('/assets/'))) return res.writeHead(404).end();
    const name = pages.includes(path) ? (path === '/' ? 'index' : path.slice(1)) + '.html' : path.slice(1);
    const data = await readFile(join(assets, name));
    res.writeHead(200, {'Content-Type': contentTypes[extname(name)] || 'application/octet-stream'}).end(data);
  } catch {
    res.writeHead(404).end();
  }
});
await new Promise((ok) => server.listen(0, '127.0.0.1', ok));
const origin = 'http://127.0.0.1:' + server.address().port;
const browser = spawn(process.env.FIREFOX || 'firefox', ['--headless', '--no-remote', '--profile', profile,
  '--remote-debugging-port', '0', 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
let diagnostics = '';
let launchError;
browser.once('error', error => { launchError = error; });
let ws;
let messageId = 0;
const messages = new Map();
const jsErrors = [];
function cmd(method, params = {}) {
  const id = ++messageId;
  return new Promise((ok, fail) => {
    const timeout = setTimeout(() => {
      messages.delete(id);
      fail(new Error(method + ' timed out'));
    }, 5000);
    messages.set(id, (result, error) => {
      clearTimeout(timeout);
      if (error) fail(new Error(JSON.stringify(error)));
      else ok(result);
    });
    ws.send(JSON.stringify({ id, method, params }));
  });
}
async function until(run, label, max = 5000) {
  const deadline = Date.now() + max;
  while (Date.now() < deadline) {
    const result = await run();
    if (result) return result;
    await delay(40);
  }
  throw new Error(label + ' timed out. Browser JavaScript errors: ' + JSON.stringify(jsErrors));
}

try {
  browser.stderr.on('data', (chunk) => { diagnostics += chunk; });
  const address = await until(() => {
    if (launchError) throw launchError;
    return diagnostics.match(/WebDriver BiDi listening on (ws:\/\/127\.0\.0\.1:\d+)/)?.[1];
  }, 'Firefox startup', 10000);
  ws = new WebSocket(address + '/session');
  await once(ws, 'open');
  ws.addEventListener('message', ({data}) => {
    const msg = JSON.parse(data);
    if (msg.method === 'log.entryAdded' && msg.params.type === 'javascript' && msg.params.level === 'error') {
      jsErrors.push(msg.params.text);
    }
    if (messages.has(msg.id)) {
      messages.get(msg.id)(msg.result, msg.type === 'error' ? msg : null);
      messages.delete(msg.id);
    }
  });
  await cmd('session.new', {capabilities:{alwaysMatch:{}}});
  await cmd('session.subscribe', { events: ['log.entryAdded'] });
  const {context} = await cmd('browsingContext.create', {type:'tab'});
  async function evaluate(expression) {
    const r = await cmd('script.evaluate', {expression, target:{context}, awaitPromise:true});
    assert.equal(r.type, 'success', JSON.stringify(r.exceptionDetails));
    return r.result.value;
  }
  async function visit(path) {
    await cmd('browsingContext.navigate', { context, url: origin + path, wait: 'complete' });
  }
  async function openPage(path) {
    await visit(path);
    const mounted = path === '/welcome' ?
      'document.body.hasAttribute("data-v-app") && !!document.querySelector("h1")' :
      'document.querySelector(".navbar-brand")?.textContent.trim() === "Moonwalk Host"';
    await until(() => evaluate(mounted), path + ' page mount');
  }
  async function click(text) {
    const btn = 'Array.from(document.querySelectorAll("button")).find(b => b.textContent.trim() === ' + JSON.stringify(text) + ')';
    await until(() => evaluate('!!(' + btn + ') && !(' + btn + ').disabled'), 'button ' + text);
    await evaluate('(' + btn + ').click()');
  }
  async function hasText(text) {
    await until(() => evaluate('document.body.innerText.includes(' + JSON.stringify(text) + ')'), text);
  }

  for (const page of pages) {
    await openPage(page);
    console.log('Mounted', page);
  }
  assert.deepEqual(jsErrors, []);
  if (!mountOnly) {
    loadStatus = 503;
    await openPage('/config');
    await hasText('Couldn’t load settings');
    assert.equal(await evaluate('Array.from(document.querySelectorAll("button")).some(b => b.textContent.trim() === "Save")'), false);
    loadStatus = 200;
    await openPage('/config');
    await until(() => evaluate('!!document.getElementById("sunshine_name")'), 'settings load');
    await evaluate('(() => { const input = document.getElementById("sunshine_name"); input.value = "Example Desk"; input.dispatchEvent(new Event("input", {bubbles:true})); })()');
    await click('Save');
    await hasText('Couldn’t confirm that the settings were saved');
    assert.equal(await evaluate('document.getElementById("sunshine_name").value'), 'Example Desk');
    assert.deepEqual(saves[0], {sunshine_name:'Example Desk', extra_setting:'retained'});
    assert.equal(restarts, 0);
    saveReply = { status: true };
    await click('Save');
    await hasText('Settings saved.');
    assert.equal(restarts, 0);
    await click('Apply');
    await hasText('Couldn’t confirm the restart');
    assert.equal(restarts, 1);
    restartReply = { status:true };
    await click('Apply');
    await hasText('Settings saved and restart requested');
    assert.equal(restarts, 2);
    assert.equal(saves.length, 4);

    await openPage('/troubleshooting');
    restartReply = 'drop';
    const restartText = await evaluate('document.querySelector("#restart").textContent.trim()');
    await click(restartText);
    await hasText('Couldn’t confirm the restart');
    assert.equal(restarts, 3);
    restartReply = { status: true };
    await click(restartText);
    await hasText('Moonwalk Host accepted the restart request');
    assert.equal(restarts, 4);

    await openPage('/apps');
    await until(() => evaluate('Array.from(document.querySelectorAll(".app-initial")).map(el => el.textContent).join("") === "EM"'), 'missing cover fallback');
    await click('Edit');
    assert.equal(await evaluate('document.querySelectorAll(\'label[for="appName"]\').length'), 1);
    await click('Add Commands');
    await click('Add Detached Command');
    assert.equal(await evaluate(`(() => {
      const form = document.querySelector('.edit-form');
      const groups = [...form.querySelectorAll('[role="group"][aria-labelledby][aria-describedby]')];
      return groups.length === 2 && groups.every(group =>
        document.getElementById(group.getAttribute('aria-labelledby'))?.textContent.trim()
        && document.getElementById(group.getAttribute('aria-describedby'))?.textContent.trim()
        && [...group.querySelectorAll('input, button')].every(el => el.getAttribute('aria-label')?.trim()));
    })()`), true);
    await evaluate('document.querySelector(\'[aria-label="Remove preparation command 1"]\').click()');
    await evaluate('document.querySelector(\'[aria-label="Remove background command 1"]\').click()');
    await evaluate('(() => { const field = document.getElementById("appName"); field.value = "Edited Desktop"; field.dispatchEvent(new Event("input", {bubbles:true})); })()');
    appTag = '"concurrent"';
    await click('Save');
    await hasText('The application list changed');
    assert.equal(await evaluate('document.getElementById("appName").value'), 'Edited Desktop');
    assert.equal(appChanges[0].tag, '"initial"');
    assert.equal(appChanges[0].edit['image-path'], '');
    await openPage('/apps');
    await click('Edit');
    await click('Save');
    await hasText('Couldn’t confirm the application change');
    assert.equal(appChanges[1].tag, '"concurrent"');
    await click('Cancel');
    appTag = '"changed-before-delete"';
    await evaluate('window.confirm = () => true; document.querySelector(\'[aria-label="Delete Example Desktop"]\').click()');
    await hasText('The application list changed');
    assert.equal(appChanges[2].method, 'DELETE');
    assert.equal(apps.length, 2);
    await openPage('/apps');
    await hasText('Example Desktop');
    acceptAppChanges = true;
    await evaluate('window.confirm = () => true; document.querySelector(\'[aria-label="Delete Example Desktop"]\').click()');
    await until(() => evaluate('document.querySelector(".navbar-brand") && !document.querySelector(\'[aria-label="Delete Example Desktop"]\')'), 'reloaded list after delete');
    assert.equal(appChanges[3].tag, '"changed-before-delete"');
    assert.equal(apps.length, 1);

    localeStatus = 503;
    await openPage('/welcome');
    assert.equal(await evaluate('document.documentElement.lang'), 'en');
    await hasText('Choose a username and password');
    await openPage('/config');
    await hasText('Configuration');
    localeStatus = 200;
    selectedLocale = 'en_GB';
    await openPage('/welcome');
    assert.equal(await evaluate('document.documentElement.lang'), 'en-GB');
    selectedLocale = 'zz';
    await openPage('/welcome');
    assert.equal(await evaluate('document.documentElement.lang'), 'en');
    await hasText('Choose a username and password');
    selectedLocale = 'en';

    pendingPairings = [{ uniqueid: 'example-request', source_ip: '192.0.2.10', age_sec: 1 }];
    await openPage('/pin');
    await hasText('192.0.2.10');
    assert.equal(await evaluate('document.querySelector("#form .btn-primary")?.disabled'), true);
    await evaluate(`(() => {
      document.querySelector('.list-group-item').click();
      for (const [id, value] of [['pin-input', '0123'], ['name-input', 'Example Laptop']]) {
        const input = document.getElementById(id);
        input.value = value;
        input.dispatchEvent(new Event('input', {bubbles:true}));
      }
    })()`);
    await evaluate('document.getElementById("form").requestSubmit(); document.getElementById("form").requestSubmit()');
    await hasText('Couldn’t send the PIN');
    assert.deepEqual(pairingRequests, [{ pin:'0123', name:'Example Laptop', uniqueid:'example-request' }]);
    assert.equal(await evaluate('document.getElementById("pin-input").value'), '0123');
    pairingReply = 'drop';
    await click('Send');
    await hasText('Couldn’t confirm that the PIN was sent');
    pairingReply = { status: true };
    await click('Send');
    await hasText('PIN sent. Check the other device to finish pairing.');
    assert.equal(await evaluate('document.getElementById("pin-input").value'), '');
    assert.equal(pairingRequests.length, 3);
    assert.deepEqual(jsErrors, []);
    console.log('Confirmed load failure, functional settings save, edits preserved, correct request body, restart denial, lost response and acknowledgement.');
    console.log('Confirmed cover fallback, named command fields and buttons, draft preservation, and application revision checks.');
    console.log('Confirmed English fallback for failed language requests and a missing catalog, and normal British English selection.');
    console.log('Confirmed explicit device selection, rejected and lost PIN responses, and acknowledgement without claiming pairing is complete.');
  }
} finally {
  ws?.close();
  if (browser.pid && browser.exitCode === null && browser.signalCode === null) {
    const stopped = once(browser, 'exit');
    browser.kill();
    await stopped;
  }
  await new Promise((ok) => server.close(ok));
  await rm(profile, {recursive:true, force:true});
}
