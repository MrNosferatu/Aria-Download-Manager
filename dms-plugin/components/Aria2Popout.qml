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

    //: Set when this instance lives in the detached window instead of the bar
    //: popout. The window owns the title bar and the header actions, so the
    //: popout's own header steps aside and only the status line stays.
    property bool inWindow: false

    //: The popout learns whether it is on screen from its parent popout; the
    //: window has no parentPopout and drives this from its own visibility.
    property bool hostVisible: true

    signal detachRequested

    //: Everything above the tab content, so a host that owns its height (the
    //: window) can work out how much is left for the tabs. Spelled out term by
    //: term rather than derived from implicitHeight, which would bind back
    //: through contentHeight.
    readonly property int chromeHeight: headerHeight + detailsHeight + statStrip.height
                                        + Theme.spacingS + tabBar.height
                                        + (aria2Banner.shown ? aria2Banner.height + Theme.spacingS : 0)
                                        + Theme.spacingL + Theme.spacingXS

    Connections {
        target: popout.service
        function onRequestedTabChanged() {
            popout.tabIndex = popout.service.requestedTab
        }
    }

    readonly property bool online: service && service.connected

    // While this popout is on screen it pings the service, which streams for as
    // long as the pings keep coming. Closing simply stops the pings.
    readonly property bool showing: parentPopout ? parentPopout.shouldBeVisible : hostVisible

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

    headerText: inWindow ? "" : "Aria Download Manager"
    detailsText: {
        if (!service)
            return ""
        if (!service.connected)
            return "Manager offline · " + service.socketPath
        const aria2 = service.aria2
        if (!aria2.running)
            return "aria2c is not running · " + (aria2.last_error || "see the event log under Settings")
        return (service.activeCount > 0 ? "Downloading · " : "Ready · ") + "aria2c " + (aria2.version || "")
    }
    showCloseButton: !inWindow

    headerActions: Component {
        ManagerActions {
            service: popout.service
            onDetachRequested: popout.detachRequested()
            onDismissRequested: {
                if (popout.closePopout)
                    popout.closePopout()
            }
        }
    }

    // ---- live stat strip -------------------------------------------------
    //: Speed is the headline, with the last minute behind it as a sparkline.
    //: The per-state counts live on the Downloads filter chips; the Actions
    //: switch lives on the Actions tab.
    Rectangle {
        id: statStrip

        readonly property var totals: popout.service ? popout.service.activeTotals : ({})

        x: popout.inset
        width: parent.width - popout.inset * 2
        height: 56
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Column {
            id: downCell

            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            StyledText {
                text: "Download"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                text: popout.service ? Fmt.speed(popout.service.downloadSpeed) : "–"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.primary
            }
        }

        Canvas {
            id: sparkline

            readonly property var samples: popout.service ? popout.service.speedHistory : []
            property color tint: Theme.primary

            anchors.left: downCell.right
            anchors.leftMargin: Theme.spacingL
            anchors.right: rightCells.left
            anchors.rightMargin: Theme.spacingL
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            anchors.topMargin: Theme.spacingS
            anchors.bottomMargin: Theme.spacingS
            visible: width > 40

            onSamplesChanged: requestPaint()
            onTintChanged: requestPaint()
            onWidthChanged: requestPaint()

            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const values = samples
                if (values.length < 2)
                    return
                let peak = 1
                for (const v of values)
                    peak = Math.max(peak, v)
                const step = width / 59
                const x0 = width - (values.length - 1) * step
                const yOf = v => height - 2 - (height - 4) * (v / peak)
                ctx.beginPath()
                ctx.moveTo(x0, height)
                for (let i = 0; i < values.length; i++)
                    ctx.lineTo(x0 + i * step, yOf(values[i]))
                ctx.lineTo(width, height)
                ctx.closePath()
                ctx.fillStyle = Theme.withAlpha(tint, 0.16)
                ctx.fill()
                ctx.beginPath()
                for (let i = 0; i < values.length; i++) {
                    if (i === 0)
                        ctx.moveTo(x0, yOf(values[i]))
                    else
                        ctx.lineTo(x0 + i * step, yOf(values[i]))
                }
                ctx.lineWidth = 2
                ctx.lineJoin = "round"
                ctx.strokeStyle = tint
                ctx.stroke()
            }
        }

        Row {
            id: rightCells

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingL

            Column {
                spacing: 0

                StyledText {
                    text: "Upload"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    text: popout.service ? Fmt.speed(popout.service.uploadSpeed) : "–"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }
            }

            Column {
                spacing: 0
                visible: (statStrip.totals.left || 0) > 0

                StyledText {
                    text: "Left"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    text: Fmt.bytes(statStrip.totals.left || 0)
                          + (statStrip.totals.eta >= 0 ? " · " + Fmt.eta(statStrip.totals.eta) : "")
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }
            }
        }
    }

    Item {
        width: parent.width
        height: Theme.spacingS
    }

    // ---- aria2c is down ----------------------------------------------------
    //: The error itself and the fix, above the tabs; the list below stays as
    //: it was, since downloads pick up again once aria2c is back.
    Rectangle {
        id: aria2Banner

        readonly property bool shown: popout.online && !popout.service.aria2Running

        x: popout.inset
        width: parent.width - popout.inset * 2
        height: shown ? 64 : 0
        visible: shown
        radius: Theme.cornerRadius
        color: Theme.withAlpha(Theme.error, 0.10)
        border.width: 1
        border.color: Theme.withAlpha(Theme.error, 0.35)

        DankIcon {
            id: bannerIcon

            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            name: "error"
            size: 22
            color: Theme.error
        }

        Column {
            anchors.left: bannerIcon.right
            anchors.leftMargin: Theme.spacingS
            anchors.right: bannerButtons.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            StyledText {
                text: "aria2c stopped"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                text: popout.service ? (popout.service.aria2.last_error || "Downloads resume where they were once it is back.") : ""
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                elide: Text.ElideRight
            }
        }

        Row {
            id: bannerButtons

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingXS

            DankButton {
                text: "Open log"
                buttonHeight: 34
                backgroundColor: "transparent"
                textColor: Theme.surfaceText
                onClicked: {
                    popout.service.requestedLog = true
                    popout.service.requestedTab = popout.service.settingsTabIndex
                    popout.tabIndex = popout.service.settingsTabIndex
                }
            }

            DankButton {
                text: "Restart aria2c"
                iconName: "restart_alt"
                buttonHeight: 34
                backgroundColor: Theme.primary
                textColor: Theme.onPrimary
                onClicked: popout.service.post("/api/aria2/restart", null, "aria2c restarted")
            }
        }
    }

    Item {
        width: parent.width
        height: aria2Banner.shown ? Theme.spacingS : 0
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
                "text": popout.service && popout.online && !popout.service.rulesEnabled ? "Actions · off" : "Actions",
                "icon": "auto_fix_high"
            },
            {
                "text": "Settings",
                "icon": "tune"
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

        //: Sits over the bottom of whichever tab is showing; see Feedback.qml.
        Feedback {
            service: popout.service
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: Theme.spacingM
            z: 10
        }

        // ---- the manager is not there -----------------------------------
        //: Every tab would be empty, so none is shown: what was tried, the
        //: path to check, and a way to try again.
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacingXL * 2, 420)
            visible: !popout.online
            spacing: Theme.spacingS

            Rectangle {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 64
                height: 64
                radius: 32
                color: Theme.surfaceContainerHigh

                DankIcon {
                    anchors.centerIn: parent
                    name: "cloud_off"
                    size: 32
                    color: Theme.surfaceVariantText
                }
            }

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "The manager isn't running"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Nothing answered on the socket below. Start it with ./run.sh or its systemd user unit, then try again."
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Rectangle {
                width: parent.width
                height: 36
                radius: Theme.cornerRadius
                color: Theme.surfaceContainerHigh

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: Theme.spacingM
                    anchors.right: copySocket.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: popout.service ? popout.service.socketPath : ""
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceText
                    elide: Text.ElideMiddle
                }

                DankActionButton {
                    id: copySocket

                    anchors.right: parent.right
                    anchors.rightMargin: Theme.spacingXS
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 28
                    iconSize: Theme.iconSizeSmall
                    iconName: "content_copy"
                    tooltipText: "Copy the socket path"
                    onClicked: {
                        Quickshell.execDetached(["dms", "cl", "copy", popout.service.socketPath])
                        popout.service.notice("Copied")
                    }
                }
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: Theme.spacingS
                topPadding: Theme.spacingS

                DankButton {
                    text: "Retry now"
                    iconName: "refresh"
                    buttonHeight: 36
                    backgroundColor: Theme.primary
                    textColor: Theme.onPrimary
                    onClicked: {
                        popout.service.restart()
                        popout.service.refreshSnapshot()
                    }
                }
            }

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Reconnects on its own as soon as the manager answers."
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
        }

        Loader {
            anchors.fill: parent
            anchors.leftMargin: popout.inset
            anchors.rightMargin: popout.inset
            visible: popout.online
            sourceComponent: {
                switch (popout.tabIndex) {
                case 0:
                    return downloadsTab
                case 1:
                    return rulesTab
                default:
                    return settingsTab
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

}
