'use strict';

/* The toolbar popup: the DankBar quick menu, in the browser. What is happening
   first (a headline, the overall progress, the few downloads that matter, each
   with its one action), then the bulk buttons, then the quick add and the
   switches. When a link in the chain is broken it says which one and how to
   fix it, instead of a red status line. */

const $ = (id) => document.getElementById(id);
let settings = null;
let currentHost = '';
let lastState = null;

const LISTED = 4;
const RANK = { active: 0, error: 1, paused: 2, waiting: 3 };

/* The manager pushes a frame the moment it has new figures. Polling on a
   timer of our own instead showed numbers up to a tick behind the DankBar,
   which streams — the speed here read lower than the one in the bar. */
function watchState() {
  ManagerLink.subscribe({
    onFrame(kind, data) {
      if (kind === 'state') render(data);
    },
    onError(reason) {
      showTrouble(/native host/i.test(reason || '') ? 'host' : 'manager', reason);
    },
  });
}

async function refresh() {
  const reply = await ManagerLink.call('GET', '/api/state');
  const problem = linkProblem(reply);
  if (problem) {
    showTrouble(problem, ManagerLink.errorText(reply));
    return;
  }
  render(reply.body || {});
}

async function act(method, path, body) {
  const reply = await ManagerLink.call(method, path, body);
  if (reply.status < 200 || reply.status >= 300) {
    flashHint(ManagerLink.errorText(reply), true);
    return false;
  }
  refresh();
  return true;
}

/* ------------------------------------------------------------- trouble */
function copy(text) {
  navigator.clipboard.writeText(text).then(() => flashHint('Copied'), () => {});
}

function showTrouble(kind, reason) {
  lastState = null;
  $('headline').textContent = kind === 'aria2' ? 'Downloads on hold' : 'Not connected';
  $('subline').textContent = '';
  for (const id of ['overall', 'list']) $(id).hidden = true;
  $('bulk').hidden = kind !== 'aria2';
  $('trouble').hidden = false;
  $('trouble').dataset.kind = kind;
  const cmd = $('trouble-cmd');
  const primary = $('trouble-primary');
  const secondary = $('trouble-secondary');
  secondary.hidden = true;
  cmd.hidden = true;
  if (kind === 'host') {
    $('trouble-title').textContent = "The browser can't reach the helper";
    $('trouble-text').textContent = 'Register it once, then restart the browser:';
    cmd.textContent = INSTALL_HOST_CMD;
    cmd.hidden = false;
    primary.textContent = 'Copy command';
    primary.onclick = () => copy(INSTALL_HOST_CMD);
  } else if (kind === 'manager') {
    $('trouble-title').textContent = "The manager isn't running";
    $('trouble-text').textContent = 'Start it with ./run.sh or its systemd user unit:';
    cmd.textContent = START_MANAGER_CMD;
    cmd.hidden = false;
    primary.textContent = 'Try again';
    primary.onclick = () => refresh();
    secondary.textContent = 'Copy command';
    secondary.hidden = false;
    secondary.onclick = () => copy(START_MANAGER_CMD);
  } else {
    $('trouble-title').textContent = 'aria2c stopped';
    $('trouble-text').textContent = `${reason || 'It stopped without saying why.'} Downloads resume where they were once it is back.`;
    primary.textContent = 'Restart aria2c';
    primary.onclick = () => act('POST', '/api/aria2/restart');
    secondary.textContent = 'Open log';
    secondary.hidden = false;
    secondary.onclick = () => openManager('#log');
  }
  paintBulk(null);
}

/* -------------------------------------------------------------- render */
function render(state) {
  lastState = state;
  const aria2 = state.aria2 || {};
  const counts = state.counts || {};
  const speed = Number((state.global || {}).downloadSpeed || 0);
  const active = counts.active || 0;
  const paused = counts.paused || 0;
  const queued = counts.waiting || 0;

  if (!aria2.running) {
    showTrouble('aria2', aria2.last_error || '');
    return;
  }
  $('trouble').hidden = true;

  const totals = activeTotals(state);
  if (active > 0) {
    $('headline').textContent = `${active} downloading`;
    const eta = humanEta(totals.eta);
    $('subline').textContent = `${humanSpeed(speed)}${eta ? ` · ${eta} left` : ''}`;
  } else if (paused || queued) {
    $('headline').textContent = [paused ? `${paused} paused` : '', queued ? `${queued} waiting` : '']
      .filter(Boolean).join(', ');
    $('subline').textContent = 'Nothing is moving';
  } else {
    $('headline').textContent = 'Nothing downloading';
    const done = counts.complete || 0;
    $('subline').textContent = done ? `${done} finished` : 'Ready';
  }

  // Overall progress, while anything runs and every size is known.
  $('overall').hidden = !(active > 0 && totals.progress >= 0);
  if (!$('overall').hidden) {
    $('overall-bar').style.width = `${Math.round(totals.progress * 100)}%`;
    const bits = [`${humanBytes(totals.completed)} of ${humanBytes(totals.total)}`];
    if (paused + queued) bits.push(`${paused + queued} waiting`);
    if (counts.error) bits.push(`${counts.error} failed`);
    $('overall-text').textContent = bits.join(' · ');
  }

  renderList(state);
  paintBulk(counts);
}

