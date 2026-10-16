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

// Bar-sized speed: at most three digits ("850 KiB/s", "12.4 MiB/s"), so the
// pill keeps a steady width. `compact` drops the unit to a letter ("12M") for
// a vertical bar, where every character costs a line.
function speedShort(n, compact) {
    n = Number(n) || 0
    var units = compact ? ["", "K", "M", "G", "T"] : [" B/s", " KiB/s", " MiB/s", " GiB/s", " TiB/s"]
    var i = 0
    while (n >= 999.5 && i < units.length - 1) {
        n /= 1024
        i++
    }
    var text = i === 0 || n >= 99.95 || (compact && n >= 9.95) ? String(Math.round(n)) : n.toFixed(1)
    return text + units[i]
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
