'use strict';
const byId = id => document.getElementById(id);
const tiles = Array.from(document.querySelectorAll('.tile'));
const panel = byId('panel');
const idle = byId('idle');
const controls = byId('controls');
const sound = Array.from(panel.querySelectorAll('[data-audio]'));
const settings = Array.from(panel.querySelectorAll('.setting:not(#lgSettings)')).concat(byId('done'));
const onTV = !!window.PalmServiceBridge;
const options = { wallpaper: ['Tide', 'Alpine lake', 'Horizon'], shade: ['Natural', 'Dim', 'Low'], clockSetting: ['On', 'Off'] };
const prefs = {};
let selectedTile = tiles[0];
let noticeTimer;
let idleTimer;
let idleReturn;
let launching = false;

function render() {
  byId('scene').style.backgroundImage = 'url(assets/' + ['tide','alpine','horizon'][prefs.wallpaper] + '.jpg)';
  byId('scene').style.opacity = [1,.7,.4][prefs.shade];
  byId('clock').hidden = prefs.clockSetting === 1;
  Object.keys(options).forEach(key => {
    byId(key).querySelector('b').textContent = options[key][prefs[key]];
  });
}
Object.keys(options).forEach(key => {
  const storageKey = key === 'wallpaper' ? 'afterglow.tide.wallpaper' : 'afterglow.' + key;
  let saved = 0;
  try { saved = Number(localStorage.getItem(storageKey)); } catch (_) {}
  prefs[key] = Number.isInteger(saved) && options[key][saved] ? saved : 0;
  byId(key).onclick = () => {
    prefs[key] = (prefs[key] + 1) % options[key].length;
    try { localStorage.setItem(storageKey, prefs[key]); } catch (_) {}
    render();
  };
});

function updateClock() {
  const now = new Date();
  const time = now.toLocaleTimeString([], {hour:'numeric', minute:'2-digit'});
  byId('clock').textContent = time;
  byId('idleTime').textContent = prefs.clockSetting ? '' : time;
  byId('idleTime').style.left = (12 + (now.getMinutes() * 13) % 60) + '%';
  byId('idleTime').style.top = (15 + (now.getMinutes() * 17) % 64) + '%';
}
function panelOpen(open) {
  panel.hidden = byId('overlay').hidden = !open;
  byId('home').setAttribute('aria-hidden', String(open));
  Array.from(byId('home').querySelectorAll('button')).forEach(b => b.tabIndex = open ? -1 : 0);
  (open ? byId('lgSettings') : controls).focus();
}
byId('lgSettings').onclick = async () => {
  if (!onTV) return notify('LG TV Settings opens on the TV.');
  try {
    await service('applicationManager', 'launch', {id:'com.palm.app.settings'});
  } catch (_) { notify('Press the Settings button on your LG remote.'); }
};
controls.onclick = () => panelOpen(true);
byId('overlay').onclick = byId('done').onclick = () => panelOpen(false);
function enterIdle() {
  if (document.hidden || !idle.hidden) return;
  idleReturn = document.activeElement;
  idle.hidden = false;
  updateClock();
}
function armIdle() {
  clearTimeout(idleTimer);
  if (idle.hidden && !document.hidden) idleTimer = setTimeout(enterIdle, 90000);
}
function wake() {
  idle.hidden = true;
  if (idleReturn) idleReturn.focus();
  armIdle();
}
byId('ambient').onclick = enterIdle;
idle.onclick = wake;
function notify(message) {
  clearTimeout(noticeTimer);
  byId('notice').textContent = message;
  byId('notice').hidden = false;
  noticeTimer = setTimeout(() => byId('notice').hidden = true, 5500);
}
function service(name, method, parameters) {
  return new Promise((resolve,reject) => {
    const timer = setTimeout(() => reject(new Error('TV response timed out')), 5000);
    webOS.service.request('luna://com.webos.' + name, {
      method, parameters,
      onSuccess: response => { clearTimeout(timer); resolve(response); },
      onFailure: error => { clearTimeout(timer); reject(error); }
    });
  });
}
async function launch(tile) {
  const label = tile.getAttribute('aria-label');
  if (!onTV) return notify(label + ' opens on a compatible LG TV. This is the Mac preview.');
  if (launching) return;
  launching = true;
  try {
    const id = tile.dataset.app;
    const result = await service('applicationManager', 'getAppLoadStatus', {appId:id});
    if (!result.exist) return notify(label + ' shortcut unavailable. Open it from LG Home.');
    await service('applicationManager', 'launch', {id});
  } catch (_) {
    notify('The TV could not open ' + label + '. Use LG Home.');
  } finally { launching = false; }
}
tiles.forEach(tile => {
  tile.onfocus = () => selectedTile = tile;
  tile.onclick = () => launch(tile);
});
sound.forEach(button => {
  button.onclick = async () => {
    if (!onTV) return notify('TV sound controls are available on the LG TV.');
    const action = button.dataset.audio;
    const isMute = action === 'mute' || action === 'unmute';
    try {
      await service('audio', isMute ? 'setMuted' : action, isMute ? {muted:action === 'mute'} : {});
      notify({mute:'Muted',unmute:'Sound on',volumeUp:'Volume increased',volumeDown:'Volume decreased'}[action]);
    } catch (_) { notify('Use the volume buttons on your LG remote.'); }
  };
});
function move(direction) {
  const current = document.activeElement;
  if (panel.hidden) {
    if (current === controls) {
      if (direction === 'Left' || direction === 'Down') selectedTile.focus();
    } else if (tiles.includes(current)) {
      const index = tiles.indexOf(current);
      if (direction === 'Right' || (direction === 'Up' && index === 0)) controls.focus();
      else if (direction === 'Up') tiles[index - 1].focus();
      else if (direction === 'Down' && index < tiles.length - 1) tiles[index + 1].focus();
    }
    return;
  }
  if (current === byId('lgSettings')) {
    if (direction === 'Down') sound[0].focus();
  } else if (sound.includes(current)) {
    if (direction === 'Up') byId('lgSettings').focus();
    if (direction === 'Down') settings[0].focus();
    const step = direction === 'Left' ? -1 : direction === 'Right' ? 1 : 0;
    if (step) (sound[sound.indexOf(current) + step] || current).focus();
  } else if (direction === 'Up' || direction === 'Down') {
    const index = settings.indexOf(current) + (direction === 'Up' ? -1 : 1);
    (index < 0 ? sound[0] : settings[index] || current).focus();
  }
}
document.addEventListener('keydown', event => {
  if (!idle.hidden) { event.preventDefault(); wake(); return; }
  armIdle();
  if ((event.key || '').indexOf('Arrow') === 0) {
    event.preventDefault();
    move(event.key.slice(5));
  } else if (event.keyCode === 461 || event.key === 'Escape' || event.key === 'Backspace') {
    event.preventDefault();
    if (!panel.hidden) panelOpen(false);
    else if (onTV) webOS.platformBack();
  }
});
document.addEventListener('mouseover', event => {
  const button = event.target.closest('button');
  if (button && idle.hidden && (panel.hidden || panel.contains(button))) button.focus();
});
document.addEventListener('mousemove', armIdle);
document.addEventListener('click', armIdle);
document.addEventListener('visibilitychange', () => {
  if (!document.hidden) { updateClock(); if (!idle.hidden) wake(); }
  armIdle();
});
render();
updateClock();
setInterval(updateClock, 10000);
selectedTile.focus();
armIdle();
