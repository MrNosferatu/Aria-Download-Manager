/* Draws a torrent's files as a tree (lib/filetree-core.js) for the extension's
   pages: the download dialog and the manager page's details.

   Like qBittorrent (Revision 2, board 3): folders that fold and carry their
   files' totals — a checkbox that is ticked, a dash or empty as all, some or
   none inside are wanted; the wanted size ("1.5 GiB of 3.8 GiB"); progress
   over the wanted bytes, green at 100%; and a priority, "Mixed" when the
   files inside differ, that sets every file in it. Sortable columns, Expand
   all, and a filter for big torrents. Changes go to `onChange(levels)` as
   they happen; the page decides when to save (or, for a finished torrent in
   History, to fetch). `notes` puts a word on a file's row ("not on disk");
   `onOpen(path)` opens a file or folder on a double click. A click folds a folder;
   Ctrl+click or a press and hold picks a row (Shift+click a range), after
   which a click adds or takes one away, and the priority menu then sets the
   picked ones. With `menu(x, y, items)` (the page's popMenu) a right click
   brings up the row's menu: open it, show it in its folder, its priority,
   pick; `onOpen(path, true)` asks for the folder a file is in. */
'use strict';

const FT_LEVELS = [[1, 'Normal'], [2, 'High'], [3, 'Max']];
// The menu says "don't download" in full; a skipped row reads Skip.
const FT_ROW_LEVELS = [[0, "Don't download"], ...FT_LEVELS];
const FT_SORTS = [['name', 'Name'], ['size', 'Size'], ['progress', '%'], ['priority', 'Priority']];
const FT_CHEVRON = '<svg class="ico" viewBox="0 0 24 24"><path d="M10 6 8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg>';
const FT_FILE = '<svg class="ico" viewBox="0 0 24 24"><path d="M14 2H6c-1.1 0-2 .9-2 2v16c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V8l-6-6zm4 18H6V4h7v5h5v11z"/></svg>';
const FT_FOLDER = '<svg class="ico" viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z"/></svg>';

// Each page has its own byte formatter: the dialog lib/common.js's, the
// manager page app.js's.
function ftBytes(n) {
  if (typeof humanBytes === 'function') return humanBytes(n);
  if (typeof fmtBytes === 'function') return fmtBytes(n);
  return `${n} B`;
}

// Every folder's key, for Expand all / Collapse all.
function ftFolderKeys(node) {
  const out = [];
  for (const name in node.dirs) out.push(node.dirs[name].key, ...ftFolderKeys(node.dirs[name]));
  return out;
}

