'use strict';

const $ = (id) => document.getElementById(id);
const CHECKBOXES = ['enabled', 'intercept', 'capture', 'captureMagnets', 'altClick',
  'paused', 'notify', 'pageToasts', 'videoSniffer'];
const TEXTS = ['dir'];

const MIB = 1024 * 1024;

/* The setting is stored in MiB (what background.js compares against), but shown
   as a number and a unit, in the largest unit it reaches 1 in. */
function fillMinSize(mib) {
  const bytes = (Number(mib) || 0) * MIB;
  const units = [...$('minSizeUnit').options].map((o) => Number(o.value));
  let unit = MIB;
  for (const size of units) if (bytes >= size) unit = size;
  $('minSize').value = bytes ? String(+(bytes / unit).toFixed(2)) : '';
  $('minSizeUnit').value = String(bytes ? unit : MIB);
}

function readMinSize() {
  const amount = Number($('minSize').value.trim());
  if (!Number.isFinite(amount) || amount <= 0) return 0;
  return (amount * Number($('minSizeUnit').value)) / MIB;
}

function fill(settings) {
  for (const key of CHECKBOXES) $(key).checked = !!settings[key];
  for (const key of TEXTS) $(key).value = settings[key] || '';
  fillMinSize(settings.minSizeMB);
  $('extensions').value = (settings.extensions || []).join(', ');
  $('blockedHosts').value = (settings.blockedHosts || []).join('\n');
}

function collect() {
  const patch = {};
  for (const key of CHECKBOXES) patch[key] = $(key).checked;
  patch.dir = $('dir').value.trim();
  patch.minSizeMB = readMinSize();
  patch.extensions = $('extensions').value
    .split(',')
    .map((s) => s.trim().replace(/^\./, '').toLowerCase())
    .filter(Boolean);
  patch.blockedHosts = $('blockedHosts').value
    .split('\n')
    .map((s) => s.trim().replace(/^https?:\/\//, '').replace(/\/.*$/, ''))
    .filter(Boolean);
  return patch;
}

async function init() {
  fill(await loadSettings());

  $('save').addEventListener('click', async () => {
    await saveSettings(collect());
    api.runtime.sendMessage({ type: 'refreshBadge' });
    $('saved').textContent = 'saved';
    setTimeout(() => { $('saved').textContent = ''; }, 1500);
  });

  $('reset').addEventListener('click', async () => {
    await saveSettings(DEFAULTS);
    fill(DEFAULTS);
    $('saved').textContent = 'back to defaults';
    setTimeout(() => { $('saved').textContent = ''; }, 1500);
  });

  $('test').addEventListener('click', async () => {
    const reply = await api.runtime.sendMessage({ type: 'ping' });
    const out = $('test-result');
    if (reply && reply.ok) {
      const info = reply.info || {};
      out.textContent = `connected via ${info.socket || 'the socket'} — ${info.name} ${info.version}, aria2 ${info.aria2 ? 'up' : 'down'}`;
      out.className = 'hint ok';
    } else {
      out.textContent = (reply && reply.error) || 'failed';
      out.className = 'hint err';
    }
  });
}

init();
