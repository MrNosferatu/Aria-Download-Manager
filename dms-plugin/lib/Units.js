.pragma library
.import "Fmt.js" as Fmt

// Speeds and sizes as a number and a unit. aria2 takes and reports them in
// bytes, which left every limit to be typed as arithmetic; the fields show a
// number and a unit instead and still write bytes. Kept in step with the
// manager page's unitInput() so both front-ends behave identically.

var UNITS = {
    "speed": [["B/s", 1], ["KiB/s", 1024], ["MiB/s", 1048576], ["GiB/s", 1073741824]],
    "size": [["B", 1], ["KiB", 1024], ["MiB", 1048576], ["GiB", 1073741824]]
}

// The unit an empty or zero field starts on: what a limit is usually set in.
var DEFAULT_UNIT = 2

// aria2 options that take a speed or a size, wherever they are shown.
var OPTIONS = {
    "max-overall-download-limit": "speed",
    "max-download-limit": "speed",
    "max-overall-upload-limit": "speed",
    "max-upload-limit": "speed",
    "lowest-speed-limit": "speed",
    "bt-request-peer-speed-limit": "speed",
    "min-split-size": "size",
    "disk-cache": "size",
    "piece-length": "size",
    "max-mmap-limit": "size",
    "no-file-allocation-limit": "size",
    "rpc-max-request-size": "size",
    "socket-recv-buffer-size": "size"
}

function kindFor(key) {
    return OPTIONS[key] || ""
}

function labels(kind) {
    return UNITS[kind].map(function (unit) {
        return unit[0]
    })
}

// bytes (or aria2 shorthand like "12M") -> {amount, unit}, in the largest unit
// the value reaches 1 in. A speed of 0 is aria2's "no limit", which reads better
// as an empty field saying so than as "0 MiB/s".
function split(raw, kind) {
    var bytes = Fmt.parseSize(raw)
    if (bytes === null)
        return { "amount": "", "unit": DEFAULT_UNIT }
    if (bytes === 0)
        return { "amount": kind === "speed" ? "" : "0", "unit": DEFAULT_UNIT }
    var units = UNITS[kind]
    var index = 0
    while (index < units.length - 1 && bytes >= units[index + 1][1])
        index++
    return { "amount": String(Number((bytes / units[index][1]).toFixed(2))), "unit": index }
}

// What the user typed -> bytes as a string ("" when empty). Changing the unit
// reinterprets the number rather than converting it. `raw` is what the field
// was given, for "clearing a set speed means no limit".
function join(text, unit, kind, raw) {
    text = String(text || "").trim()
    if (!text)
        return kind === "speed" && String(raw || "") !== "" ? "0" : ""
    // Shorthand typed into the box carries its own unit.
    if (/[a-z]/i.test(text)) {
        var parsed = Fmt.parseSize(text)
        return parsed === null ? text : String(parsed)
    }
    var number = Number(text)
    // Left as typed, so the manager's validation says what is wrong with it.
    if (!isFinite(number) || number < 0)
        return text
    return String(Math.round(number * UNITS[kind][unit][1]))
}

// config.yaml keeps sizes as written and aria2 reports bytes, so "32M" and
// "33554432" are the same setting spelled two ways.
// Two maps of settings hold the same values: key order aside, a list compared
// as a set ("zip 7z" is "7z zip"), a missing key as an empty value.
function sameMap(a, b) {
    a = a || {}
    b = b || {}
    var keys = {}
    var k
    for (k in a)
        keys[k] = true
    for (k in b)
        keys[k] = true
    for (k in keys) {
        var x = a[k]
        var y = b[k]
        if (Array.isArray(x) || Array.isArray(y)) {
            if ((x || []).slice().sort().join("\n") !== (y || []).slice().sort().join("\n"))
                return false
        } else if (String(x === undefined || x === null ? "" : x) !== String(y === undefined || y === null ? "" : y)) {
            return false
        }
    }
    return true
}

function same(a, b) {
    a = String(a === undefined || a === null ? "" : a).trim()
    b = String(b === undefined || b === null ? "" : b).trim()
    if (a === b)
        return true
    var na = Fmt.parseSize(a)
    var nb = Fmt.parseSize(b)
    return na !== null && nb !== null && na === nb
}
