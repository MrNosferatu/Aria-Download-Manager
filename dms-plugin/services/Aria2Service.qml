pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services

// Single connection to the aria2c-manager daemon, shared by every widget
// instance (bar, control center, popout) so multi-monitor setups still open
// exactly one event stream.
Singleton {
    id: root

    readonly property string pluginId: "aria2cManager"
    readonly property var cfg: SettingsData.pluginSettings[pluginId] || ({})

    //: A visible popout pings once a second. Counting open/close events instead
    //: put the stream permanently out of phase whenever the popout's content was
    //: recreated rather than merely hidden; a heartbeat cannot drift — if
    //: nothing is pinging, nothing is watching.
    property double lastViewerPing: 0
    property bool viewerActive: false
    readonly property int idlePollSeconds: parseInt(cfg.idlePollSeconds || "10") || 10
    readonly property bool alwaysStream: cfg.alwaysStream === true

    readonly property string host: cfg.host || "127.0.0.1"
    readonly property int port: parseInt(cfg.port || "6810") || 6810
    readonly property string baseUrl: "http://" + host + ":" + port

    // ---- live snapshot ---------------------------------------------------
    property bool connected: false
    property string lastError: ""
    property var snapshot: null
    property var events: []

    readonly property var downloads: (snapshot && snapshot.downloads) || []
    readonly property var globalStat: (snapshot && snapshot.global) || ({})
    readonly property var counts: (snapshot && snapshot.counts) || ({})
    readonly property var aria2: (snapshot && snapshot.aria2) || ({})
    readonly property var ruleState: (snapshot && snapshot.rules) || ({})

    readonly property int downloadSpeed: globalStat.downloadSpeed || 0
    readonly property int uploadSpeed: globalStat.uploadSpeed || 0
    readonly property int activeCount: counts.active || 0
    readonly property int waitingCount: (counts.waiting || 0) + (counts.paused || 0)
    readonly property int stoppedCount: counts.stopped || 0
    readonly property int errorCount: counts.error || 0
    readonly property bool aria2Running: aria2.running === true

    // ---- lazily fetched sections ----------------------------------------
    property var globalOptions: ({})
    property var rules: []
    property bool rulesEnabled: true
    property string speedSource: "hybrid"
    property var triggers: []
    property var history: null
    property var serverConfig: null
    //: server.web_ui only takes effect at startup, so a change parks here until
    //: the manager is restarted.
    property bool restartRequired: false

    readonly property bool webUiEnabled: serverConfig && serverConfig.server
                                         ? serverConfig.server.web_ui === true : false

    signal rulesLoaded
    signal optionsLoaded
    signal historyLoaded

    //: Bar widgets listen for this so `dms ipc call aria2c toggle` (or a
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
    readonly property var tabNames: ["downloads", "settings", "rules", "log"]

    // ---- event stream ----------------------------------------------------
    property string _pendingEvent: ""
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
            // while curl starts up: fetch the current snapshot right away.
            refreshSnapshot()
            start()
        } else {
            stream.running = false
            reconnectTimer.stop()
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
        if (!root.wantStream)
            return
        if (!stream.running) {
            root.lastFrameAt = Date.now()
            root.streamStarts++
            stream.running = true
        }
    }

    function restart() {
        stream.running = false
        reconnectTimer.stop()
        // A settings change must not resurrect the stream when nothing is
        // watching; the idle poll covers the pill.
        if (root.wantStream)
            Qt.callLater(() => root.start())
        else
            Qt.callLater(() => root.refreshSnapshot())
    }

    onBaseUrlChanged: restart()

    Component.onCompleted: {
        refreshSnapshot()
        start()
        loadConfig()
        loadRules()
        loadLog()
    }

    Process {
        id: stream

        running: false
        command: ["curl", "-sN", "--no-buffer", "--max-time", "0", "-H", "Accept: text/event-stream", root.baseUrl + "/api/events"]

        stdout: SplitParser {
            splitMarker: "\n"
            onRead: data => root._handleLine(data)
        }

        onExited: (exitCode, exitStatus) => {
            root.connected = false
            if (!root.lastError)
                root.lastError = "event stream closed"
            reconnectTimer.restart()
        }
    }

    // A plugin reload drops this singleton; without this the orphaned curl
    // lingers with nobody draining its pipe.
    Component.onDestruction: stream.running = false

    // Supervisor. Two jobs: reconcile the stream with what the UI actually
    // wants (a missed viewer count, a daemon restart or a dropped process would
    // otherwise leave the popout showing a frozen snapshot forever), and notice
    // a pipe that died without curl exiting — the manager pushes state every
    // second and a keepalive every 15s, so a long silence means it is gone.
    Timer {
        id: watchdog

        interval: 4000
        repeat: true
        running: true
        onTriggered: {
            if (root.wantStream && !stream.running) {
                if (!reconnectTimer.running) {
                    root.watchdogTrips++
                    root.start()
                }
                return
            }
            if (!root.wantStream && stream.running) {
                stream.running = false
                return
            }
            if (!stream.running || !root.wantStream)
                return
            if (Date.now() - root.lastFrameAt < 20000)
                return
            root.watchdogTrips++
            root.connected = false
            root.restart()
        }
    }

    Timer {
        id: reconnectTimer
        interval: 3000
        repeat: false
        onTriggered: root.start()
    }

    function _handleLine(rawLine) {
        root.lastFrameAt = Date.now()
        // SSE ends every frame with a blank line, and the reader hands that back
        // as a leading newline on the *next* line rather than as an empty line
        // of its own. Without trimming, "\nevent: state" fails the prefix test,
        // the frame's type is lost, and its data is dropped as unknown — which
        // froze the UI on everything but the first frame.
        const line = String(rawLine).trim()
        if (!line || line.charAt(0) === ":")
            return
        if (line.indexOf("event:") === 0) {
            root._pendingEvent = line.substring(6).trim()
            return
        }
        if (line.indexOf("data:") !== 0)
            return

        const kind = root._pendingEvent || "message"
        root._pendingEvent = ""
        let payload = null
        try {
            payload = JSON.parse(line.substring(5).trim())
        } catch (e) {
            return
        }

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
        }
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
            ToastService.showError("aria2c", event.message)
        else if (event.level === "info" && /finished|complete/i.test(event.message || ""))
            ToastService.showInfo("aria2c", event.message)
    }

    // ---- REST ------------------------------------------------------------
    function request(method, path, body, callback) {
        const xhr = new XMLHttpRequest()
        xhr.onreadystatechange = () => {
            if (xhr.readyState !== XMLHttpRequest.DONE)
                return
            let data = null
            try {
                data = JSON.parse(xhr.responseText)
            } catch (e) {
                data = null
            }
            if (xhr.status >= 200 && xhr.status < 300) {
                if (callback)
                    callback(data, null)
                return
            }
            const detail = data && (data.error || data.detail)
            const message = typeof detail === "string" ? detail
                : (xhr.status ? xhr.status + " " + xhr.statusText : "aria2c-manager is not reachable")
            if (callback)
                callback(null, message)
        }
        xhr.open(method, root.baseUrl + path)
        if (body !== undefined && body !== null)
            xhr.setRequestHeader("Content-Type", "application/json")
        xhr.send(body === undefined || body === null ? undefined : JSON.stringify(body))
    }

    function get(path, callback) {
        request("GET", path, null, callback)
    }

    // Fire a mutating call, toasting the outcome. `callback` sees the payload
    // only on success, matching the web UI's act().
    function act(method, path, body, okMessage, callback) {
        request(method, path, body, (data, error) => {
            if (error) {
                ToastService.showError("aria2c", error)
                return
            }
            if (okMessage)
                ToastService.showInfo("aria2c", okMessage)
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

    // ---- section loaders -------------------------------------------------
    function loadConfig() {
        get("/api/config", (data, error) => {
            if (!error)
                root.serverConfig = data
        })
    }

    // ---- manager settings ------------------------------------------------
    function setManagerConfig(patch, okMessage) {
        post("/api/config", patch, okMessage, data => {
                 if (data && data.config)
                     root.serverConfig = data.config
                 if (data && data.restartRequired)
                     root.restartRequired = true
             })
    }

    function restartManager() {
        post("/api/restart", null, "Restarting the manager…", () => {
                 root.restartRequired = false
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
             }, "Rules saved", data => {
                 if (data && data.rules)
                     root.rules = data.rules
                 root.rulesLoaded()
             })
    }

    function setRulesEnabled(enabled) {
        root.rulesEnabled = enabled
        post("/api/rules", {
                 "enabled": enabled
             }, enabled ? "Rules engine on" : "Rules engine off")
    }

    function setSpeedSource(source) {
        root.speedSource = source
        post("/api/rules", {
                 "speed_source": source
             }, "Rules now judge speed by: " + source)
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
             }, okMessage || "Options applied", () => root.loadOptions())
    }

    function loadHistory() {
        get("/api/history?limit=300", (data, error) => {
            if (error) {
                ToastService.showError("aria2c history", error)
                return
            }
            if (!data)
                return
            root.history = data
            root.historyLoaded()
        })
    }

    IpcHandler {
        target: "aria2c"

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

                    + " running=" + stream.running + " connected=" + root.connected
                    + " silentFor=" + Math.round((Date.now() - root.lastFrameAt) / 1000) + "s"
                    + " starts=" + root.streamStarts + " watchdogTrips=" + root.watchdogTrips
        }

        function tab(name: string): string {
            const at = root.tabNames.indexOf((name || "").toLowerCase())
            if (at < 0)
                return "unknown tab, try: " + root.tabNames.join(", ")
            root.requestedTab = at
            return "showing " + root.tabNames[at]
        }

        function add(url: string): string {
            if (!url)
                return "usage: dms ipc call aria2c add <url>"
            root.post("/api/downloads", {
                          "uris": [url]
                      }, "Queued")
            return "queued " + url
        }

        function status(): string {
            if (!root.connected)
                return "offline (" + root.baseUrl + ")"
            return root.activeCount + " active, " + root.waitingCount + " queued, "
                    + root.stoppedCount + " stopped, down " + root.downloadSpeed + " B/s"
        }

        function pauseAll(): string {
            root.post("/api/global/pause-all", null, "Paused all")
            return "paused"
        }

        function resumeAll(): string {
            root.post("/api/global/resume-all", null, "Resumed all")
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
