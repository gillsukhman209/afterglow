// Loaded by the Afterglow helper on this G1. Only this known firmware is eligible.
'use strict';
const fs = require('fs');
const crypto = require('crypto');
const spawn = require('child_process').spawn;
const dir = '/var/lib/webosbrew/afterglow';
const source = '/usr/lib/qt5/qml/KeyFilters/systemUi.js';
const selected = dir + '/systemUi-tide-1.js';
const key = 'com.webos.surfacemanager.keyFilters';
const app = 'com.afterglow.lounge';
function request(method, body) {
  return new Promise((resolve, reject) => {
    const child = spawn('/usr/bin/luna-send', ['-w','3500','-n','1','luna://com.webos.service.config/' + method, JSON.stringify(body)]);
    let output = '';
    child.stdout.on('data', chunk => output += chunk);
    child.stderr.resume();
    child.on('error', reject);
    child.on('close', () => {
      try {
        const r = JSON.parse(output);
        if (!r.returnValue) throw new Error(r.errorText || 'key configuration rejected');
        resolve(r);
      } catch (error) { reject(error); }
    });
  });
}
async function configure(restore) {
  const current = (await request('getConfigs', {configNames:[key]})).configs[key];
  const from = restore ? selected : source;
  const to = restore ? source : selected;
  if (!Array.isArray(current) || !current.some(f => f.file === from && f.handler === 'handleSystemKeys')) return;
  if (!restore) {
    if (!fs.existsSync('/media/developer/apps/usr/palm/applications/' + app + '/appinfo.json')) return;
    const text = fs.readFileSync(source, 'utf8');
    if (crypto.createHash('sha256').update(text).digest('hex') !== 'abbe33ff0b1bc44126f7115cdb51cb7bd5c5d51066504f61a15a19913010e3db') throw new Error('firmware changed');
    const patched = text.replace('var HOME_APP_ID = "com.webos.app.home"', 'var HOME_APP_ID = "' + app + '"')
      .replace('applicationManager.launch("com.webos.app.home"', 'applicationManager.launch("' + app + '"')
      .replace('longPressTimer.set(key, 1500, runFlashBack)', 'longPressTimer.set(key, 1500, function () { launchHomeApp(key); })');
    fs.writeFileSync(selected + '.next', patched, {mode:0o644});
    fs.renameSync(selected + '.next', selected);
  }
  const next = current.map(f => f.file === from ? Object.assign({}, f, {file:to}) : f);
  await request('setConfigs', {volatile:true, configs:{[key]:next}});
  const readback = (await request('getConfigs', {configNames:[key]})).configs[key];
  if (!Array.isArray(readback) || readback.length !== next.length || !next.every((f,i) => readback[i].file === f.file && readback[i].handler === f.handler)) throw new Error('home key readback mismatch');
}
module.exports = configure;
if (require.main === module) configure(process.argv[2] === 'restore').catch(e => { console.error(e.message); process.exitCode=1; });
