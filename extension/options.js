'use strict';

const $ = (id) => document.getElementById(id);
const CHECKBOXES = ['enabled', 'intercept', 'capture', 'captureMagnets', 'altClick',
  'paused', 'notify', 'notifyErrors', 'pageToasts', 'videoSniffer', 'askBeforeDownload'];
const TEXTS = ['dir'];

const MIB = 1024 * 1024;
//: How many chips a long list shows before "Show all".
const CHIPS_FOLDED = 12;

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

/* ------------------------------------------------------------ chip lists */
/* A list setting (file types, sites) as chips: × takes one out, typing and
   Enter (or a comma) puts one in. Easier to scan than a comma-separated box,
   and impossible to break with a stray separator. */
const chipLists = {};

function chipList(id, normalise) {
  const box = $(id);
  const list = { items: [], open: false, normalise };
  const input = document.createElement('input');
  input.className = 'chip-input';
  input.placeholder = box.dataset.placeholder || 'Add…';
  input.setAttribute('aria-label', input.placeholder);

  function add(raw) {
    const value = normalise(raw);
    if (!value || list.items.includes(value)) return;
    list.items = [...list.items, value];
    render();
    changed();
  }

  function render() {
    const shown = list.open ? list.items : list.items.slice(0, CHIPS_FOLDED);
    const chips = shown.map((value) => {
      const chip = document.createElement('span');
      chip.className = 'chip removable';
      chip.textContent = value;
      const x = document.createElement('button');
      x.type = 'button';
      x.className = 'x';
      x.setAttribute('aria-label', `Remove ${value}`);
      x.textContent = '×';
      x.addEventListener('click', () => {
        list.items = list.items.filter((v) => v !== value);
        render();
        changed();
      });
      chip.append(x);
      return chip;
    });
    const nodes = [...chips];
    if (list.items.length > CHIPS_FOLDED) {
      const more = document.createElement('button');
      more.type = 'button';
      more.className = 'btn btn-text btn-sm';
      more.textContent = list.open ? 'Show fewer' : `+${list.items.length - CHIPS_FOLDED} more`;
      more.addEventListener('click', () => { list.open = !list.open; render(); });
      nodes.push(more);
    }
    box.replaceChildren(...nodes, input);
  }

  input.addEventListener('keydown', (e) => {
    if (e.key === 'Enter' || e.key === ',') {
      e.preventDefault();
      for (const part of input.value.split(/[,\s]+/)) add(part);
      input.value = '';
    } else if (e.key === 'Backspace' && !input.value && list.items.length) {
      list.items = list.items.slice(0, -1);
      render();
      changed();
    }
  });
  input.addEventListener('blur', () => {
    if (!input.value.trim()) return;
    for (const part of input.value.split(/[,\s]+/)) add(part);
    input.value = '';
  });

  list.set = (items) => { list.items = [...(items || [])]; render(); };
  chipLists[id] = list;
  render();
  return list;
}

/* ---------------------------------------------------------- fill / read */
let saved = null;

function fill(settings) {
  for (const key of CHECKBOXES) $(key).checked = settings[key] !== undefined ? !!settings[key] : !!DEFAULTS[key];
  for (const key of TEXTS) $(key).value = settings[key] || '';
  fillMinSize(settings.minSizeMB);
  chipLists.extensions.set(settings.extensions || []);
  chipLists.blockedHosts.set(settings.blockedHosts || []);
  changed();
}

function collect() {
  const patch = {};
  for (const key of CHECKBOXES) patch[key] = $(key).checked;
  patch.dir = $('dir').value.trim();
  patch.minSizeMB = readMinSize();
  patch.extensions = [...chipLists.extensions.items];
  patch.blockedHosts = [...chipLists.blockedHosts.items];
  return patch;
}

//: How many settings differ from what is saved; the save bar shows only then.
function differences() {
  if (!saved) return 0;
  const now = collect();
  return Object.keys(now).filter((key) => JSON.stringify(now[key]) !== JSON.stringify(saved[key] ?? DEFAULTS[key])).length;
}

