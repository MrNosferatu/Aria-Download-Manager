.pragma library
.import "Fmt.js" as Fmt

// Automatic actions in words: the one-line summary a folded card shows, and
// the templates the empty Actions tab offers. The rule objects are the ones
// config.yaml holds (see aria_download_manager/rules.py).

var ACTION_WORDS = {
    "pause_resume": "pause, then resume",
    "force_pause_resume": "force pause, then resume",
    "restart": "remove and add again",
    "set_option": "change its options",
    "stop": "pause and leave paused",
    "log_only": "only log it"
}

// What a set_option rule sets, in words where the option is a common one.
function optionWords(options) {
    var parts = []
    for (var key in (options || {})) {
        var value = options[key]
        if (key === "max-download-limit")
            parts.push("limit to " + Fmt.speed(Fmt.parseSize(value) || 0))
        else if (key === "max-upload-limit")
            parts.push("limit uploads to " + Fmt.speed(Fmt.parseSize(value) || 0))
        else if (key === "max-connection-per-server")
            parts.push(value + " connections per server")
        else
            parts.push(key + " = " + value)
    }
    return parts.join(", ")
}

// "Under 50 KiB/s for 3 s → pause, then resume"
function summary(rule) {
    var when = (rule && rule.when) || {}
    var lead = []
    if (when.torrent_only)
        lead.push("Torrents")
    else if (when.http_only)
        lead.push("Normal downloads")
    if (when.name_matches)
        lead.push("named /" + when.name_matches + "/")
    var cond = ""
    if (when.speed_below !== undefined && when.speed_below !== "")
        cond = "under " + Fmt.speed(Number(when.speed_below))
    else if (when.speed_above !== undefined && when.speed_above !== "")
        cond = "over " + Fmt.speed(Number(when.speed_above))
    else if (when.connections_below !== undefined && when.connections_below !== "")
        cond = "under " + when.connections_below + " connections"
    if (when.for_seconds)
        cond += " for " + when.for_seconds + " s"
    if (when.min_progress)
        cond += " past " + when.min_progress + "%"
    var action = rule.action === "set_option" && rule.options && Object.keys(rule.options).length
               ? optionWords(rule.options) : (ACTION_WORDS[rule.action || "pause_resume"] || String(rule.action || ""))
    if ((rule.action === "pause_resume" || rule.action === "force_pause_resume") && rule.resume_after_seconds)
        action += " after " + rule.resume_after_seconds + " s"
    var head = (lead.length ? lead.join(", ") + ": " : "") + cond
    head = head.charAt(0).toUpperCase() + head.slice(1)
    return head + " → " + action
}

// The empty tab's starting points; each is added and opened in one click.
var TEMPLATES = [
    {
        "icon": "speed",
        "title": "Kick stalled downloads",
        "rule": {
            "name": "Stall kick",
            "enabled": true,
            "description": "Pause and resume a download that stalls",
            "when": {
                "statuses": ["active"],
                "speed_below": 51200,
                "for_seconds": 3,
                "min_age_seconds": 8
            },
            "action": "pause_resume",
            "resume_after_seconds": 1.5,
            "cooldown_seconds": 25,
            "max_triggers": 20
        }
    },
    {
        "icon": "hub",
        "title": "Restart dead torrents",
        "rule": {
            "name": "Dead torrent",
            "enabled": true,
            "description": "Start a torrent over when it stops getting data",
            "when": {
                "statuses": ["active"],
                "torrent_only": true,
                "speed_below": 1024,
                "for_seconds": 120,
                "min_progress": 5
            },
            "action": "restart",
            "cooldown_seconds": 600,
            "max_triggers": 3
        }
    },
    {
        "icon": "bedtime",
        "title": "Slow down big files",
        "rule": {
            "name": "Slow ISOs",
            "enabled": true,
            "description": "Keep disk images from taking the whole line",
            "when": {
                "statuses": ["active"],
                "name_matches": "\\.iso$",
                "speed_above": 2097152,
                "for_seconds": 5
            },
            "action": "set_option",
            "options": {
                "max-download-limit": "2M"
            },
            "max_triggers": 1
        }
    }
]

// What an action did, as a trigger line says it afterwards.
var ACTION_DONE = {
    "pause_resume": "paused and resumed",
    "force_pause_resume": "force-paused and resumed",
    "restart": "restarted",
    "set_option": "options changed",
    "stop": "paused",
    "log_only": "logged"
}

// One fired action after its time and rule name (board 7):
// "debian-13.1.0-amd64-netinst.iso · 12 KiB/s → paused and resumed".
function triggerLine(t) {
    if (t.logLine)
        return String(t.name).replace(/^\[[^\]]*\]\s*/, "")
    var done = ACTION_DONE[t.action] || String(t.action || "").replace(/_/g, " ")
    return t.name + " · " + Fmt.speed(t.speed) + (done ? " → " + done : "") + (t.detail ? " (" + t.detail + ")" : "")
}

// Where a JSON text stops parsing, as "Line N: what", or "" when it parses.
function jsonProblem(text) {
    try {
        JSON.parse(text)
        return ""
    } catch (e) {
        var trailing = /,(\s*)[}\]]/.exec(text)
        if (trailing)
            return "Line " + lineAt(text, trailing.index) + ": a comma before a closing bracket"
        var where = /position (\d+)/i.exec(String(e.message))
        if (where)
            return "Line " + lineAt(text, Number(where[1])) + ": " + e.message
        var unquoted = /[{,]\s*([A-Za-z_][\w-]*)\s*:/.exec(text)
        if (unquoted)
            return "Line " + lineAt(text, unquoted.index + unquoted[0].indexOf(unquoted[1]))
                    + ": names need double quotes (\"" + unquoted[1] + "\")"
        // Qt's parser says no more than "Parse error".
        return "Not valid JSON — check the commas, quotes and brackets"
    }
}

function lineAt(text, index) {
    return text.slice(0, index).split("\n").length
}
