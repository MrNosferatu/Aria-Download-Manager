/* Draws a torrent's files as a tree (lib/filetree-core.js) for the extension's
   pages: the download dialog and the manager page's details.

   Like qBittorrent: folders that fold, a checkbox on every row (a folder's
   covers everything in it, and shows "some" when only part is chosen), size
   and a progress bar per row, a priority for what is chosen, sortable
   columns, and a filter for big torrents. Changes go to `onChange(levels)` as
   they happen; the page decides when to save. */
'use strict';

const FT_LEVELS = [[1, 'Normal'], [2, 'High'], [3, 'Maximum']];
const FT_SORTS = [['name', 'Name'], ['size', 'Size'], ['progress', 'Done'], ['priority', 'Priority']];
const FT_CHEVRON = '<svg class="ico" viewBox="0 0 24 24"><path d="M10 6 8.59 7.41 13.17 12l-4.58 4.59L10 18l6-6z"/></svg>';
const FT_FOLDER = '<svg class="ico" viewBox="0 0 24 24"><path d="M10 4H4c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h16c1.1 0 2-.9 2-2V8c0-1.1-.9-2-2-2h-8l-2-2z"/></svg>';

// Each page has its own byte formatter: the dialog lib/common.js's, the
// manager page app.js's.
function ftBytes(n) {
  if (typeof humanBytes === 'function') return humanBytes(n);
  if (typeof fmtBytes === 'function') return fmtBytes(n);
  return `${n} B`;
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
  };
  const onChange = options.onChange || (() => {});

  host.classList.add('ftree');
  if (!S.progress) host.classList.add('ft-noprogress');
  host.innerHTML = `
    <div class="ft-bar">
      <label class="ft-check"><input type="checkbox" data-role="all" aria-label="All files"><span data-role="count"></span></label>
      <input class="ft-filter" data-role="filter" placeholder="Filter files" spellcheck="false">
      <span class="ft-spacer"></span>
      <select class="ft-setall" data-role="setall" aria-label="Priority for every chosen file">
        <option value="">Priority for all…</option>
        ${FT_LEVELS.map(([v, l]) => `<option value="${v}">${l}</option>`).join('')}
      </select>
    </div>
    <div class="ft-head" role="row">
      ${FT_SORTS.map(([key, label]) => `<button type="button" class="ft-col ft-col-${key}" data-sort="${key}">${label}<span class="ft-arrow"></span></button>`).join('')}
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

  function draw() {
    if (!S.root) S.root = treeBuild(S.files, S.base);
    // Keep the control being used where it is across the redraw.
    const active = document.activeElement;
    const focusKey = active && list.contains(active) ? active.closest('[data-key]')?.dataset.key : null;
    const focusRole = active && active.dataset ? active.dataset.role : null;

    const rows = treeRows(S.root, S.levels, S.collapsed, S.filter, S.sort, S.desc);
    list.replaceChildren(...rows.map(rowElement));
    if (!rows.length) {
      list.innerHTML = '<p class="ft-empty">No files match.</p>';
    }

    const sum = treeSummary(S.files, S.levels);
    $r('count').textContent = `${sum.chosen} of ${sum.count} files · ${ftBytes(sum.selected)} of ${ftBytes(sum.total)}`;
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
    el.className = `ft-row${row.isDir ? ' is-dir' : ''}${row.state === 0 ? ' is-off' : ''}`;
    el.dataset.key = row.key;
    el.setAttribute('role', 'treeitem');
    if (row.isDir) el.setAttribute('aria-expanded', String(row.open));
    el.style.setProperty('--depth', row.depth);
    const pct = row.size ? Math.min(100, Math.round(row.done / row.size * 1000) / 10) : 0;
    const levelOptions = row.state === 0
      ? '<option value="0" selected>—</option>'
      : (row.level === -1 ? '<option value="-1" selected>Mixed</option>' : '')
        + FT_LEVELS.map(([v, l]) => `<option value="${v}"${v === row.level ? ' selected' : ''}>${l}</option>`).join('');
    el.innerHTML = `
      <span class="ft-name">
        ${row.isDir ? `<button type="button" class="ft-twisty${row.open ? ' is-open' : ''}" data-role="twisty" aria-label="${row.open ? 'Fold' : 'Unfold'}">${FT_CHEVRON}</button>` : '<span class="ft-twisty"></span>'}
        <input type="checkbox" data-role="check" aria-label="Download"${row.state === 2 ? ' checked' : ''}>
        ${row.isDir ? `<span class="ft-folder">${FT_FOLDER}</span>` : ''}
        <span class="ft-label"></span>
      </span>
      <span class="ft-size">${ftBytes(row.size)}</span>
      <span class="ft-done" title="${ftBytes(row.done)} of ${ftBytes(row.size)}">
        <span class="ft-bar-track"><span class="ft-bar-fill" style="width:${pct}%"></span></span>
        <span class="ft-pct">${pct >= 100 ? '100%' : `${pct}%`}</span>
      </span>
      <select class="ft-level" data-role="level" aria-label="Priority"${row.state === 0 ? ' disabled' : ''}>${levelOptions}</select>`;
    const label = el.querySelector('.ft-label');
    label.textContent = row.name;
    label.title = row.waiting ? `${row.name} · starts after the higher priorities` : row.name;
    const check = el.querySelector('[data-role="check"]');
    check.indeterminate = row.state === 1;
    check.addEventListener('change', () => changed(treeSetChosen(S.levels, row.indices, check.checked)));
    el.querySelector('[data-role="level"]').addEventListener('change', (e) => {
      const value = Number(e.target.value);
      if (value > 0) changed(treeSetLevel(S.levels, row.indices.filter((i) => treeLevelOf(S.levels, i) > 0), value));
    });
    if (row.isDir) {
      const fold = () => {
        S.collapsed[row.key] = row.open;
        draw();
      };
      el.querySelector('[data-role="twisty"]').addEventListener('click', fold);
      label.addEventListener('click', fold);
    }
    return el;
  }

  $r('all').addEventListener('change', (e) => {
    const every = S.files.map((f) => String(f.index));
    changed(treeSetChosen(S.levels, every, e.target.checked));
  });
  $r('setall').addEventListener('change', (e) => {
    const level = Number(e.target.value);
    e.target.value = '';
    if (!level) return;
    const chosen = S.files.map((f) => String(f.index)).filter((i) => treeLevelOf(S.levels, i) > 0);
    changed(treeSetLevel(S.levels, chosen, level));
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
      if (levels && Date.now() - S.editedAt > 4000) S.levels = Object.assign({}, levels);
      // Not under an open priority menu: redrawing would snap it shut.
      if (document.activeElement?.tagName === 'SELECT' && host.contains(document.activeElement)) return;
      draw();
    },
  };
}
