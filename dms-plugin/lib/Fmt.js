.pragma library

// Formatting helpers shared by every surface of the plugin. Kept in step with
// the manager page's own helpers so both front-ends read identically.

function bytes(n, digits) {
    n = Number(n) || 0
    if (digits === undefined)
        digits = 1
    if (n < 1024)
        return n + " B"
    var units = ["KiB", "MiB", "GiB", "TiB"]
    var i = -1
    do {
        n /= 1024
        i++
    } while (n >= 1024 && i < units.length - 1)
    return n.toFixed(n < 10 ? digits : 0) + " " + units[i]
}

function speed(n) {
    return Number(n) > 0 ? bytes(n) + "/s" : "0 B/s"
}

function eta(seconds) {
    if (seconds === null || seconds === undefined || seconds < 0)
        return "—"
    var s = Math.round(seconds)
    if (s < 60)
        return s + "s"
    if (s < 3600)
        return Math.floor(s / 60) + "m " + (s % 60) + "s"
    if (s < 86400)
        return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m"
    return Math.floor(s / 86400) + "d " + Math.floor((s % 86400) / 3600) + "h"
}

function time(ts) {
    if (!ts)
        return ""
    return new Date(ts * 1000).toLocaleTimeString(Qt.locale(), "HH:mm:ss")
}

function dateTime(ts) {
    if (!ts)
        return ""
    return new Date(ts * 1000).toLocaleString(Qt.locale(), "yyyy-MM-dd HH:mm")
}

// "50K" / "1.5M" / "1024" -> bytes. Mirrors the manager page's parseSize.
function parseSize(value) {
    var text = String(value === null || value === undefined ? "" : value).trim()
    if (!text)
        return null
    var m = text.match(/^([\d.]+)\s*([kmgt])?i?b?\/?s?$/i)
    if (!m)
        return Number(text) || null
    var mult = {
        k: 1024,
        m: 1024 * 1024,
        g: 1024 * 1024 * 1024,
        t: 1024 * 1024 * 1024 * 1024
    }[(m[2] || "").toLowerCase()] || 1
    return Math.round(parseFloat(m[1]) * mult)
}

// Nested "when.speed_below" access, so rule editing can stay declarative.
function getPath(obj, path) {
    return path.split(".").reduce(function (node, key) {
        return node === null || node === undefined ? node : node[key]
    }, obj)
}

function setPath(obj, path, value) {
    var keys = path.split(".")
    var last = keys.pop()
    var node = obj
    for (var i = 0; i < keys.length; i++) {
        if (node[keys[i]] === null || node[keys[i]] === undefined)
            node[keys[i]] = {}
        node = node[keys[i]]
    }
    if (value === "" || value === null || value === undefined)
        delete node[last]
    else
        node[last] = value
    return obj
}

// Daemon vocabulary ("active", "error", "info") is lowercase on the wire but is
// shown as a label, so it gets a capital. Identifiers and option keys never go
// through here.
function label(value) {
    var text = String(value === null || value === undefined ? "" : value)
    return text ? text.charAt(0).toUpperCase() + text.slice(1) : text
}

// aria2's status vocabulary on the wire; what a person reads on screen. The
// same words the manager page and the extension popup use.
var STATUS_LABEL = {
    "active": "Active",
    "waiting": "Queued",
    "paused": "Paused",
    "complete": "Done",
    "error": "Failed",
    "removed": "Removed"
}

function statusLabel(status) {
    return STATUS_LABEL[status] || label(status)
}

function basename(path) {
    var parts = String(path || "").split("/")
    return parts[parts.length - 1] || path || ""
}

// The glyph for a download's status tile: what kind of file it is, so a list
// can be scanned by shape as well as by name. Shared by live rows and history.
function kindIcon(name, isTorrent, isMetadata) {
    if (isMetadata || (isTorrent && !name))
        return "hub"
    var lower = String(name || "").toLowerCase()
    var ext = (lower.match(/\.([a-z0-9]+)$/) || [])[1] || ""
    var kinds = [
        ["movie", ["mkv", "mp4", "webm", "avi", "mov", "m4v", "wmv", "flv", "ts"]],
        ["music_note", ["mp3", "flac", "ogg", "opus", "wav", "m4a", "aac"]],
        ["album", ["iso", "img", "qcow2", "vdi", "vmdk"]],
        ["folder_zip", ["zip", "7z", "rar", "gz", "xz", "zst", "bz2", "tar", "tgz"]],
        ["image", ["png", "jpg", "jpeg", "gif", "webp", "svg", "avif"]],
        ["description", ["pdf", "epub", "doc", "docx", "odt", "txt", "md"]],
        ["inventory_2", ["deb", "rpm", "appimage", "exe", "msi", "pkg", "flatpak"]]
    ]
    for (var i = 0; i < kinds.length; i++) {
        if (kinds[i][1].indexOf(ext) >= 0)
            return kinds[i][0]
    }
    return isTorrent ? "hub" : "draft"
}

