'use strict';

const $ = (id) => document.getElementById(id);
let settings = null;
let currentHost = '';

function setStatus(text, kind, title = '') {
  const el = $('status');
  el.textContent = text;
  el.className = `status ${kind}`;
  el.title = title;
}

const STATUS_WORD = { active: '', waiting: 'Queued', paused: 'Paused' };

async function refresh() {
  const reply = await api.runtime.sendMessage({ type: 'state' });
  if (!reply || !reply.ok) {
    setStatus('Manager offline', 'err', (reply && reply.error) || '');
    $('list').textContent = '';
    $('empty-text').textContent = `Can't reach the manager: ${(reply && reply.error) || 'no reply'}.`;
    $('empty').hidden = false;
    return;
  }

  const state = reply.state || {};
  const aria2 = state.aria2 || {};
  const counts = state.counts || {};
  const global = state.global || {};
  const busy = (counts.active || 0) > 0;

  if (!aria2.running) setStatus('aria2c is not running', 'err', aria2.last_error || '');
  else setStatus(busy ? 'Downloading' : 'Ready', busy ? 'busy' : 'ok', `aria2c ${aria2.version || ''}`.trim());

  const down = $('down');
  down.textContent = humanSpeed(global.downloadSpeed);
  down.classList.toggle('quiet', !(Number(global.downloadSpeed) > 0));
  $('active').textContent = counts.active || 0;
  $('queued').textContent = (counts.waiting || 0) + (counts.paused || 0);

  const rows = (state.downloads || [])
    .filter((d) => d.status === 'active' || d.status === 'waiting' || d.status === 'paused')
    .slice(0, 8);
  $('empty').hidden = rows.length > 0;
  $('empty-text').textContent = 'Nothing downloading right now.';

  // Built as nodes rather than innerHTML: a download name is remote text.
  const list = $('list');
  list.textContent = '';
  for (const d of rows) {
    const item = document.createElement('div');
    item.className = `item is-${d.status}`;

    const top = document.createElement('div');
    top.className = 'top';
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = d.name;
    name.title = d.name;
    const speed = document.createElement('span');
    speed.className = 'speed';
    speed.textContent = d.status === 'active'
      ? `${humanSpeed(d.downloadSpeed)} · ${Math.round(d.progress || 0)}%`
      : `${STATUS_WORD[d.status] || d.status} · ${Math.round(d.progress || 0)}%`;
    top.append(name, speed);

    const bar = document.createElement('div');
    bar.className = 'progress';
    const fill = document.createElement('i');
    fill.style.width = `${Math.min(100, d.progress || 0)}%`;
    bar.append(fill);

    item.append(top, bar);
    list.append(item);
  }
}

async function init() {
  settings = await loadSettings();

  function paintEnabled(on) {
    document.body.classList.toggle('off', !on);
    $('enabled').checked = on;
    $('enabled').title = on
      ? 'On: downloads go to the manager. Turn off to leave them to the browser.'
      : 'Off: the browser is handling its own downloads.';
    const site = $('site-block');
    if (site) site.disabled = !on || !currentHost;
  }

  paintEnabled(settings.enabled !== false);
  $('enabled').addEventListener('change', async (event) => {
    const on = event.target.checked;
    settings.enabled = on;
    await saveSettings({ enabled: on });
    paintEnabled(on);
    api.runtime.sendMessage({ type: 'refreshBadge' }).catch(() => {});
    if (on) refresh();
  });

  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  // Only web pages can be excluded; an about:/moz-extension: tab has no host.
  const url = tab && tab.url ? tab.url : '';
  currentHost = /^https?:/i.test(url) ? hostOf(url) : '';
  $('host').textContent = currentHost || 'this site';
  $('site-block').checked = !!currentHost && settings.blockedHosts.includes(currentHost);
  $('site-block').disabled = !currentHost || settings.enabled === false;

  $('site-block').addEventListener('change', async (event) => {
    const hosts = new Set(settings.blockedHosts);
    if (event.target.checked) hosts.add(currentHost);
    else hosts.delete(currentHost);
    settings.blockedHosts = [...hosts];
    await saveSettings({ blockedHosts: settings.blockedHosts });
  });

  $('add').addEventListener('submit', async (event) => {
    event.preventDefault();
    const url = $('url').value.trim();
    if (!url) return;
    const reply = await api.runtime.sendMessage({
      type: 'send',
      item: { url, referer: '', source: 'popup' },
    });
    if (reply && reply.ok) {
      $('url').value = '';
      refresh();
    } else {
      setStatus(reply && reply.error ? reply.error : 'Could not add that', 'err');
    }
  });

  // The manager ships inside the extension, so it opens without any server.
  // An already-open copy is brought forward instead of stacking up tabs.
  $('open-ui').addEventListener('click', async () => {
    const url = api.runtime.getURL('manager/index.html');
    const open = (await api.tabs.query({})).find((t) => (t.url || '').startsWith(url));
    if (open) {
      await api.tabs.update(open.id, { active: true });
      await api.windows.update(open.windowId, { focused: true });
    } else {
      await api.tabs.create({ url });
    }
    window.close();
  });

  $('options').addEventListener('click', () => api.runtime.openOptionsPage());

  refresh();
  setInterval(refresh, 1000);
}

init();
