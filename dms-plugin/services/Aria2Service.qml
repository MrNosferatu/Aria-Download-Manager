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

    function notice(message) {
        if (message)
            root.feedback(message)
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

    //: gids added with "choose files": their detail opens as soon as the file
    //: list is known, on this torrent or (aria2, a magnet) the one it becomes.
    property var pendingChoice: ({})

    function openWhenListed(gids) {
        const next = Object.assign({}, pendingChoice)
        for (const gid of gids)
            next[gid] = true
        pendingChoice = next
    }

    //: The download to open now, if one is ready; it leaves the pending list.
    function takeReadyChoice() {
        for (const dl of downloads) {
            const origin = pendingChoice[dl.gid] ? dl.gid : dl.following
            if (!origin || !pendingChoice[origin] || dl.isMetadata || !(dl.numFiles > 0))
                continue
            const next = Object.assign({}, pendingChoice)
            delete next[origin]
            pendingChoice = next
            return dl.gid
        }
        return ""
    }

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
                    detail: ""
                }))
        if (fired.length)
            root.triggers = fired
    }

    function _notify(event) {
        if (!root.cfg.notify)
            return
        if (event.level === "error")
            ToastService.showError("Aria", event.message)
        else if (event.level === "info" && /finished|complete/i.test(event.message || ""))
            ToastService.showInfo("Aria", event.message)
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
                ToastService.showError("Aria", error)
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
    function bulk(action, gids, deleteFiles, callback) {
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
                      if (data && data.message)
                          root.notice(data.message)
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
    //: Exit and let systemd bring the manager back, rereading config.yaml.
    function restartManager() {
        post("/api/restart", null, "Restarting the manager", () => {
                 root.connected = false
                 restartSettle.restart()
             })
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

    function saveRouting(payload, okMessage) {
        post("/api/routing", payload, okMessage || "Sorting saved", data => {
            if (data)
                root.routing = data
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

    function saveOptions(options, okMessage) {
        post("/api/global/options", {
                 "options": options
             }, okMessage || "Applied", () => root.loadOptions())
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
            root.post("/api/global/pause-all", null, "Paused everything")
            return "paused"
        }

        function resumeAll(): string {
            root.post("/api/global/resume-all", null, "Resumed everything")
            return "resumed"
        }
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
