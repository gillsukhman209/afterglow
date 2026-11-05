// Runs on the G1's Node 8 runtime. Listen to the TV instead of polling it.
'use strict';
const spawn = require('child_process').spawn;
const readline = require('readline');
const fs = require('fs');
const logPath = '/tmp/afterglow-launch.log';
function log(message) {
  try {
    if (fs.existsSync(logPath) && fs.statSync(logPath).size > 20000) fs.unlinkSync(logPath);
    fs.appendFileSync(logPath, String(process.uptime().toFixed(2)) + ' ' + message + '\n');
  } catch (_) {}
}
log('helper started');
const app = 'com.afterglow.lounge';
const stock = 'com.webos.app.home';
let previousPower, previousApp;
let pendingLaunch = false;
function launch(retries) {
  if (pendingLaunch) return;
  pendingLaunch = true;
  const p = spawn('/usr/bin/luna-send', ['-w','4000','-n','1','luna://com.webos.applicationManager/launch', JSON.stringify({id:app,noSplash:true})]);
  let result = '';
  p.stdout.on('data', data => result += data);
  p.stderr.resume();
  p.on('error', () => pendingLaunch = false);
  p.on('close', () => {
    pendingLaunch = false;
    let accepted = false;
    try { accepted = JSON.parse(result).returnValue === true; } catch (_) {}
    log('launch ' + (accepted ? 'accepted' : 'failed ' + result.slice(0,220)));
    if (!accepted && retries > 0 && previousPower === 'Active') setTimeout(() => launch(retries - 1), 1200);
  });
}
function subscribe(uri, callback, parameters) {
  const child = spawn('/usr/bin/luna-send', ['-i', 'luna://' + uri, JSON.stringify(Object.assign({subscribe:true}, parameters))]);
  child.stderr.resume();
  readline.createInterface({input:child.stdout}).on('line', line => {
    // Some firmware prefixes interactive responses with '** Message ...'.
    const start = line.indexOf('{');
    if (start < 0) return;
    try {
      const data = JSON.parse(line.slice(start));
      if (data.returnValue) callback(data);
      else { log('subscription failed ' + uri); child.kill(); }
    } catch (_) {}
  });
  child.on('error', () => {});
  child.on('close', () => setTimeout(() => subscribe(uri, callback, parameters), 4000));
}
subscribe('com.webos.service.tvpower/power/getPowerState', msg => {
  if (!msg.state || msg.state === previousPower) return;
  const wasSleeping = Boolean(previousPower);
  previousPower = msg.state;
  log('power ' + msg.state);
  if (msg.state === 'Active') {
    if (wasSleeping) {
      launch(8);
    } else {
      // The boot manager can start Afterglow earlier than the Homebrew hook.
      // Do not interrupt anyone who has already selected another streaming app.
      const probe = spawn('/usr/bin/luna-send',['-w','3000','-n','1',
        'luna://com.webos.bootManager/getBootStatus','{}']);
      let output = '';
      probe.stdout.on('data', chunk => output += chunk);
      probe.stderr.resume();
      probe.on('close', () => {
        let info = {};
        try { info = JSON.parse(output); } catch (_) {}
        if (info.firstAppId !== app || !info.firstAppLaunched) launch(8);
      });
    }
  }
});
subscribe('com.webos.applicationManager/getForegroundAppInfo', msg => {
  if (!msg.appId || previousApp === msg.appId) return;
  previousApp = msg.appId;
  log('screen ' + (msg.appId === app ? 'Afterglow' : msg.appId === stock ? 'LG Home' : 'other'));
  if (previousApp !== stock || previousPower !== 'Active') return;
  launch(2);
});


// The boot manager reads this four-field input preference before Homebrew starts.
// Keep the user's physical HDMI selection, and save the displaced record for undo.
const inputPath = '/var/lib/eim/lastinput';
const savedInput = '/var/lib/webosbrew/afterglow/previous-input.json';
let saveTimer;
function pinStartupInput() {
  try {
    const file = fs.lstatSync(inputPath);
    if (!file.isFile() || file.size > 4096) return;
    const raw = fs.readFileSync(inputPath,'utf8');
    const record = JSON.parse(raw);
    if (record.appId === app && record.type === 'MVPD_IP') return;
    if (typeof record.type !== 'string' || typeof record.appId !== 'string' ||
        !record.physicalLastSourceId || !record.physicalLastSourceAppId) return;
    // Gate this adaptation to the G1's verified on-disk schema.
    if (Object.keys(record).sort().join(',') !== 'appId,physicalLastSourceAppId,physicalLastSourceId,type') return;
    const temp = inputPath + '.afterglow';
    fs.writeFileSync(savedInput + '.tmp',raw,{mode:0o600});
    fs.renameSync(savedInput + '.tmp',savedInput);
    record.appId = app; record.type = 'MVPD_IP';
    fs.writeFileSync(temp,JSON.stringify(record),{mode:file.mode & 0o777});
    // A concurrent LG input selection takes priority; the watcher retries.
    if (fs.readFileSync(inputPath,'utf8') === raw) fs.renameSync(temp,inputPath);
    else fs.unlinkSync(temp);
  } catch (_) { log('startup preference unavailable'); }
}
try {
  fs.watch('/var/lib/eim',(event,name) => {
    if (name && name !== 'lastinput') return;
    clearTimeout(saveTimer);
    saveTimer = setTimeout(pinStartupInput,150);
  });
  pinStartupInput();
} catch (_) { log('input preference watcher unavailable'); }

const configureHomeKey = require('./home-key');
let configuringHomeKey = false;
function ensureHomeKey() {
  if (configuringHomeKey) return;
  configuringHomeKey = true;
  configureHomeKey(false).catch(e => log('home key: ' + e.message))
    .then(() => { configuringHomeKey = false; });
}
ensureHomeKey();
setInterval(ensureHomeKey, 60000);
