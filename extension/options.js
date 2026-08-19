'use strict';

const $ = (id) => document.getElementById(id);
const CHECKBOXES = ['intercept', 'capture', 'captureMagnets', 'altClick', 'paused', 'notify', 'pageToasts'];
const TEXTS = ['server', 'dir'];

function fill(settings) {
  for (const key of CHECKBOXES) $(key).checked = !!settings[key];
  for (const key of TEXTS) $(key).value = settings[key] || '';
  $('minSizeMB').value = settings.minSizeMB || 0;
  $('extensions').value = (settings.extensions || []).join(', ');
  $('blockedHosts').value = (settings.blockedHosts || []).join('\n');
}

function collect() {
  const patch = {};
  for (const key of CHECKBOXES) patch[key] = $(key).checked;
  patch.server = $('server').value.trim() || DEFAULTS.server;
  patch.dir = $('dir').value.trim();
  patch.minSizeMB = Math.max(0, Number($('minSizeMB').value) || 0);
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
    // Test what is typed in the box, not what was last saved.
    await saveSettings({ server: $('server').value.trim() || DEFAULTS.server });
    const reply = await api.runtime.sendMessage({ type: 'ping' });
    const out = $('test-result');
    if (reply && reply.ok) {
      const info = reply.info || {};
      out.textContent = `connected — ${info.name} ${info.version}, aria2 ${info.aria2 ? 'up' : 'down'}`;
      out.className = 'hint ok';
    } else {
      out.textContent = (reply && reply.error) || 'failed';
      out.className = 'hint err';
    }
  });
}

init();
