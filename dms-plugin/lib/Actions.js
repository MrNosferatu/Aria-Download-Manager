.pragma library

// The manager's global actions, described once and rendered twice: as the
// header button row (ManagerActions) and as the right-click quick menu
// (QuickMenu). Endpoints and wording live here so the two surfaces cannot
// drift apart. Treat the exported tables as read-only — .pragma library means
// every importer shares one copy.
//
// Only the static half of an action lives here. Whether it is enabled, and the
// count it shows, are read straight off the service by the QML that renders it:
// property capture is what keeps those bindings live, so the reads have to
// happen in QML rather than behind a function call.

var GLOBAL = [
    {
        "id": "pauseAll",
        "icon": "pause",
        "label": "Pause all",
        "path": "/api/global/pause-all",
        "ok": "Paused everything"
    },
    {
        "id": "resumeAll",
        "icon": "play_arrow",
        "label": "Resume all",
        "path": "/api/global/resume-all",
        "ok": "Resumed everything"
    },
    {
        "id": "purge",
        "icon": "cleaning_services",
        "label": "Clear finished",
        "tooltip": "Clear finished and failed from the list",
        "path": "/api/global/purge",
        "ok": "Cleared finished and failed"
    }
]

function tooltipFor(action) {
    return action.tooltip || action.label
}