function rowFor(d) {
  const item = document.createElement('div');
  item.className = `pitem is-${d.status}`;

  const main = document.createElement('div');
  main.className = 'pmain';
  const top = document.createElement('div');
  top.className = 'ptop';
  const name = document.createElement('span');
  name.className = 'name';
  // Built as nodes rather than innerHTML: a download name is remote text.
  name.textContent = d.isMetadata ? 'Magnet · getting the file list' : d.name;
  name.title = d.name;
  const figure = document.createElement('span');
  figure.className = 'figure';
  const pct = `${Math.floor(d.progress || 0)}%`;
  figure.textContent = {
    active: d.isMetadata ? `${d.connections || 0} peers` : pct,
    paused: `Paused · ${pct}`,
    waiting: 'Waiting',
    error: '',
  }[d.status] ?? pct;
  top.append(name, figure);
  main.append(top);

  if (d.status === 'error') {
    const why = document.createElement('span');
    why.className = 'why';
    why.textContent = d.errorMessage || 'Failed';
    why.title = d.errorMessage || '';
    main.append(why);
  } else {
    const bar = document.createElement('div');
    bar.className = 'progress';
    const fill = document.createElement('i');
    fill.style.width = `${d.isMetadata ? 30 : Math.min(100, d.progress || 0)}%`;
    bar.append(fill);
    main.append(bar);
  }

  const button = document.createElement('button');
  button.type = 'button';
  if (d.status === 'error') {
    button.className = 'btn btn-sm';
    button.textContent = 'Retry';
    button.addEventListener('click', () => act('POST', `/api/download/${d.gid}/retry`));
  } else {
    const running = d.status === 'active';
    button.className = 'btn btn-icon btn-sm';
    button.title = running ? 'Pause' : 'Resume';
    button.setAttribute('aria-label', button.title);
    button.innerHTML = running
      ? '<svg class="ico" viewBox="0 0 24 24"><path d="M6 19h4V5H6v14zm8-14v14h4V5h-4z"/></svg>'
      : '<svg class="ico" viewBox="0 0 24 24"><path d="M8 5v14l11-7z"/></svg>';
    button.addEventListener('click', () => act('POST', `/api/download/${d.gid}/${running ? 'pause' : 'resume'}`));
  }
  item.append(main, button);
  return item;
}

function lastFinished(state) {
  return (state.downloads || [])
    .filter((d) => d.status === 'complete' && d.fileExists !== false)
    .sort((a, b) => (b.finishedAt || 0) - (a.finishedAt || 0))[0];
}

function renderList(state) {
  const list = $('list');
  list.textContent = '';
  const all = (state.downloads || [])
    .filter((d) => RANK[d.status] !== undefined)
    .sort((a, b) => RANK[a.status] - RANK[b.status]);

  if (!all.length) {
    // Nothing running: the most likely next click is the file that just finished.
    const done = lastFinished(state);
    list.hidden = !done;
    if (!done) return;
    const item = document.createElement('div');
    item.className = 'pitem is-complete';
    const name = document.createElement('span');
    name.className = 'name';
    name.textContent = done.name;
    name.title = done.path || done.name;
    const open = document.createElement('button');
    open.type = 'button';
    open.className = 'btn btn-sm';
    open.textContent = 'Open';
    open.addEventListener('click', () => act('POST', `/api/download/${done.gid}/open`, { folder: false }));
    const folder = document.createElement('button');
    folder.type = 'button';
    folder.className = 'btn btn-icon btn-sm';
    folder.title = 'Show in folder';
    folder.setAttribute('aria-label', 'Show in folder');
    folder.innerHTML = '<svg class="ico" viewBox="0 0 24 24"><path d="M20 6h-8l-2-2H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2zm0 12H4V8h16v10z"/></svg>';
    folder.addEventListener('click', () => act('POST', `/api/download/${done.gid}/open`, { folder: true }));
    const main = document.createElement('div');
    main.className = 'pmain';
    main.append(name);
    item.append(main, folder, open);
    list.append(item);
    return;
  }

  list.hidden = false;
  for (const d of all.slice(0, LISTED)) list.append(rowFor(d));
  if (all.length > LISTED) {
    const more = document.createElement('button');
    more.type = 'button';
    more.className = 'more';
    more.textContent = `+${all.length - LISTED} more in the manager`;
    more.addEventListener('click', () => openManager());
    list.append(more);
  }
}

