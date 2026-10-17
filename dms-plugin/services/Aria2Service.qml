pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Single connection to the Aria Download Manager daemon, shared by every widget
// instance (bar, control center, popout) so multi-monitor setups still open
// exactly one event stream.
Singleton {
    id: root

    readonly property string pluginId: "ariaDownloadManager"
    readonly property var cfg: SettingsData.pluginSettings[pluginId] || ({})

    //: A visible popout pings once a second. Counting open/close events instead
    //: put the stream permanently out of phase whenever the popout's content was
    //: recreated rather than merely hidden; a heartbeat cannot drift — if
    //: nothing is pinging, nothing is watching.
    property double lastViewerPing: 0
    property bool viewerActive: false
    //: How stale the pill may get while nothing is watching the panel. Ten
    //: seconds meant a download could be running for most of that before the
    //: bar admitted it; three keeps the pill roughly in step with the desktop's
    //: other monitors for one cheap request every three seconds.
    readonly property int idlePollSeconds: parseInt(cfg.idlePollSeconds || "3") || 3
    readonly property bool alwaysStream: cfg.alwaysStream === true

    //: The manager's Unix socket. Everything goes through it: a socket never
    //: touches the network stack, so no VPN or proxy can get in between.
    readonly property string socketPath: cfg.socketPath
                                         || ((Quickshell.env("XDG_RUNTIME_DIR") || "")
                                             + "/aria-download-manager.sock")

    // ---- live snapshot ---------------------------------------------------
    property bool connected: false
    property string lastError: ""
    property var snapshot: null
    property var events: []

    readonly property var downloads: (snapshot && snapshot.downloads) || []
    readonly property var globalStat: (snapshot && snapshot.global) || ({})
    readonly property var counts: (snapshot && snapshot.counts) || ({})
    readonly property var aria2: (snapshot && snapshot.aria2) || ({})
    //: The torrent engine when it is qBittorrent (see qbittorrent.py).
    readonly property var qbittorrent: (snapshot && snapshot.qbittorrent) || ({})
    readonly property var ruleState: (snapshot && snapshot.rules) || ({})
    //: Torrents never seed (the manager's download-only setting).
    readonly property bool downloadOnly: !!(snapshot && snapshot.torrent && snapshot.torrent.downloadOnly)

    readonly property int downloadSpeed: globalStat.downloadSpeed || 0
    readonly property int uploadSpeed: globalStat.uploadSpeed || 0
    readonly property int activeCount: counts.active || 0
    readonly property int waitingCount: (counts.waiting || 0) + (counts.paused || 0)
    readonly property int stoppedCount: counts.stopped || 0
    readonly property bool aria2Running: aria2.running === true
    readonly property int pausedCount: counts.paused || 0
    readonly property int queuedCount: counts.waiting || 0
    readonly property int errorCount: counts.error || 0
    readonly property int completeCount: counts.complete || 0

    //: The running downloads summed up, for the bar ring, the quick menu and
    //: the stat strip. `progress` is -1 while any running download has no size
    //: yet (a magnet still fetching its file list), so the ring can stay away
    //: rather than claim a fraction it does not know.
    readonly property var activeTotals: {
        let done = 0
        let total = 0
        let unknown = false
        for (const d of downloads) {
            if (d.status !== "active")
                continue
            if (!d.total || d.isMetadata) {
                unknown = true
                continue
            }
            done += d.completed || 0
            total += d.total
        }
        const left = Math.max(0, total - done)
        return {
            "completed": done,
            "total": total,
            "left": left,
            "progress": (!unknown && total > 0) ? done / total : -1,
            "eta": downloadSpeed > 0 && total > 0 ? left / downloadSpeed : -1
        }
    }

    //: The most interesting few downloads for the quick menu: running ones
    //: first, then paused, then queued.
    readonly property var topDownloads: {
        const rank = {
            "active": 0,
            "paused": 1,
            "waiting": 2
        }
        return downloads.filter(d => rank[d.status] !== undefined)
                        .sort((a, b) => rank[a.status] - rank[b.status])
                        .slice(0, 3)
    }

    //: What finished since midnight among the downloads aria2 still holds, and
    //: the name of the latest, for the idle hover card and control-center tile.
    readonly property var finishedToday: {
        const midnight = new Date()
        midnight.setHours(0, 0, 0, 0)
        const since = midnight.getTime() / 1000
        let count = 0
        let last = null
        for (const d of downloads) {
            if (d.status !== "complete" || !(d.finishedAt >= since))
                continue
            count++
            if (!last || d.finishedAt > last.finishedAt)
                last = d
        }
        return {
            "count": count,
            "last": last ? (last.name || last.gid) : ""
        }
    }

    //: Downloads that finished while nobody had the manager open. The bar
    //: shows a dot until the panel is next opened. Counted from the "complete"
    //: total, so a purge (which lowers it) never produces a false dot.
    property int unseenFinished: 0
    property int _lastCompleteCount: -1

    onCompleteCountChanged: {
        if (_lastCompleteCount >= 0 && completeCount > _lastCompleteCount && !viewerActive)
            unseenFinished += completeCount - _lastCompleteCount
        _lastCompleteCount = completeCount
    }

    onViewerActiveChanged: {
        if (viewerActive)
            unseenFinished = 0
    }

    //: The last minute of total download speed, one sample per snapshot, for
    //: the stat strip's sparkline.
    property var speedHistory: []

    onSnapshotChanged: {
        const next = speedHistory.concat([downloadSpeed])
        speedHistory = next.length > 60 ? next.slice(next.length - 60) : next
        // A restart is over once a snapshot shows it done (see restarting).
        if (root.restarting === "manager" && root.connected)
            root.restarting = ""
        else if (root.restarting === "aria2c" && root.aria2Running && (root.aria2.pid || 0) !== root._restartPid)
            root.restarting = ""
    }

    // ---- lazily fetched sections ----------------------------------------
    property var globalOptions: ({})
    property var rules: []
    property bool rulesEnabled: true
    property string speedSource: "hybrid"
    property var triggers: []
    property var history: null
    property var serverConfig: null

    signal rulesLoaded
    signal optionsLoaded
    signal historyLoaded

    //: Confirmation that something worked ("History cleared", "Rules saved").
    //: Shown inside the panel as a brief animated pill, never as a shell
    //: notification: a success needs a glance, not a popup to dismiss. Errors
    //: still go through ToastService, because they need attention.
    signal feedback(string message)

    //: The undo for the feedback now showing, or null: {run: function}. Set
    //: just before `feedback` fires, so the pill reads it with the message.
    //: Only reversible actions offer one — pausing and resuming. Clearing,
    //: removing and forgetting history do not: what they drop is gone.
    property var pendingUndo: null

    function notice(message, undo) {
        if (!message)
            return
        root.pendingUndo = undo ? {
                                      "run": undo
                                  } : null
        root.feedback(message)
    }

    //: Pause everything, remembering what was running so Undo resumes exactly
    //: those and not whatever was paused before.
    function pauseAllWithUndo(okMessage) {
        const running = root.downloads.filter(d => d.status === "active").map(d => d.gid)
        root.request("POST", "/api/global/pause-all", null, (data, error) => {
            if (error) {
                root.showFailure(root._whatFailed("POST", "/api/global/pause-all"), error)
                return
            }
            root.notice(okMessage || "Paused everything",
                        running.length ? () => root.bulk("resume", running, false, null, "Resumed " + running.length) : null)
        })
    }

    //: Pause or resume one download, with the opposite as its undo.
    function setPaused(gid, pause) {
        const verb = pause ? "pause" : "resume"
        root.request("POST", "/api/download/" + gid + "/" + verb, null, (data, error) => {
            if (error) {
                root.showFailure(root._whatFailed("POST", "/" + verb), error)
                return
            }
            root.notice(pause ? "Paused" : "Resumed", () => root.request("POST", "/api/download/" + gid + "/" + (pause ? "resume" : "pause"), null, null))
        })
    }

    //: Bar widgets listen for this so `dms ipc call ariaDownloadManager toggle` (or a
    //: compositor keybind) opens the manager window without a click.
    signal popoutToggleRequested

    //: Same, for the detached window. Only the widget that holds the window
    //: claim answers it; forceShow lets a non-owning bar open the window
    //: rather than flip it shut.
    signal windowToggleRequested(bool forceShow)

    //: One bar instance hosts the detached window, or a multi-monitor setup
    //: would open one window per bar. First bar-hosted widget to ask wins, and
    //: hands the claim back when it goes away.
    property var windowOwner: null

    function claimWindow(who) {
        if (!windowOwner)
            windowOwner = who
        return windowOwner === who
    }

    function releaseWindow(who) {
        if (windowOwner === who)
            windowOwner = null
    }

    //: Which tab the popout shows. Changing it switches an open popout, and
    //: preselects the tab for the next one.
    property int requestedTab: 0
    //: Order matches the tab bar, which is what requestedTab indexes into.
    readonly property var tabNames: ["downloads", "rules", "settings"]

    //: The log moved into Settings — it is diagnostic material, not a main
    //: view — but `tab log` was documented, so it still lands somewhere useful.
    readonly property int settingsTabIndex: tabNames.indexOf("settings")

    //: Set alongside requestedTab to open the Settings tab with its event log
    //: section already expanded.
    property bool requestedLog: false


    // ---- event stream ----------------------------------------------------
    //: Whether the manager is currently sending live frames on the socket.
    property bool subscribed: false
    property double lastFrameAt: 0
    property int streamStarts: 0
    property int watchdogTrips: 0
    property int stateFrames: 0
    property int otherFrames: 0

    readonly property bool wantStream: viewerActive || alwaysStream

    function viewerPing() {
        lastViewerPing = Date.now()
        if (!viewerActive)
            viewerActive = true
    }

    Timer {
        id: viewerTicker

        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            const stale = Date.now() - root.lastViewerPing > 2500
            if (root.viewerActive === stale)
                root.viewerActive = !stale
        }
    }

    onWantStreamChanged: {
        if (wantStream) {
            // Opening the window must not show the last idle poll's numbers
            // while the stream starts: fetch the current snapshot right away.
            refreshSnapshot()
            start()
        } else {
            root.unsubscribe()
            root.refreshSnapshot()
        }
    }

    // Cheap stand-in for the stream: one snapshot, no long-lived connection.
    function refreshSnapshot() {
        get("/api/state", (data, error) => {
                if (error) {
                    root.connected = false
                    root.lastError = error
                    return
                }
                root.snapshot = data
                root.connected = true
                root.lastError = ""
                root.lastFrameAt = Date.now()
            })
    }

    Timer {
        id: idlePoll

        interval: root.idlePollSeconds * 1000
        repeat: true
        running: !root.wantStream
        triggeredOnStart: true
        onTriggered: root.refreshSnapshot()
    }

    function start() {
        // Asked for again from onConnectionStateChanged once the link is up.
        if (!root.wantStream || root.subscribed || !link.linkUp)
            return
        root.lastFrameAt = Date.now()
        root.streamStarts++
        root.subscribed = true
        root._send({
                       "method": "SUBSCRIBE"
                   }, null)
    }

    function unsubscribe() {
        if (!root.subscribed)
            return
        root.subscribed = false
        if (link.linkUp)
            root._send({
                           "method": "UNSUBSCRIBE"
                       }, null)
    }

    //: Drop the connection and dial again. The stream comes back with it when
    //: something is watching; the idle poll covers the pill otherwise.
    function restart() {
        root.subscribed = false
        link.connected = false
        Qt.callLater(() => link.connected = true)
    }

    onSocketPathChanged: restart()

    // A plugin reload drops this singleton; close the socket with it.
    Component.onDestruction: link.connected = false

    Component.onCompleted: {
        refreshSnapshot()
        loadConfig()
        loadRules()
        loadLog()
    }

    // ---- the socket ------------------------------------------------------
    //: One connection for everything: newline-delimited JSON, requests matched
    //: to replies by id, live frames arriving on the same connection. See
    //: aria_download_manager/ipc.py for the protocol.
    property int _nextId: 0
    property var _pending: ({})
    property var _outbox: []
    property double _outboxSince: 0

    //: DMS's own wrapper rather than a bare Socket: Quickshell's Socket cannot
    //: redial after a failed attempt, so a manager restart that outlasted the
    //: first retry left the widget offline for good. DankSocket gives every
    //: attempt a fresh Socket and backs off between them.
    DankSocket {
        id: link

        path: root.socketPath
        connected: true

        parser: SplitParser {
            splitMarker: "\n"
            onRead: data => root._handleLine(data)
        }

        onConnectionStateChanged: {
            if (linkUp) {
                const queued = root._outbox
                root._outbox = []
                for (const line of queued)
                    link.send(line)
                // A new connection has no subscription: the old one died with
                // the old connection (or the old manager).
                root.subscribed = false
                if (root.wantStream)
                    root.start()
                else
                    root.refreshSnapshot()
                return
            }
            root.connected = false
            root.subscribed = false
            root._failPending("Aria Download Manager closed the connection")
        }
    }

    function _send(message, callback) {
        const id = ++root._nextId
        message.id = id
        if (callback)
            root._pending[id] = {
                "callback": callback,
                "at": Date.now()
            }
        const line = JSON.stringify(message) + "\n"
        if (link.linkUp) {
            link.send(line)
            return
        }
        // Held briefly: the first calls of a session race the first dial. The
        // sweep fails them if the link does not come up, so the pill says
        // "offline" instead of waiting on a manager that is not there.
        if (!root._outbox.length)
            root._outboxSince = Date.now()
        root._outbox = root._outbox.concat([line]).slice(-50)
    }

    function _failPending(message) {
        const pending = root._pending
        root._pending = ({})
        root._outbox = []
        for (const id in pending)
            pending[id].callback(null, message)
    }

    Timer {
        id: pendingSweep

        interval: 500
        repeat: true
        running: true
        onTriggered: {
            const now = Date.now()
            if (!link.linkUp && root._outbox.length && now - root._outboxSince > 1500) {
                root.connected = false
                root.lastError = "no Aria Download Manager at " + root.socketPath
                root._failPending(root.lastError)
                return
            }
            for (const id in root._pending) {
                const entry = root._pending[id]
                if (now - entry.at < 20000)
                    continue
                delete root._pending[id]
                entry.callback(null, "Aria Download Manager did not answer")
            }
        }
    }

    // Supervisor. Two jobs: reconcile the stream with what the UI actually
    // wants (a missed viewer ping would otherwise leave the popout showing a
    // frozen snapshot forever), and notice a connection that went quiet without
    // closing — the manager pushes state on every poll, so a long silence means
    // it is gone.
    Timer {
        id: watchdog

        interval: 4000
        repeat: true
        running: true
        onTriggered: {
            if (root.wantStream && !root.subscribed) {
                if (link.linkUp) {
                    root.watchdogTrips++
                    root.start()
                }
                return
            }
            if (!root.wantStream && root.subscribed) {
                root.unsubscribe()
                return
            }
            if (!root.subscribed)
                return
            if (Date.now() - root.lastFrameAt < 20000)
                return
            root.watchdogTrips++
            root.connected = false
            root.restart()
        }
    }

    function _handleLine(rawLine) {
        const line = String(rawLine).trim()
        if (!line)
            return
        let message = null
        try {
            message = JSON.parse(line)
        } catch (e) {
            return
        }
        if (message.event === undefined) {
            root._settle(message)
            return
        }

        root.lastFrameAt = Date.now()
        const kind = message.event
        const payload = message.data
        if (kind === "state") {
            root.stateFrames++
            root.snapshot = payload
            root.connected = true
            root.lastError = ""
        } else {
            root.otherFrames++
        }
        if (kind === "backlog") {
            root.events = payload || []
            root._syncTriggers()
        } else if (kind === "event") {
            const merged = [payload].concat(root.events)
            root.events = merged.slice(0, 400)
            root._syncTriggers()
            root._notify(payload)
        } else if (kind === "shutdown") {
            // The manager is going away and will close the socket; the
            // reconnect timer picks up the next one.
            root.connected = false
        }
    }

    //: A reply to one of our requests.
    function _settle(message) {
        const entry = root._pending[message.id]
        if (!entry)
            return
        delete root._pending[message.id]
        const status = message.status || 0
        const data = message.body
        if (status >= 200 && status < 300) {
            entry.callback(data, null)
            return
        }
        const detail = data && (data.error || data.detail)
        entry.callback(null, typeof detail === "string" ? detail
                                                        : (status ? "HTTP " + status : "Aria Download Manager is not reachable"))
    }

    function _syncTriggers() {
        const fired = root.events.filter(e => e.level === "rule").map(e => ({
                    ts: e.ts,
                    rule: e.rule || "?",
                    action: e.action || "",
                    name: e.message,
                    speed: e.speed || 0,
                    detail: "",
                    //: Rebuilt from the log line, which already says it all.
                    logLine: true
                }))
        if (fired.length)
            root.triggers = fired
    }

    //: Finishes and errors are toggled apart; a setup from before the split
    //: has only the single `notify` key, which still turns on both.
    readonly property bool notifyFinished: cfg.notifyFinished !== undefined ? cfg.notifyFinished === true : cfg.notify === true
    readonly property bool notifyErrors: cfg.notifyErrors !== undefined ? cfg.notifyErrors === true : cfg.notify === true

    function _notify(event) {
        if (event.level === "error" && root.notifyErrors)
            root.showFailure("Aria", event.message)
        else if (event.level === "info" && root.notifyFinished && /finished|complete/i.test(event.message || ""))
            ToastService.showInfo("Aria", event.message)
    }

    // ---- errors in plain words ---------------------------------------------
    //: The failures people actually meet, matched on what aria2 or the manager
    //: wrote, each turned into why it happened and what to do about it.
    readonly property var _errorWords: [
        [/status=404|\b404\b|not found/i, "the server says the file isn't there (404)", "Check the link, or copy it again from the page it came from."],
        [/status=403|\b403\b|forbidden/i, "the server refused it (403)", "The link may have expired or need the browser's cookies. Send it from the browser extension instead."],
        [/status=401|\b401\b|unauthori[sz]ed/i, "the server wants a login (401)", "Add cookies, or a user and password, under Advanced when adding it."],
        [/not enough disk space|no space left|enospc/i, "the disk is full", "Free some space or pick another folder, then retry."],
        [/permission denied|eacces|eperm|read-only file system/i, "the folder can't be written to", "Pick a folder you own, or fix its permissions."],
        [/unsupported (protocol|scheme)|no uri|invalid uri|bad uri|not supported/i, "that isn't a link aria2 can fetch", "Use an http, https, ftp, sftp or magnet link."],
        [/resolve|name or service not known|getaddrinfo/i, "the server's name couldn't be found", "Check the address and your connection."],
        [/timed? ?out|timeout/i, "the server stopped answering", "Retry, or lower the number of connections."],
        [/checksum|hash .*(mismatch|fail)/i, "the file doesn't match its checksum", "It was not kept. Download it again."]
    ]

    //: {why, todo} for an error we know, or null.
    function explainError(raw) {
        const text = String(raw || "")
        for (const entry of root._errorWords) {
            if (entry[0].test(text))
                return {
                    "why": entry[1],
                    "todo": entry[2]
                }
        }
        return null
    }

    //: What the user was trying to do, from the request that failed.
    function _whatFailed(method, path) {
        const p = String(path || "")
        if (/^\/api\/downloads(\/file)?$/.test(p) || p === "/api/history/readd" || p === "/api/intake/add")
            return "Couldn't add the download"
        if (/\/pause$/.test(p) || p === "/api/global/pause-all")
            return "Couldn't pause"
        if (/\/resume$/.test(p) || p === "/api/global/resume-all")
            return "Couldn't resume"
        if (/\/retry$/.test(p))
            return "Couldn't retry"
        if (method === "DELETE" || /bulk$/.test(p))
            return "Couldn't remove it"
        if (/options$/.test(p) || p === "/api/routing" || p === "/api/rules")
            return "Couldn't save"
        if (p === "/api/aria2/restart" || p === "/api/restart")
            return "Couldn't restart"
        return "Aria"
    }

    //: One error toast: what failed and why as the headline, what to do and
    //: the original message in the details.
    function showFailure(what, raw) {
        const known = root.explainError(raw)
        if (known)
            ToastService.showError(what + " — " + known.why, known.todo + "\n\n" + raw)
        else
            ToastService.showError(what, String(raw || ""))
    }

    // ---- API calls -------------------------------------------------------
    //: Same method + path + JSON body as the REST API; the socket carries them.
    function request(method, path, body, callback) {
        const message = {
            "method": method,
            "path": path
        }
        if (body !== undefined && body !== null)
            message.body = body
        root._send(message, callback || ((data, error) => {}))
    }

    function get(path, callback) {
        request("GET", path, null, callback)
    }

    // Fire a mutating call, toasting the outcome. `callback` sees the payload
    // only on success, matching the manager page's act().
    function act(method, path, body, okMessage, callback) {
        request(method, path, body, (data, error) => {
            if (error) {
                root.showFailure(root._whatFailed(method, path), error)
                return
            }
            root.notice(okMessage)
            if (callback)
                callback(data)
        })
    }

    function post(path, body, okMessage, callback) {
        act("POST", path, body, okMessage, callback)
    }

    function del(path, okMessage, callback) {
        act("DELETE", path, null, okMessage, callback)
    }

    //: Remove one download. aria2 never touches the bytes itself, so a removed
    //: download leaves its part file and .aria2 control file behind unless
    //: deleteFiles says otherwise — which is what the caller has just asked the
    //: user about.
    function removeDownload(gid, deleteFiles, okMessage) {
        const query = "?force=true&purge=true" + (deleteFiles ? "&delete_files=true" : "")
        root.del("/api/download/" + gid + query,
                 okMessage !== undefined ? okMessage
                                         : (deleteFiles ? "Removed with its file" : "Removed"))
    }

    //: One action across a chosen set. The server reports per-gid failures
    //: rather than giving up on the first one, and hands back a summary line.
    //: `message` replaces the server's summary line when given. Pausing and
    //: resuming a set can be undone with the opposite on the same set.
    function bulk(action, gids, deleteFiles, callback, message) {
        if (!gids || !gids.length)
            return
        root.post("/api/downloads/bulk", {
                      "action": action,
                      "gids": gids,
                      "delete_files": deleteFiles === true,
                      "force": true
                  }, "", data => {
                      // act() only calls back on success and toasts failures
                      // itself, so the server's summary is the whole story here.
                      const done = (data && data.done) || []
                      const opposite = {
                          "pause": "resume",
                          "resume": "pause"
                      }[action]
                      const undo = opposite && done.length && message === undefined
                                 ? () => root.bulk(opposite, done, false, null, "") : null
                      const text = message !== undefined ? message : (data && data.message)
                      if (text)
                          root.notice(text, undo)
                      if (callback)
                          callback(data)
                  })
    }

    // ---- section loaders -------------------------------------------------
    function loadConfig() {
        get("/api/config", (data, error) => {
            if (!error)
                root.serverConfig = data
        })
    }

    // ---- manager ---------------------------------------------------------
    //: "manager" or "aria2c" while a restart is under way, "" otherwise. The
    //: panel shows it in place — a restarting manager is not an offline one —
    //: and it clears with the first snapshot that shows the restart done.
    property string restarting: ""
    property int _restartPid: 0

    //: Exit and let systemd bring the manager back, rereading config.yaml.
    function restartManager() {
        root.restarting = "manager"
        restartGiveUp.restart()
        root.request("POST", "/api/restart", null, (data, error) => {
            if (error) {
                root.restarting = ""
                root.showFailure(root._whatFailed("POST", "/api/restart"), error)
                return
            }
            root.connected = false
            restartSettle.restart()
        })
    }

    function restartAria2() {
        root.restarting = "aria2c"
        root._restartPid = root.aria2.pid || 0
        restartGiveUp.restart()
        root.request("POST", "/api/aria2/restart", null, (data, error) => {
            if (error) {
                root.restarting = ""
                root.showFailure(root._whatFailed("POST", "/api/aria2/restart"), error)
                return
            }
            root.notice("aria2c restarted")
        })
    }


    //: A restart that never visibly finishes stops claiming to be one.
    Timer {
        id: restartGiveUp

        interval: 30000
        onTriggered: root.restarting = ""
    }

    Timer {
        id: restartSettle

        interval: 4000
        repeat: false
        onTriggered: {
            root.loadConfig()
            if (root.wantStream)
                root.restart()
            else
                root.refreshSnapshot()
        }
    }

    function loadLog() {
        get("/api/log?limit=200", (data, error) => {
            if (error || !data)
                return
            root.events = data.events || []
            if (data.triggers && data.triggers.length)
                root.triggers = data.triggers
        })
    }

    function loadRules() {
        get("/api/rules", (data, error) => {
            if (error || !data)
                return
            root.rules = data.rules || []
            root.rulesEnabled = data.enabled !== false
            root.speedSource = data.speed_source || "hybrid"
            if (data.triggers && data.triggers.length)
                root.triggers = data.triggers
            root.rulesLoaded()
        })
    }

    function saveRules(rules, enabled, speedSource) {
        post("/api/rules", {
                 "rules": rules,
                 "enabled": enabled,
                 "speed_source": speedSource
             }, "Actions saved", data => {
                 if (data && data.rules)
                     root.rules = data.rules
                 root.rulesLoaded()
             })
    }

    function setRulesEnabled(enabled) {
        root.rulesEnabled = enabled
        post("/api/rules", {
                 "enabled": enabled
             }, enabled ? "Actions on" : "Actions off")
    }

    function setSpeedSource(source) {
        root.speedSource = source
        post("/api/rules", {
                 "speed_source": source
             }, "Speed judged by: " + ({"hybrid": "Hybrid", "measured": "Write speed", "aria2": "Reported speed"}[source] || source))
    }

    //: Where downloads go by file type. A manager setting, not an aria2 one,
    //: so it has its own endpoint rather than riding with the options.
    property var routing: null

    function loadRouting() {
        get("/api/routing", (data, error) => {
            if (error || !data)
                return
            root.routing = data
        })
    }

    //: `done(error)` hears how it went: "" on success, the reason otherwise.
    //: A caller that passes it shows the failure itself.
    function saveRouting(payload, okMessage, done) {
        root.request("POST", "/api/routing", payload, (data, error) => {
            if (error) {
                if (done)
                    done(error)
                else
                    root.showFailure("Couldn't save", error)
                return
            }
            if (data)
                root.routing = data
            root.notice(okMessage || "Sorting saved")
            if (done)
                done("")
        })
    }

    function loadOptions() {
        get("/api/global/options", (data, error) => {
            if (error || !data)
                return
            root.globalOptions = data
            root.optionsLoaded()
        })
    }

    function saveOptions(options, okMessage, done) {
        root.request("POST", "/api/global/options", {
                         "options": options
                     }, (data, error) => {
            if (error) {
                if (done)
                    done(error)
                else
                    root.showFailure("Couldn't save", error)
                return
            }
            root.notice(okMessage || "Applied")
            root.loadOptions()
            if (done)
                done("")
        })
    }

    function loadHistory() {
        get("/api/history?limit=300", (data, error) => {
            if (error) {
                ToastService.showError("Aria", error)
                return
            }
            if (!data)
                return
            root.history = data
            root.historyLoaded()
        })
    }

    IpcHandler {
        target: "ariaDownloadManager"

        function toggle(): string {
            root.popoutToggleRequested()
            return "toggled"
        }

        function toggleWindow(): string {
            if (!root.windowOwner)
                return "no bar is hosting the widget"
            root.windowToggleRequested(false)
            return "toggled window"
        }

        function streamInfo(): string {
            const age = root.snapshot ? Math.round(Date.now() / 1000 - root.snapshot.ts) : -1
            return "viewer=" + root.viewerActive + " wantStream=" + root.wantStream
                    + " stateFrames=" + root.stateFrames + " other=" + root.otherFrames
                    + " snapshotAge=" + age + "s"
                    + " downloads=" + root.downloads.length

                    + " socket=" + root.socketPath + " linked=" + link.linkUp
                    + " subscribed=" + root.subscribed + " connected=" + root.connected
                    + " silentFor=" + Math.round((Date.now() - root.lastFrameAt) / 1000) + "s"
                    + " starts=" + root.streamStarts + " watchdogTrips=" + root.watchdogTrips
        }

        function tab(name: string): string {
            const wanted = (name || "").toLowerCase()
            if (wanted === "log") {
                root.requestedLog = true
                root.requestedTab = root.settingsTabIndex
                return "showing the event log under settings"
            }
            // "Actions" is what the tab says; "rules" is what config.yaml and the
            // API say, and what was documented, so both open the same tab.
            const at = root.tabNames.indexOf(wanted === "actions" ? "rules" : wanted)
            if (at < 0)
                return "unknown tab, try: " + root.tabNames.concat(["log"]).join(", ")
            root.requestedLog = false
            root.requestedTab = at
            return "showing " + root.tabNames[at]
        }

        function add(url: string): string {
            if (!url)
                return "usage: dms ipc call ariaDownloadManager add <url>"
            root.post("/api/downloads", {
                          "uris": [url]
                      }, "Added")
            return "queued " + url
        }

        function status(): string {
            if (!root.connected)
                return "offline (" + root.socketPath + ")"
            return root.activeCount + " active, " + root.waitingCount + " queued, "
                    + root.stoppedCount + " stopped, down " + root.downloadSpeed + " B/s"
        }

        function pauseAll(): string {
            root.pauseAllWithUndo("Paused everything")
            return "paused"
        }

        function resumeAll(): string {
            root.post("/api/global/resume-all", null, "Resumed everything")
            return "resumed"
        }
    }

    // ---- torrents held for a file choice ------------------------------------
    //: gid -> true for torrents the Add panel added held, so the list can mark
    //: them "waiting for you" and offer the file choice, even after the Add
    //: panel is closed. Kept for the shell session; a held torrent left over
    //: from before a restart is an ordinary paused one.
    property var heldGids: ({})

    function holdForChoice(gid) {
        const next = Object.assign({}, root.heldGids)
        next[gid] = true
        root.heldGids = next
    }

    function releaseHold(gid) {
        if (!root.heldGids[gid])
            return
        const next = Object.assign({}, root.heldGids)
        delete next[gid]
        root.heldGids = next
    }

    //: A held torrent, or the download aria2 made from a held magnet once its
    //: file list arrived, still paused and waiting.
    function isHeldForChoice(dl) {
        if (!dl || dl.status !== "paused" || dl.isMetadata)
            return false
        return root.heldGids[dl.gid] === true || (!!dl.following && root.heldGids[dl.following] === true)
    }

    // ---- rule bookkeeping for a single download --------------------------
    function rulesFor(gid) {
        const perDownload = root.ruleState.downloads || ({})
        return perDownload[gid] || ({})
    }

    function isActing(gid) {
        const info = rulesFor(gid)
        for (const name in info) {
            if (info[name].acting)
                return true
        }
        return false
    }
}
