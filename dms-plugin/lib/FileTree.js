/* A torrent's files as a folder tree, the way qBittorrent shows them.

   Shared word for word by the extension (download dialog, manager page) and the
   DankBar plugin (dms-plugin/lib/FileTree.js; tests/test_filetree.py keeps the
   two identical). Plain functions and no globals beyond them, so it loads as a
   classic <script> in a browser and as a QML JavaScript import alike.

   A file is {index, path, length, completedLength}; `levels` maps a file's
   index to 0 (do not download), 1 normal, 2 high, 3 maximum. */

// Natural order: "(2)" before "(10)", case ignored. By hand, because Qt's
// JavaScript ignores localeCompare's numeric option.
function treeCompareNames(a, b) {
  const split = (s) => String(s).toLowerCase().match(/(\d+|\D+)/g) || [];
  const x = split(a);
  const y = split(b);
  for (let i = 0; i < Math.min(x.length, y.length); i++) {
    if (x[i] === y[i]) continue;
    const nx = /^\d/.test(x[i]);
    const ny = /^\d/.test(y[i]);
    if (nx && ny) return (Number(x[i]) - Number(y[i])) || (x[i].length - y[i].length);
    return x[i] < y[i] ? -1 : 1;
  }
  return x.length - y.length;
}

/* Folders and files from the flat list. `base` (the download's folder) is cut
   off each path; when every file sits in one top folder (a torrent's own
   name), that folder is dropped too, since the name is shown already. */
function treeBuild(files, base) {
  const prefix = base ? String(base).replace(/\/+$/, '') + '/' : '';
  const rel = (files || []).map((f) => {
    const path = String(f.path || '');
    return (prefix && path.indexOf(prefix) === 0 ? path.slice(prefix.length) : path).split('/').filter((p) => p);
  });
  let top = '';
  if (rel.length && rel.every((parts) => parts.length > 1 && parts[0] === rel[0][0])) {
    top = rel[0][0];
    for (const parts of rel) parts.shift();
  }
  const root = { name: top, key: '', dirs: {}, files: [] };
  (files || []).forEach((f, i) => {
    let node = root;
    const parts = rel[i];
    for (let d = 0; d < parts.length - 1; d++) {
      const key = node.key + '/' + parts[d];
      if (!node.dirs[parts[d]]) node.dirs[parts[d]] = { name: parts[d], key, dirs: {}, files: [] };
      node = node.dirs[parts[d]];
    }
    node.files.push({
      index: String(f.index),
      name: parts[parts.length - 1] || String(f.path || ''),
      key: node.key + '/' + (parts[parts.length - 1] || ''),
      length: Number(f.length) || 0,
      done: Number(f.completedLength) || 0,
      waiting: !!f.waitingForTier,
    });
  });
  return root;
}

function treeLevelOf(levels, index) {
  const v = levels ? levels[index] : undefined;
  return v === undefined || v === null ? 1 : Number(v);
}

// Every file under a folder, depth first.
function treeAllFiles(node) {
  let out = node.files.slice();
  for (const name in node.dirs) out = out.concat(treeAllFiles(node.dirs[name]));
  return out;
}

/* The rows to draw, in order. `collapsed` maps a folder key to true; `filter`
   keeps files whose path contains it (and opens their folders); `sort` is
   name | size | progress | priority, `desc` reverses it. Folders always come
   before files, and sort among themselves by the same measure.

   A row: {key, depth, isDir, name, size, done, wanted, wantedDone, indices,
   level, state, open}. `size` is every file's bytes, `wanted` the chosen
   ones' and `wantedDone` what of those is on disk, so a folder's progress is
   not held back by files it skips. For a folder, `level` is the priority its
   files share, skipped ones included (-1, "Mixed", when they differ), and
   `state` is 2 all chosen, 1 some, 0 none; for a file, `level` is its own and
   `state` 2 or 0. */