function changed() {
  const n = differences();
  $('save-bar').hidden = n === 0;
  $('dirty-text').textContent = `${n} unsaved change${n === 1 ? '' : 's'}`;
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
  setTimeout(() => { $('saved').textContent = ''; }, 2400);
}

/* ----------------------------------------------------------- connection */
/* Three links between the browser and a download: the native-messaging helper,
   the manager behind it, and aria2c behind that. Each gets its own check; the
   first broken one says why and how to mend it. */
function paintChain(states, fix) {
  for (const li of $('chain').children) {
    const state = states[li.dataset.step] || 'idle';
    li.className = state;
  }
  $('fix').hidden = !fix;
  if (fix) {
    $('fix-text').textContent = fix.text;
    $('fix-cmd').textContent = fix.cmd;
    $('fix-cmd').parentElement.hidden = !fix.cmd;
  }
}

async function testConnection() {
  paintChain({ host: 'busy', manager: 'busy', aria2: 'busy' }, null);
  $('manager-label').textContent = 'Manager';
  const reply = await api.runtime.sendMessage({ type: 'ping' });
  if (reply && reply.ok) {
    const info = reply.info || {};
    if (info.version) $('manager-label').textContent = `Manager ${info.version}`;
    if (info.aria2 === false) {
      paintChain({ host: 'ok', manager: 'ok', aria2: 'bad' }, {
        text: 'The manager is running but aria2c is not. Restart it from the manager page (Settings → aria2c process), or look at the event log there.',
        cmd: '',
      });
    } else {
      paintChain({ host: 'ok', manager: 'ok', aria2: 'ok' }, null);
    }
    $('test').title = info.socket || '';
    return;
  }
  const error = (reply && reply.error) || '';
  if (/native host/i.test(error)) {
    paintChain({ host: 'bad', manager: 'idle', aria2: 'idle' }, {
      text: "The browser can't start the helper that talks to the manager. Register it once, then restart the browser:",
      cmd: INSTALL_HOST_CMD,
    });
  } else {
    paintChain({ host: 'ok', manager: 'bad', aria2: 'idle' }, {
      text: "The helper is installed, but the manager isn't running. Start it with ./run.sh, or its systemd user unit:",
      cmd: START_MANAGER_CMD,
    });
  }
}

/* ----------------------------------------------------------------- init */
async function init() {
  chipList('extensions', (raw) => String(raw || '').trim().replace(/^\*?\./, '').toLowerCase());
  chipList('blockedHosts', (raw) => String(raw || '').trim()
    .replace(/^https?:\/\//, '').replace(/\/.*$/, '').toLowerCase());

  saved = await loadSettings();
  fill(saved);
  const stored = await api.storage.local.get({ settingsMode: 'simple' });
  setMode(stored.settingsMode);

  for (const btn of document.querySelectorAll('.seg [data-mode]')) {
    btn.addEventListener('click', async () => {
      setMode(btn.dataset.mode);
      await api.storage.local.set({ settingsMode: btn.dataset.mode });
    });
  }

  document.body.addEventListener('input', changed);
  document.body.addEventListener('change', changed);

  $('save').addEventListener('click', async () => {
    const patch = collect();
    await saveSettings(patch);
    saved = { ...saved, ...patch };
    api.runtime.sendMessage({ type: 'refreshBadge' });
    changed();
    flash('Saved');
  });

  $('discard').addEventListener('click', () => fill(saved));

  $('reset').addEventListener('click', async () => {
    if (!confirm('Put every extension setting back to its default? File types and blocked sites are reset too.')) return;
    await saveSettings(DEFAULTS);
    saved = { ...DEFAULTS };
    fill(DEFAULTS);
    flash('Back to defaults');
  });

  $('fix-copy').addEventListener('click', () => {
    navigator.clipboard.writeText($('fix-cmd').textContent).then(() => flash('Copied'), () => {});
  });
  $('test').addEventListener('click', testConnection);
  testConnection();
}

init();
