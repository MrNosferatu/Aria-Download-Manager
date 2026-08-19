import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "../lib/Fmt.js" as Fmt

PopoutComponent {
    id: popout

    property var service: null
    property int contentHeight: 540
    readonly property int inset: Theme.spacingS
    property int tabIndex: service ? service.requestedTab : 0

    Connections {
        target: popout.service
        function onRequestedTabChanged() {
            popout.tabIndex = popout.service.requestedTab
        }
    }

    readonly property bool online: service && service.connected

    // While this popout is on screen it pings the service, which streams for as
    // long as the pings keep coming. Closing simply stops the pings.
    readonly property bool showing: parentPopout ? parentPopout.shouldBeVisible : true

    onShowingChanged: {
        if (showing && service)
            service.viewerPing()
    }

    Component.onCompleted: {
        if (showing && service)
            service.viewerPing()
    }

    Timer {
        interval: 1000
        repeat: true
        running: popout.showing
        triggeredOnStart: true
        onTriggered: {
            if (popout.service)
                popout.service.viewerPing()
        }
    }

    headerText: "aria2c manager"
    detailsText: {
        if (!service)
            return ""
        if (!service.connected)
            return "manager offline — " + service.baseUrl
        const aria2 = service.aria2
        if (!aria2.running)
            return "aria2c not running — " + (aria2.last_error || "see the Log tab")
        return "aria2c " + (aria2.version || "") + " · pid " + (aria2.pid !== undefined && aria2.pid !== null ? aria2.pid : "ext")
    }
    showCloseButton: true

    headerActions: Component {
        Row {
            spacing: Theme.spacingXS

            DankActionButton {
                iconName: "pause"
                tooltipText: "Pause all"
                buttonSize: 30
                onClicked: popout.service.post("/api/global/pause-all", null, "Paused all")
            }

            DankActionButton {
                iconName: "play_arrow"
                tooltipText: "Resume all"
                buttonSize: 30
                onClicked: popout.service.post("/api/global/resume-all", null, "Resumed all")
            }

            DankActionButton {
                iconName: "cleaning_services"
                tooltipText: "Purge finished results from the list"
                buttonSize: 30
                onClicked: popout.service.post("/api/global/purge", null, "Purged finished results")
            }

            DankActionButton {
                iconName: "open_in_browser"
                tooltipText: "Open the web UI"
                buttonSize: 30
                onClicked: {
                    Quickshell.execDetached(["xdg-open", popout.service.baseUrl + "/"])
                    if (popout.closePopout)
                        popout.closePopout()
                }
            }
        }
    }

    // ---- live stat strip -------------------------------------------------
    Rectangle {
        x: popout.inset
        width: parent.width - popout.inset * 2
        height: 46
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Row {
            // Bounded by the rules switch on the right: without this the stats
            // run underneath it once the popout is narrowed.
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.right: rulesSwitch.left
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingL
            clip: true

            Repeater {
                model: [
                    {
                        "label": "Down",
                        "value": popout.service ? Fmt.speed(popout.service.downloadSpeed) : "–",
                        "accent": true
                    },
                    {
                        "label": "Up",
                        "value": popout.service ? Fmt.speed(popout.service.uploadSpeed) : "–",
                        "accent": false
                    },
                    {
                        "label": "Active",
                        "value": popout.service ? String(popout.service.activeCount) : "0",
                        "accent": false
                    },
                    {
                        "label": "Queued",
                        "value": popout.service ? String(popout.service.waitingCount) : "0",
                        "accent": false
                    },
                    {
                        "label": "Stopped",
                        "value": popout.service ? String(popout.service.stoppedCount) : "0",
                        "accent": false
                    }
                ]

                Column {
                    id: statCell

                    required property var modelData

                    spacing: 0

                    StyledText {
                        text: statCell.modelData.label
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        text: statCell.modelData.value
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: statCell.modelData.accent ? Theme.primary : Theme.surfaceText
                    }
                }
            }
        }

        Row {
            id: rulesSwitch

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Rules"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankToggle {
                anchors.verticalCenter: parent.verticalCenter
                checked: popout.service ? popout.service.rulesEnabled : false
                hideText: true
                onToggled: checked => popout.service.setRulesEnabled(checked)
            }
        }
    }

    Item {
        width: parent.width
        height: Theme.spacingS
    }

    DankTabBar {
        id: tabBar

        width: parent.width
        tabHeight: 52
        equalWidthTabs: true
        currentIndex: popout.tabIndex
        model: [
            {
                "text": "Downloads",
                "icon": "download"
            },
            {
                "text": "Settings",
                "icon": "tune"
            },
            {
                "text": "Rules",
                "icon": "bolt"
            },
            {
                "text": "Log",
                "icon": "article"
            }
        ]

        onTabClicked: index => popout.tabIndex = index
    }

    Item {
        // DankTabBar paints its active indicator and divider below its own
        // height (y = height + 7 and + 10), so the content has to start clear
        // of them or the first row sits on top of the underline.
        width: parent.width
        height: Theme.spacingL + Theme.spacingXS
    }

    Item {
        id: contentArea

        width: parent.width
        height: popout.contentHeight

        Loader {
            anchors.fill: parent
            anchors.leftMargin: popout.inset
            anchors.rightMargin: popout.inset
            sourceComponent: {
                switch (popout.tabIndex) {
                case 0:
                    return downloadsTab
                case 1:
                    return settingsTab
                case 2:
                    return rulesTab
                default:
                    return logTab
                }
            }
        }
    }

    Component {
        id: downloadsTab
        DownloadsTab {
            service: popout.service
        }
    }

    Component {
        id: settingsTab
        SettingsTab {
            service: popout.service
        }
    }

    Component {
        id: rulesTab
        RulesTab {
            service: popout.service
        }
    }

    Component {
        id: logTab
        LogTab {
            service: popout.service
        }
    }
}
