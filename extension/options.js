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

/* Simple / Advanced. Remembered like any other setting, so the page opens the
   way it was left. */
function setMode(mode) {
  document.body.classList.toggle('advanced', mode === 'advanced');
  for (const btn of document.querySelectorAll('.seg [data-mode]')) {
    btn.setAttribute('aria-pressed', String(btn.dataset.mode === mode));
  }
}

function flash(text) {
  $('saved').textContent = text;
  setTimeout(() => { $('saved').textContent = ''; }, 1800);
}

async function testConnection() {
  const out = $('test-result');
  out.textContent = 'Checking…';
  out.className = 'status';
  const reply = await api.runtime.sendMessage({ type: 'ping' });
  if (reply && reply.ok) {
    const info = reply.info || {};
    out.textContent = `Connected · ${info.name || 'manager'} ${info.version || ''} · aria2c ${info.aria2 ? 'running' : 'not running'}`;
    out.className = `status ${info.aria2 ? 'ok' : 'err'}`;
    out.title = info.socket || '';
  } else {
    out.textContent = (reply && reply.error) || 'Could not reach the manager';
    out.className = 'status err';
  }
}

async function init() {
  const settings = await loadSettings();
  fill(settings);
  const stored = await api.storage.local.get({ settingsMode: 'simple' });
  setMode(stored.settingsMode);

  for (const btn of document.querySelectorAll('.seg [data-mode]')) {
    btn.addEventListener('click', async () => {
      setMode(btn.dataset.mode);
      await api.storage.local.set({ settingsMode: btn.dataset.mode });
    });
  }

  $('save').addEventListener('click', async () => {
    await saveSettings(collect());
    api.runtime.sendMessage({ type: 'refreshBadge' });
    flash('Saved');
  });

  $('reset').addEventListener('click', async () => {
    await saveSettings(DEFAULTS);
    fill(DEFAULTS);
    flash('Back to defaults');
  });

  $('test').addEventListener('click', testConnection);
  testConnection();
}

init();
