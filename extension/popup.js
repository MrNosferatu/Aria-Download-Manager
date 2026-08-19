'use strict';

const $ = (id) => document.getElementById(id);
let settings = null;
let currentHost = '';

function setStatus(text, kind) {
  const pill = $('status');
  pill.textContent = text;
  pill.className = `pill ${kind}`;
}

async function refresh() {
  const reply = await api.runtime.sendMessage({ type: 'state' });
  if (!reply || !reply.ok) {
    setStatus('Offline', 'err');
    $('list').innerHTML = '';
    $('empty').textContent = 'Manager unreachable. Check the server URL in Settings.';
    $('empty').hidden = false;
    return;
  }

  const state = reply.state || {};
  const aria2 = state.aria2 || {};
  const counts = state.counts || {};
  const global = state.global || {};

  setStatus(aria2.running ? `aria2c ${aria2.version || 'up'}` : 'aria2c down',
            aria2.running ? 'ok' : 'err');
  $('down').textContent = humanSpeed(global.downloadSpeed);
  $('up').textContent = humanSpeed(global.uploadSpeed);
  $('active').textContent = counts.active || 0;
  $('queued').textContent = (counts.waiting || 0) + (counts.paused || 0);

  const rows = (state.downloads || [])
    .filter((d) => d.status === 'active' || d.status === 'waiting' || d.status === 'paused')
    .slice(0, 8);
  $('empty').hidden = rows.length > 0;
  $('empty').textContent = 'Nothing downloading.';

  // Built as nodes rather than innerHTML: a download name is remote text.
  const list = $('list');
  list.textContent = '';
  for (const d of rows) {
    const row = document.createElement('div');
    row.className = 'row';

    const top = document.createElement('div');
    top.className = 'row-top';

    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = d.name;
    name.title = d.name;

    const speed = document.createElement('span');
    speed.className = 'speed';
    speed.textContent = d.status === 'active' ? humanSpeed(d.downloadSpeed) : d.status;

    top.append(name, speed);

    const bar = document.createElement('div');
    bar.className = 'bar';
    const fill = document.createElement('i');
    fill.style.width = `${Math.min(100, d.progress || 0)}%`;
    bar.append(fill);

    row.append(top, bar);
    list.append(row);
  }
}

async function init() {
  settings = await loadSettings();

  const [tab] = await api.tabs.query({ active: true, currentWindow: true });
  // Only web pages can be blocklisted; an about:/moz-extension: tab has no
  // host worth showing.
  const url = tab && tab.url ? tab.url : '';
  currentHost = /^https?:/i.test(url) ? hostOf(url) : '';
  $('host').textContent = currentHost || 'this site';
  $('site-block').checked = !!currentHost && settings.blockedHosts.includes(currentHost);
  $('site-block').disabled = !currentHost;

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
      item: { url, referer: '', cookie: '', source: 'popup' },
    });
    if (reply && reply.ok) {
      $('url').value = '';
      refresh();
    } else {
      setStatus(reply && reply.error ? reply.error : 'Failed', 'err');
    }
  });

  $('open-ui').addEventListener('click', () => {
    api.tabs.create({ url: baseUrl(settings.server) + '/' });
    window.close();
  });

  $('options').addEventListener('click', () => api.runtime.openOptionsPage());

  refresh();
  setInterval(refresh, 1000);
}

init();
