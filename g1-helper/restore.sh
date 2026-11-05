#!/bin/sh
set -eu
dir=/var/lib/webosbrew/afterglow
if [ -f /var/lib/webosbrew/init.d/60-afterglow ]; then
  mv /var/lib/webosbrew/init.d/60-afterglow "$dir/disabled-hook"
fi
for pid in $(pidof node || true); do
  test -r "/proc/$pid/cmdline" || continue
  target=$(tr "\000" "\n" < "/proc/$pid/cmdline" | sed -n "2p")
  if [ "$target" = "$dir/home.js" ]; then kill "$pid"; fi
done
if [ -f "$dir/home-key.js" ]; then node "$dir/home-key.js" restore; fi
# Deregister only the Afterglow input if webOS still has it cached.
sleep 2 | luna-send -w 1800 -n 1 luna://com.webos.service.eim/deleteDevice '{"appId":"com.afterglow.lounge"}' || true
# Preserve the selected physical input. If LG already picked another input,
# leave its live startup record alone.
node <<'JS'
const fs = require('fs');
const file = '/var/lib/eim/lastinput';
const record = JSON.parse(fs.readFileSync(file, 'utf8'));
if (record.appId === 'com.afterglow.lounge') {
  let saved;
  try { saved = JSON.parse(fs.readFileSync('/var/lib/webosbrew/afterglow/previous-input.json','utf8')); } catch (_) {}
  if (saved && saved.appId !== record.appId && saved.physicalLastSourceId === record.physicalLastSourceId && saved.physicalLastSourceAppId === record.physicalLastSourceAppId) {
    record.type = saved.type;
    record.appId = saved.appId;
  } else {
  if (!record.physicalLastSourceId || !record.physicalLastSourceAppId) process.exit(1);
  record.type = record.physicalLastSourceId;
  record.appId = record.physicalLastSourceAppId;
  }
  fs.writeFileSync(file + '.afterglow-restore', JSON.stringify(record), {mode: 0o644});
  fs.renameSync(file + '.afterglow-restore', file);
}
JS
# Restore the LG startup preference observed before configuring Afterglow.
sleep 2 | luna-send -w 1800 -n 1 luna://com.webos.settingsservice/setSystemSettings '{"category":"general","settings":{"homeAutoLaunch":"off","lastInputApp":"com.movenetworks.app.sling-tv-sling-production"}}'
sync
echo "LG Home restored. Press Home on your remote. Afterglow is still available in Apps."