function treeRows(root, levels, collapsed, filter, sort, desc) {
  const needle = String(filter || '').trim().toLowerCase();
  const rows = [];
  const measure = (item) => {
    if (sort === 'size') return item.size;
    if (sort === 'progress') return item.wanted ? item.wantedDone / item.wanted : 0;
    if (sort === 'priority') return item.level;
    return 0;
  };
  const order = (a, b) => {
    const by = sort && sort !== 'name' ? measure(a) - measure(b) : 0;
    const result = by || treeCompareNames(a.name, b.name);
    return desc ? -result : result;
  };
  const summarize = (node) => {
    const all = treeAllFiles(node).filter((f) => !needle || f.key.toLowerCase().indexOf(needle) >= 0);
    let size = 0, done = 0, chosen = 0, wanted = 0, wantedDone = 0;
    const seen = {};
    for (const f of all) {
      size += f.length;
      done += f.done;
      const level = treeLevelOf(levels, f.index);
      seen[level] = true;
      if (level > 0) {
        chosen++;
        wanted += f.length;
        wantedDone += f.done;
      }
    }
    const distinct = Object.keys(seen);
    return {
      size, done, wanted, wantedDone, indices: all.map((f) => f.index), count: all.length,
      state: chosen === 0 ? 0 : chosen === all.length ? 2 : 1,
      level: distinct.length === 1 ? Number(distinct[0]) : (distinct.length ? -1 : 0),
    };
  };
  const walk = (node, depth) => {
    const dirs = [];
    for (const name in node.dirs) {
      const dir = node.dirs[name];
      const s = summarize(dir);
      if (needle && !s.count) continue;
      dirs.push({ node: dir, name: dir.name, size: s.size, done: s.done, wanted: s.wanted, wantedDone: s.wantedDone, level: s.level, s });
    }
    const files = node.files
      .filter((f) => !needle || f.key.toLowerCase().indexOf(needle) >= 0)
      .map((f) => {
        const level = treeLevelOf(levels, f.index);
        return { f, name: f.name, size: f.length, done: f.done, level,
          wanted: level > 0 ? f.length : 0, wantedDone: level > 0 ? f.done : 0 };
      });
    dirs.sort(order);
    files.sort(order);
    for (const d of dirs) {
      const open = needle ? true : !(collapsed && collapsed[d.node.key]);
      rows.push({
        key: d.node.key, depth, isDir: true, name: d.name, size: d.size, done: d.done,
        wanted: d.wanted, wantedDone: d.wantedDone, indices: d.s.indices, count: d.s.count, level: d.s.level, state: d.s.state, open,
      });
      if (open) walk(d.node, depth + 1);
    }
    for (const x of files) {
      rows.push({
        key: x.f.key, depth, isDir: false, name: x.name, size: x.size, done: x.done,
        wanted: x.wanted, wantedDone: x.wantedDone, indices: [x.f.index], index: x.f.index, level: x.level, state: x.level > 0 ? 2 : 0,
        waiting: x.f.waiting,
      });
    }
  };
  walk(root, 0);
  return rows;
}

// Check or clear files: checking keeps a file's own priority if it had one.
function treeSetChosen(levels, indices, chosen) {
  const next = Object.assign({}, levels);
  for (const index of indices) {
    const level = treeLevelOf(levels, index);
    next[index] = chosen ? (level > 0 ? level : 1) : 0;
  }
  return next;
}

function treeSetLevel(levels, indices, level) {
  const next = Object.assign({}, levels);
  for (const index of indices) next[index] = Number(level);
  return next;
}

// {count, chosen, total, selected}: files and bytes, all and chosen.
function treeSummary(files, levels) {
  let total = 0, selected = 0, chosen = 0;
  for (const f of files || []) {
    const size = Number(f.length) || 0;
    total += size;
    if (treeLevelOf(levels, String(f.index)) > 0) {
      chosen++;
      selected += size;
    }
  }
  return { count: (files || []).length, chosen, total, selected };
}
