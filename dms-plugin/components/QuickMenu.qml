import QtQuick
import Quickshell
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Actions.js" as Actions
import "../lib/Fmt.js" as Fmt

//: Right-click menu for the bar pill: the handful of things worth doing
//: without opening the manager at all.
DankPopout {
    id: menu

    property var service: null

    //: The window is the widget's to own, so that one action goes back out.
    signal windowRequested

    readonly property int rowHeight: 34
    readonly property int separatorHeight: Theme.spacingS * 2 + 1
    readonly property int statusHeight: 40
    readonly property int padding: Theme.spacingS

    readonly property bool online: service && service.connected

    //: One row per entry, in order. The counts and enabled flags are read off
    //: the service here rather than in Actions.js so the bindings stay live.
    readonly property var entries: {
        const svc = menu.service
        const on = menu.online
        const counts = {
            "pauseAll": on && svc.activeCount > 0 ? svc.activeCount : 0,
            "resumeAll": on && svc.waitingCount > 0 ? svc.waitingCount : 0,
            "purge": on && svc.stoppedCount > 0 ? svc.stoppedCount : 0
        }

        const rows = [
            {
                "icon": "open_in_new",
                "text": "Open in window",
                "action": () => menu.windowRequested()
            },
            {
                "icon": "content_paste",
                "text": "Add link from clipboard",
                "enabled": on,
                "action": () => clipboard.running = true
            },
            {
                "separator": true
            }
        ]

        for (const action of Actions.GLOBAL) {
            const count = counts[action.id]
            rows.push({
                          "icon": action.icon,
                          "text": action.label,
                          "detail": count > 0 ? String(count) : "",
                          // Resume is worth offering with nothing paused —
                          // aria2 may still be holding downloads back — but
                          // pausing or purging nothing is a no-op.
                          "enabled": on && (action.id === "resumeAll" || count > 0),
                          "action": () => svc.post(action.path, null, action.ok)
                      })
        }

        return rows.concat([
                               {
                                   "separator": true
                               },
                               {
                                   "icon": "auto_fix_high",
                                   "text": on && svc.rulesEnabled ? "Turn actions off" : "Turn actions on",
                                   "enabled": on,
                                   "action": () => svc.setRulesEnabled(!svc.rulesEnabled)
                               },
                               {
                                   "separator": true
                               },
                               {
                                   "icon": "restart_alt",
                                   "text": "Restart aria2c",
                                   "enabled": on,
                                   "danger": true,
                                   "action": () => svc.post("/api/aria2/restart", null, "aria2c restarted")
                               }
                           ])
    }

    function trigger(action) {
        menu.close()
        if (action)
            action()
    }

    //: wl-clipboard is not a hard dependency of the plugin, so a missing or
    //: unhelpful wl-paste has to say so rather than fail quietly.
    function addFromClipboard(text) {
        const url = (text || "").trim()
        if (!/^(https?|ftp|sftp|magnet):/i.test(url)) {
            ToastService.showError("Aria", "The clipboard does not hold a link that can be downloaded")
            return
        }
        menu.service.post("/api/downloads", {
                              "uris": [url]
                          }, "Added")
    }

    Process {
        id: clipboard

        command: ["wl-paste", "-n"]
        running: false

        stdout: StdioCollector {
            onStreamFinished: menu.addFromClipboard(text)
        }

        onExited: exitCode => {
            if (exitCode !== 0)
                ToastService.showError("Aria", "Could not read the clipboard. Is wl-clipboard installed?")
        }
    }

    layerNamespace: "dms:plugins:aria-download-manager-quick"
    popupWidth: 260
    popupHeight: {
        let total = menu.padding * 2 + menu.statusHeight
        for (const entry of menu.entries)
            total += entry.separator ? menu.separatorHeight : menu.rowHeight
        return total
    }
    shouldBeVisible: false

    onBackgroundClicked: close()

    content: Component {
        Item {
            id: menuBody

            focus: true

            Component.onCompleted: {
                if (menu.shouldBeVisible)
                    forceActiveFocus()
            }

            Keys.onPressed: event => {
                if (event.key === Qt.Key_Escape) {
                    menu.close()
                    event.accepted = true
                }
            }

            Connections {
                target: menu
                function onShouldBeVisibleChanged() {
                    if (menu.shouldBeVisible)
                        Qt.callLater(() => menuBody.forceActiveFocus())
                }
            }

            Column {
                anchors.fill: parent
                anchors.margins: menu.padding
                spacing: 0

                Item {
                    width: parent.width
                    height: menu.statusHeight

                    Column {
                        anchors.left: parent.left
                        anchors.leftMargin: Theme.spacingS
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 0

                        StyledText {
                            text: "Aria Download Manager"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Bold
                            color: Theme.surfaceText
                        }

                        StyledText {
                            text: {
                                const svc = menu.service
                                if (!menu.online)
                                    return "Offline · " + (svc ? svc.socketPath : "")
                                if (svc.activeCount > 0)
                                    return svc.activeCount + " active · " + Fmt.speed(svc.downloadSpeed)
                                if (svc.waitingCount > 0)
                                    return svc.waitingCount + " queued"
                                return "Idle"
                            }
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                Repeater {
                    model: menu.entries

                    QuickMenuRow {
                        required property var modelData

                        width: parent.width
                        entry: modelData
                        rowHeight: menu.rowHeight
                        separatorHeight: menu.separatorHeight
                        onTriggered: menu.trigger(modelData.action)
                    }
                }
            }
        }
    }
}