function paintBulk(counts) {
  const usable = !!counts;
  const c = counts || {};
  const waiting = (c.waiting || 0) + (c.paused || 0);
  const stopped = c.stopped || 0;
  $('bulk').hidden = !lastState && $('trouble').dataset.kind !== 'aria2';
  const set = (id, label, n, enabled) => {
    const btn = $(id);
    btn.disabled = !enabled;
    btn.querySelector('span').textContent = n > 0 ? `${label} · ${n}` : label;
  };
  set('b-pause', 'Pause all', c.active || 0, usable && (c.active || 0) > 0);
  // Resume is worth offering with nothing paused — aria2 may still be holding
  // downloads back — but pausing or clearing nothing is a no-op.
  set('b-resume', 'Resume', waiting, usable);
  set('b-clear', 'Clear', stopped, usable && stopped > 0);
}

/* ------------------------------------------------------------ add hint */
let hintTimer = null;
function flashHint(text, isError = false) {
  const el = $('add-hint');
  el.textContent = text;
  el.classList.toggle('err', isError);
  el.hidden = !text;
  clearTimeout(hintTimer);
  if (text) hintTimer = setTimeout(() => { el.hidden = true; }, isError ? 6000 : 2400);
}

//: What the box holds, said back as it is typed or pasted: "2 links · 1 magnet".
function describeLinks(text) {
  const links = text.split(/\s+/).filter((t) => isFetchable(t));
  if (!links.length) return text.trim() ? "That isn't a link the manager can fetch" : '';
  const magnets = links.filter(isMagnet).length;
  const head = links.length === 1 ? (magnets ? 'A magnet link' : hostOf(links[0]) || '1 link') : `${links.length} links`;
  return magnets && links.length > 1 ? `${head} · ${magnets} magnet` : head;
}

/* ----------------------------------------------------------------- open */
async function openManager(hash = '') {
  // The manager ships inside the extension, so it opens without any server.
  // An already-open copy is brought forward instead of stacking up tabs.
  const base = api.runtime.getURL('manager/index.html');
  const open = (await api.tabs.query({})).find((t) => (t.url || '').startsWith(base));
  if (open) {
    await api.tabs.update(open.id, { active: true, ...(hash ? { url: base + hash } : {}) });
    await api.windows.update(open.windowId, { focused: true });
  } else {
    await api.tabs.create({ url: base + hash });
  }
  window.close();
}

/* ----------------------------------------------------------------- init */
async function init() {
  settings = await loadSettings();

  function paintEnabled(on) {
    document.body.classList.toggle('off', !on);
    $('enabled').checked = on;
    $('enabled').title = on
      ? 'On: downloads go to the manager. Turn off to leave them to the browser.'
      : 'Off: the browser is handling its own downloads.';
    $('off-banner').hidden = on;
    const site = $('site-block');
    if (site) site.disabled = !on || !currentHost;
    $('captureMagnets').disabled = !on;
  }

  async function setEnabled(on) {
    settings.enabled = on;
    await saveSettings({ enabled: on });
    paintEnabled(on);
    api.runtime.sendMessage({ type: 'refreshBadge' }).catch(() => {});
    if (on) refresh();
  }

  paintEnabled(settings.enabled !== false);
  $('enabled').addEventListener('change', (event) => setEnabled(event.target.checked));
  $('turn-on').addEventListener('click', () => setEnabled(true));

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

  // Same switch as "Catch torrents" in settings: magnets and .torrent files.
  $('captureMagnets').checked = settings.captureMagnets !== false;
  $('captureMagnets').title = 'Off leaves magnet links and .torrent files to the browser or your torrent client.';
  $('captureMagnets').addEventListener('change', async (event) => {
    settings.captureMagnets = event.target.checked;
    await saveSettings({ captureMagnets: settings.captureMagnets });
  });

  $('url').addEventListener('input', () => flashHint(describeLinks($('url').value)));
  $('add').addEventListener('submit', async (event) => {
    event.preventDefault();
    const links = $('url').value.split(/\s+/).filter((t) => isFetchable(t));
    if (!links.length) {
      flashHint("That isn't a link the manager can fetch", true);
      return;
    }
    const reply = links.length === 1
      ? await api.runtime.sendMessage({ type: 'send', item: { url: links[0], referer: '', source: 'popup' } })
      : await api.runtime.sendMessage({ type: 'sendMany', urls: links, context: { source: 'popup' } });
    if (reply && reply.ok) {
      $('url').value = '';
      flashHint(links.length === 1 ? 'Sent to Aria' : `Sent ${links.length} links to Aria`);
      refresh();
    } else {
      flashHint(reply && reply.error ? reply.error : 'Could not add that', true);
    }
  });

  $('b-pause').addEventListener('click', () => act('POST', '/api/global/pause-all'));
  $('b-resume').addEventListener('click', () => act('POST', '/api/global/resume-all'));
  $('b-clear').addEventListener('click', () => act('POST', '/api/global/purge'));
  $('open-ui').addEventListener('click', () => openManager());
  $('options').addEventListener('click', () => api.runtime.openOptionsPage());

  // Ctrl+V straight into the box: the popup opens with it focused.
  $('url').focus();
  refresh();
  watchState();
}

init();