// Which day group a timestamp falls in, for History's section headers.
function dayGroup(ts) {
    if (!ts)
        return "Earlier"
    var midnight = new Date()
    midnight.setHours(0, 0, 0, 0)
    var start = midnight.getTime() / 1000
    if (ts >= start)
        return "Today"
    if (ts >= start - 86400)
        return "Yesterday"
    if (ts >= start - 6 * 86400)
        return "This week"
    return "Earlier"
}

// A time short enough for a meta line: "13:52" today, "Mon 13:52" this week,
// "2026-09-14" before that.
function shortWhen(ts) {
    if (!ts)
        return ""
    var date = new Date(ts * 1000)
    var group = dayGroup(ts)
    if (group === "Today")
        return date.toLocaleTimeString(Qt.locale(), "HH:mm")
    if (group === "Yesterday")
        return "yesterday " + date.toLocaleTimeString(Qt.locale(), "HH:mm")
    if (group === "This week")
        return date.toLocaleString(Qt.locale(), "ddd HH:mm")
    return date.toLocaleDateString(Qt.locale(), "yyyy-MM-dd")
}

// "~/Downloads" rather than "/home/someone/Downloads".
function homePath(path, home) {
    var text = String(path || "")
    if (home && text.indexOf(home) === 0)
        return "~" + text.slice(home.length)
    return text
}

// What kind of file a name is, in a word: "Disk image", "Video".
function kindLabel(name, contentType) {
    var words = {
        "movie": "Video",
        "music_note": "Audio",
        "album": "Disk image",
        "folder_zip": "Archive",
        "image": "Image",
        "description": "Document",
        "inventory_2": "Installer"
    }
    var icon = kindIcon(name, false, false)
    if (words[icon])
        return words[icon]
    var type = String(contentType || "").split(";")[0].trim()
    return type || "File"
}

// A link short enough for a list line: host, then the end of the path.
function shortLink(url) {
    var text = String(url || "")
    if (/^magnet:/i.test(text)) {
        var name = text.match(/[?&]dn=([^&]+)/)
        if (name)
            return "magnet · " + decodeURIComponent(name[1].replace(/\+/g, " "))
        var hash = text.match(/btih:([a-z0-9]+)/i)
        return "magnet · " + (hash ? hash[1].slice(0, 8) + "…" : "torrent")
    }
    var m = text.match(/^[a-z]+:\/\/([^/?#]+)([^?#]*)/i)
    if (!m)
        return text
    var parts = m[2].split("/").filter(function (p) { return p.length > 0 })
    if (!parts.length)
        return m[1]
    var tail = parts[parts.length - 1]
    try {
        tail = decodeURIComponent(tail)
    } catch (e) {}
    return m[1] + (parts.length > 1 ? "/…/" : "/") + tail
}

// "12 min ago", "3 h ago", "yesterday", then the date.
function ago(ts) {
    if (!ts)
        return ""
    var s = Math.max(0, Date.now() / 1000 - ts)
    if (s < 60)
        return "just now"
    if (s < 3600)
        return Math.floor(s / 60) + " min ago"
    if (s < 86400)
        return Math.floor(s / 3600) + " h ago"
    if (s < 2 * 86400)
        return "yesterday"
    return shortWhen(ts)
}

// What a search for `text` also looks for: the word as typed, and its stem
// before an English plural ("retry" finds "retries", "proxy" "proxies").
function searchForms(text) {
    var needle = String(text || "").trim().toLowerCase()
    if (!needle)
        return []
    var out = [needle]
    if (needle.length > 3 && /[^aeiou]y$/.test(needle))
        out.push(needle.slice(0, -1) + "i")
    return out
}