function mountFileTree(host, options) {
  const S = {
    files: options.files || [],
    base: options.base || '',
    levels: Object.assign({}, options.levels || {}),
    progress: options.progress !== false,
    collapsed: {},
    filter: '',
    sort: 'name',
    desc: false,
    root: null,
    editedAt: 0,
    notes: options.notes || {},
    picked: {},
    anchor: '',
    rows: [],
  };
  const onChange = options.onChange || (() => {});
  const onOpen = options.onOpen || null;
  const menu = options.menu || null;
  const pathOf = (index) => (S.files.find((f) => String(f.index) === String(index)) || {}).path || '';

  host.classList.add('ftree');
  if (!S.progress) host.classList.add('ft-noprogress');
  host.innerHTML = `
    <div class="ft-bar">
      <label class="ft-check"><input type="checkbox" data-role="all" aria-label="All files"><span data-role="count"></span></label>
      <input class="ft-filter" data-role="filter" placeholder="Filter files" spellcheck="false">
      <span class="ft-spacer"></span>
      <button type="button" class="btn btn-sm ft-foldall" data-role="foldall"></button>
      <button type="button" class="btn btn-sm btn-text ft-unpick" data-role="unpick" hidden>Unpick</button>
      <select class="ft-setall" data-role="setall" aria-label="Priority for every chosen file">
        <option value="" data-role="setall-label">Priority for all…</option>
        <option value="0" data-role="setall-skip" hidden>Don't download</option>
        ${FT_LEVELS.map(([v, l]) => `<option value="${v}">${l}</option>`).join('')}
      </select>
    </div>
    <div class="ft-head" role="row">
      ${FT_SORTS.map(([key, label]) => `<button type="button" class="ft-col ft-col-${key}" data-sort="${key}" title="Sort by ${key}">${label}<span class="ft-arrow"></span></button>`).join('')}
    </div>
    <div class="ft-list" role="tree"></div>`;
  const list = host.querySelector('.ft-list');
  const $r = (role) => host.querySelector(`[data-role="${role}"]`);
  $r('filter').hidden = S.files.length < 12;

  function changed(levels) {
    S.levels = levels;
    S.editedAt = Date.now();
    draw();
    onChange(Object.assign({}, S.levels));
  }

  // A row's right-click menu, as popMenu items ([icon, label, run] or null
  // for a line). A picked row stands for all the picked ones.
  function rowMenu(row, pick, fold) {
    const items = [];
    if (onOpen && row.isDir) {
      items.push(['folder', 'Open folder', () => onOpen(S.base.replace(/\/+$/, '') + row.key)]);
    } else if (onOpen) {
      const path = pathOf(row.index);
      if (path && !S.notes[row.index]) {
        items.push(['open', 'Open', () => onOpen(path)], ['folder', 'Show in folder', () => onOpen(path, true)]);
      }
    }
    if (row.isDir) items.push(['chevron', row.open ? 'Fold' : 'Unfold', fold]);
    const all = treePickedIndices(S.rows, S.picked);
    const group = S.picked[row.key] && all.length > 1 ? all : null;
    if (items.length) items.push(null);
    for (const [level, word] of FT_ROW_LEVELS) {
      items.push([!group && row.level === level ? 'check' : 'none', group ? `${word} · ${group.length} files` : word,
        () => changed(treeSetLevel(S.levels, group || row.indices, level))]);
    }
    items.push(null, S.picked[row.key] ? ['close', 'Unpick', () => pick(false, true)] : ['add', 'Pick', () => pick(false, true)]);
    return items;
  }

  function draw() {
    if (!S.root) S.root = treeBuild(S.files, S.base);
    // Keep the control being used where it is across the redraw.
    const active = document.activeElement;
    const focusKey = active && list.contains(active) ? active.closest('[data-key]')?.dataset.key : null;
    const focusRole = active && active.dataset ? active.dataset.role : null;

    const rows = treeRows(S.root, S.levels, S.collapsed, S.filter, S.sort, S.desc);
    S.rows = rows;
    list.replaceChildren(...rows.map(rowElement));
    if (!rows.length) {
      list.innerHTML = '<p class="ft-empty">No files match.</p>';
    }

    const sum = treeSummary(S.files, S.levels);
    $r('count').textContent = `${sum.chosen} of ${sum.count} files wanted · ${ftBytes(sum.selected)} of ${ftBytes(sum.total)}`;
    // Picked rows: the priority menu sets them, and says so.
    const picked = treePickedIndices(rows, S.picked).length;
    $r('unpick').hidden = !picked;
    $r('setall-skip').hidden = !picked;
    $r('setall-label').textContent = picked ? `Priority for ${picked} picked…` : 'Priority for all…';
    const folders = ftFolderKeys(S.root);
    const anyFolded = folders.some((k) => S.collapsed[k]);
    $r('foldall').hidden = !folders.length;
    $r('foldall').textContent = anyFolded ? 'Expand all' : 'Collapse all';
    const all = $r('all');
    all.checked = sum.chosen === sum.count && sum.count > 0;
    all.indeterminate = sum.chosen > 0 && sum.chosen < sum.count;
    for (const col of host.querySelectorAll('[data-sort]')) {
      const on = col.dataset.sort === S.sort;
      col.classList.toggle('is-sorted', on);
      col.querySelector('.ft-arrow').textContent = on ? (S.desc ? ' ↓' : ' ↑') : '';
    }
    if (focusKey) {
      const again = list.querySelector(`[data-key="${CSS.escape(focusKey)}"] [data-role="${focusRole}"]`);
      if (again) again.focus();
    }
  }

  function rowElement(row) {
    const el = document.createElement('div');
    el.className = `ft-row${row.isDir ? ' is-dir' : ''}${row.state === 0 ? ' is-off' : ''}${S.picked[row.key] ? ' is-picked' : ''}`;
    el.dataset.key = row.key;
    el.setAttribute('role', 'treeitem');
    if (row.isDir) el.setAttribute('aria-expanded', String(row.open));
    el.style.setProperty('--depth', row.depth);
    // Bytes done over bytes wanted, so skipped files do not hold a folder back.
    const pct = row.wanted ? Math.min(100, Math.floor(row.wantedDone / row.wanted * 100)) : 0;
    const size = row.isDir && row.wanted > 0 && row.wanted < row.size
      ? `${ftBytes(row.wanted)} of ${ftBytes(row.size)}` : ftBytes(row.size);
    const levelOptions = (row.level === -1 ? '<option value="-1" selected>Mixed</option>' : '')
      + FT_ROW_LEVELS.map(([v, l]) => `<option value="${v}"${v === row.level ? ' selected' : ''}>${l}</option>`).join('');
    el.innerHTML = `
      <span class="ft-name">
        <input type="checkbox" data-role="check" aria-label="Download"${row.state === 2 ? ' checked' : ''}>
        ${row.isDir ? `<button type="button" class="ft-twisty${row.open ? ' is-open' : ''}" data-role="twisty" aria-label="${row.open ? 'Fold' : 'Unfold'}">${FT_CHEVRON}</button>` : ''}
        ${S.progress
          // The icon inside a progress ring, as the DankBar pill draws it.
          ? `<span class="ft-ring${row.state === 0 ? ' is-off' : pct >= 100 ? ' is-full' : row.isDir || pct > 0 ? ' is-moving' : ''}" style="--p:${row.state === 0 ? 0 : pct}">${row.isDir ? FT_FOLDER : FT_FILE}</span>`
          : row.isDir ? `<span class="ft-folder">${FT_FOLDER}</span>` : ''}
        <span class="ft-label"></span>
        ${!row.isDir && S.notes[row.index] ? `<span class="ft-note">${S.notes[row.index]}</span>` : ''}
        ${row.isDir ? `<span class="ft-count">${row.count === 1 ? '1 file' : `${row.count} files`}</span>` : ''}
      </span>
      <span class="ft-size">${size}</span>
      <span class="ft-done${pct >= 100 ? ' is-full' : ''}" title="${ftBytes(row.wantedDone)} of ${ftBytes(row.wanted)}">
        <span class="ft-pct">${row.state === 0 ? (row.isDir ? '—' : 'skip') : `${pct}%`}</span>
      </span>
      <select class="ft-level${row.level >= 2 ? ' is-raised' : ''}" data-role="level" aria-label="Priority">${levelOptions}</select>`;
    const label = el.querySelector('.ft-label');
    label.textContent = row.name;
    if (!row.isDir && S.notes[row.index]) el.classList.add('is-noted');
    if (!row.isDir && onOpen) {
      el.addEventListener('dblclick', (e) => {
        if (e.target.closest('input, select, button') || Object.keys(S.picked).length) return;
        const path = pathOf(row.index);
        if (path && !S.notes[row.index]) onOpen(path);
      });
    }
    label.title = row.waiting ? `${row.name} · starts after the higher priorities` : row.name;
    const check = el.querySelector('[data-role="check"]');
    check.indeterminate = row.state === 1;
    check.addEventListener('change', () => changed(treeSetChosen(S.levels, row.indices, check.checked)));
    // A folder's priority sets every file inside it; Skip clears them.
    el.querySelector('[data-role="level"]').addEventListener('change', (e) => {
      const value = Number(e.target.value);
      if (value >= 0) changed(treeSetLevel(S.levels, row.indices, value));
    });
    const pick = (range, add) => {
      const next = treePick(S.rows, S.picked, S.anchor, row.key, range, add);
      S.picked = next.picked;
      S.anchor = next.anchor;
      draw();
    };
    const fold = () => {
      S.collapsed[row.key] = row.open;
      draw();
    };
    // A click folds a folder, so a plain click never starts picking: Ctrl+click
    // or a press and hold does (Shift+click a range), and while rows are
    // picked a click adds or takes one away. Its own controls do their own thing.
    // The hold redraws the rows, so whether it fired is kept in S for the
    // click that follows on the new row.
    let holdTimer = 0;
    el.addEventListener('pointerdown', (e) => {
      S.held = false;
      if (e.button !== 0 || e.target.closest('input, select, button')) return;
      holdTimer = setTimeout(() => { S.held = true; pick(false, true); }, 500);
    });
    for (const type of ['pointerup', 'pointerleave', 'pointercancel']) {
      el.addEventListener(type, () => clearTimeout(holdTimer));
    }
    el.addEventListener('click', (e) => {
      if (S.held || e.target.closest('input, select, button')) return;
      if (e.shiftKey || e.ctrlKey || e.metaKey) pick(e.shiftKey, e.ctrlKey || e.metaKey);
      else if (Object.keys(S.picked).length) pick(false, true);
      else if (row.isDir) {
        // It folds at once; the second click of a double click opens it
        // instead of folding it back, so there is neither a wait nor a flicker.
        if (e.detail === 2) {
          if (onOpen) onOpen(S.base.replace(/\/+$/, '') + row.key);
          return;
        }
        fold();
      }
    });
    if (row.isDir) el.querySelector('[data-role="twisty"]').addEventListener('click', fold);
    if (menu) {
      el.addEventListener('contextmenu', (e) => {
        if (e.target.closest('input, select, button')) return;
        e.preventDefault();
        menu(e.clientX, e.clientY, rowMenu(row, pick, fold));
      });
    }
    return el;
  }

  $r('foldall').addEventListener('click', () => {
    const folders = ftFolderKeys(S.root);
    const anyFolded = folders.some((k) => S.collapsed[k]);
    S.collapsed = {};
    if (!anyFolded) for (const k of folders) S.collapsed[k] = true;
    draw();
  });
  $r('all').addEventListener('change', (e) => {
    const every = S.files.map((f) => String(f.index));
    changed(treeSetChosen(S.levels, every, e.target.checked));
  });
  $r('setall').addEventListener('change', (e) => {
    const value = e.target.value;
    e.target.value = '';
    if (value === '') return;
    const picked = treePickedIndices(S.rows, S.picked);
    if (picked.length) {
      changed(treeSetLevel(S.levels, picked, Number(value)));
      return;
    }
    const chosen = S.files.map((f) => String(f.index)).filter((i) => treeLevelOf(S.levels, i) > 0);
    if (Number(value) > 0) changed(treeSetLevel(S.levels, chosen, Number(value)));
  });
  $r('unpick').addEventListener('click', () => {
    S.picked = {};
    S.anchor = '';
    draw();
  });
  $r('filter').addEventListener('input', (e) => {
    S.filter = e.target.value;
    draw();
  });
  for (const col of host.querySelectorAll('[data-sort]')) {
    col.addEventListener('click', () => {
      if (S.sort === col.dataset.sort) S.desc = !S.desc;
      else {
        S.sort = col.dataset.sort;
        S.desc = S.sort !== 'name';  // biggest, most done, highest first
      }
      draw();
    });
  }

  draw();

  return {
    levels: () => Object.assign({}, S.levels),
    /* Live figures from the manager. Its priorities only replace ours when
       nothing was changed here a moment ago, so a save in flight is not
       undone by the refresh that raced it. */
    update(files, levels) {
      S.files = files || [];
      S.root = null;
      // Nor over a choice of no files the page could not save (aria2 needs
      // one): it stays on screen with the page's word on it.
      const unsavedNone = S.editedAt && !Object.values(S.levels).some((v) => Number(v) > 0);
      if (levels && Date.now() - S.editedAt > 4000 && !unsavedNone) S.levels = Object.assign({}, levels);
      // Not under an open priority menu: redrawing would snap it shut.
      if (document.activeElement?.tagName === 'SELECT' && host.contains(document.activeElement)) return;
      draw();
    },
  };
}
