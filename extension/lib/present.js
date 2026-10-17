/* How things are shown, shared by every page that shows downloads: the popup,
   the download dialog, the manager page and the background (the toolbar icon).
   No browser APIs and no globals beyond these, so it loads anywhere — the
   manager page cannot load lib/common.js, whose `api` its app.js already has. */
'use strict';

//: "48 s", "3 min", "2 h 5 min" — how long, in words a glance can take in.
function humanEta(seconds) {
  const s = Math.round(Number(seconds));
  if (!Number.isFinite(s) || s < 0) return '';
  if (s < 60) return `${s} s`;
  if (s < 3600) return `${Math.round(s / 60)} min`;
  const h = Math.floor(s / 3600);
  const m = Math.round((s % 3600) / 60);
  return m ? `${h} h ${m} min` : `${h} h`;
}

//: The running downloads summed up: bytes done of the total, and the time left
//: at the current speed. progress is -1 while any has no size yet.
function activeTotals(state) {
  let done = 0;
  let total = 0;
  let unknown = false;
  for (const d of (state && state.downloads) || []) {
    if (d.status !== 'active') continue;
    if (!d.total || d.isMetadata) { unknown = true; continue; }
    done += d.completed || 0;
    total += d.total;
  }
  const speed = Number((state && state.global && state.global.downloadSpeed) || 0);
  const left = Math.max(0, total - done);
  return {
    completed: done, total, left,
    progress: !unknown && total > 0 ? done / total : -1,
    eta: speed > 0 && total > 0 ? left / speed : -1,
  };
}

//: What a file is, from its name (or MIME type): a plain-word label and a
//: Material Symbols path for its tile. Shared by the dialog and the manager page.
const FILE_KINDS = {
  image: ['Disk image', 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm0 14.5a4.5 4.5 0 1 1 0-9 4.5 4.5 0 0 1 0 9zm0-5.5a1 1 0 1 0 0 2 1 1 0 0 0 0-2z'],
  archive: ['Archive', 'M20 6h-8l-2-2H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2zm-2 6h-2v2h2v2h-2v2h-2v-2h2v-2h-2v-2h2V8h2v2h2v2z'],
  video: ['Video', 'M18 4l2 4h-3l-2-4h-2l2 4h-3l-2-4H8l2 4H7L5 4H4a2 2 0 0 0-2 2v12a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V4h-4z'],
  audio: ['Audio', 'M12 3v10.55A4 4 0 1 0 14 17V7h4V3h-6z'],
  picture: ['Picture', 'M21 19V5a2 2 0 0 0-2-2H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2zM8.5 13.5l2.5 3 3.5-4.5 4.5 6H5l3.5-4.5z'],
  document: ['Document', 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zm2 16H8v-2h8v2zm0-4H8v-2h8v2zm-3-5V3.5L18.5 9H13z'],
  app: ['App package', 'M20 6h-4V4a2 2 0 0 0-2-2h-4a2 2 0 0 0-2 2v2H4a2 2 0 0 0-2 2v11a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V8a2 2 0 0 0-2-2zM10 4h4v2h-4V4z'],
  torrent: ['Torrent', 'M18 16.08c-.76 0-1.44.3-1.96.77L8.91 12.7c.05-.23.09-.46.09-.7s-.04-.47-.09-.7l7.05-4.11A2.99 2.99 0 0 0 21 5a3 3 0 1 0-5.91.7L8.04 9.81A3 3 0 1 0 6 15c.79 0 1.5-.31 2.04-.81l7.12 4.16c-.05.21-.08.43-.08.65A2.92 2.92 0 1 0 18 16.08z'],
  page: ['Web page', 'M12 2a10 10 0 1 0 0 20 10 10 0 0 0 0-20zm-1 17.93A8 8 0 0 1 4 12c0-.62.08-1.21.21-1.79L9 15v1a2 2 0 0 0 2 2v1.93zm6.9-2.54A2 2 0 0 0 16 16h-1v-3a1 1 0 0 0-1-1H8v-2h2a1 1 0 0 0 1-1V7h2a2 2 0 0 0 2-2v-.41A7.99 7.99 0 0 1 17.9 17.39z'],
  file: ['File', 'M14 2H6a2 2 0 0 0-2 2v16a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V8l-6-6zm-1 7V3.5L18.5 9H13z'],
};

const KIND_BY_EXT = {
  image: ['iso', 'img', 'qcow2', 'vdi', 'vmdk', 'dmg'],
  archive: ['zip', '7z', 'rar', 'gz', 'xz', 'zst', 'bz2', 'tar', 'tgz', 'txz'],
  video: ['mkv', 'mp4', 'webm', 'avi', 'mov', 'm4v', 'wmv', 'flv', 'ts'],
  audio: ['mp3', 'flac', 'ogg', 'opus', 'wav', 'm4a', 'aac'],
  picture: ['png', 'jpg', 'jpeg', 'gif', 'webp', 'svg', 'avif'],
  document: ['pdf', 'epub', 'mobi', 'doc', 'docx', 'odt', 'txt', 'md'],
  app: ['deb', 'rpm', 'appimage', 'exe', 'msi', 'pkg', 'apk', 'flatpak', 'whl'],
  torrent: ['torrent'],
  page: ['html', 'htm', 'php'],
};

function fileKind(name, mime) {
  const ext = (String(name || '').toLowerCase().match(/\.([a-z0-9]+)$/) || [])[1] || '';
  for (const [kind, exts] of Object.entries(KIND_BY_EXT)) {
    if (exts.includes(ext)) return { kind, label: FILE_KINDS[kind][0], path: FILE_KINDS[kind][1] };
  }
  const m = String(mime || '').toLowerCase();
  const byMime = m.startsWith('video/') ? 'video' : m.startsWith('audio/') ? 'audio'
    : m.startsWith('image/') ? 'picture' : m.includes('pdf') ? 'document'
      : /zip|compressed|x-tar|x-7z|x-rar/.test(m) ? 'archive' : m.includes('iso9660') ? 'image'
        : m.startsWith('text/html') ? 'page' : 'file';
  return { kind: byMime, label: FILE_KINDS[byMime][0], path: FILE_KINDS[byMime][1] };
}
