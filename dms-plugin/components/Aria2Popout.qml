import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "../lib/Fmt.js" as Fmt

PopoutComponent {
    id: popout

    //: The edge menus have to stay inside: the bar popout clips anything
    //: drawn past its body (see MenuPopup).
    objectName: "aria2MenuBounds"

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
    readonly property int chromeHeight: header.height + (inWindow ? 0 : 12) + statStrip.height + (statStrip.visible ? 12 : 0)
                                        + tabBar.height
                                        + (aria2Banner.shown ? aria2Banner.height + 12 : 0)
                                        + (tabBar.visible ? 12 : 0)

    Connections {
        target: popout.service
        function onRequestedTabChanged() {
            popout.tabIndex = popout.service.requestedTab
        }
    }

    readonly property bool online: service && service.connected

    //: The first moments of a session: nothing has answered yet, and nothing
    //: has failed either. The list area shows skeleton rows rather than the
    //: offline screen, but only after 300 ms, so a fast connect never
    //: flashes them.
    //: No manager and not still trying for the first time: the offline
    //: panel stands alone, without a speed strip or tabs that would all be
    //: empty (board 10).
    readonly property bool bare: !online && !connecting
    readonly property bool connecting: !!service && !service.connected && service.snapshot === null && service.lastError === ""
    property bool skeletonDue: false

    onConnectingChanged: {
        if (connecting) {
            skeletonDelay.restart()
        } else {
            skeletonDelay.stop()
            skeletonDue = false
        }
    }

    Timer {
        id: skeletonDelay

        interval: 300
        running: popout.connecting
        onTriggered: popout.skeletonDue = true
    }

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

    //: DMS's own header is a 20 px title over a 14 px line; the board's is a
    //: compact 16 px title with the state under it and round 36 px actions,
    //: so the popout draws its own and leaves those empty.
    readonly property string statusLine: {
        if (!service)
            return ""
        if (connecting)
            return "Connecting…"
        if (service.restarting === "manager")
            return "Restarting the manager…"
        if (!service.connected)
            return "Offline"
        const aria2 = service.aria2
        if (!aria2.running)
            return "aria2c stopped"
        return (service.activeCount > 0 ? "Downloading · " : "Ready · ") + "aria2c " + (aria2.version || "")
    }

    headerText: ""
    detailsText: ""

    Item {
        id: header

        x: popout.inset
        width: parent.width - popout.inset * 2
        height: inWindow ? 0 : 44
        visible: !popout.inWindow

        Column {
            anchors.left: parent.left
            anchors.leftMargin: 6
            anchors.right: headerButtons.left
            anchors.rightMargin: Theme.spacingS
            anchors.verticalCenter: parent.verticalCenter
            spacing: 0

            StyledText {
                width: parent.width
                text: "Aria Download Manager"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.DemiBold
                color: Theme.surfaceText
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                text: popout.statusLine
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }
        }

        Row {
            id: headerButtons

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            ManagerActions {
                anchors.verticalCenter: parent.verticalCenter
                service: popout.service
                onDetachRequested: popout.detachRequested()
                onDismissRequested: {
                    if (popout.closePopout)
                        popout.closePopout()
                }
            }

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 36
                iconSize: 20
                iconName: "close"
                iconColor: Theme.surfaceText
                tooltipText: "Close"
                onClicked: {
                    if (popout.closePopout)
                        popout.closePopout()
                }
            }
        }
    }

    Item {
        width: parent.width
        height: popout.inWindow ? 0 : 12
    }

    // ---- live stat strip -------------------------------------------------
    //: Speed is the headline, with the last minute behind it as a sparkline
    //: of a fixed size; upload beside it and what is left at the far end.
    Rectangle {
        id: statStrip

        readonly property var totals: popout.service ? popout.service.activeTotals : ({})

        x: popout.inset
        width: parent.width - popout.inset * 2
        //: With aria2c down there is nothing moving to measure (board 10).
        height: aria2Banner.shown || popout.bare ? 0 : 72
        visible: height > 0
        radius: 16
        color: Theme.surfaceContainerHigh

        Row {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 20

            Column {
                width: Math.max(150, downValue.implicitWidth)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    text: "Download"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    id: downValue

                    text: popout.service ? Fmt.speed(popout.service.downloadSpeed) : "–"
                    font.pixelSize: Theme.fontSizeLarge + 8
                    font.weight: Font.DemiBold
                    color: Theme.primary
                }
            }

            Canvas {
                id: sparkline

                readonly property var samples: popout.service ? popout.service.speedHistory : []
                property color tint: Theme.primary

                anchors.verticalCenter: parent.verticalCenter
                width: statStrip.width >= 560 ? 170 : 0
                height: 40
                visible: width > 0

                onSamplesChanged: requestPaint()
                onTintChanged: requestPaint()
                onWidthChanged: requestPaint()

                onPaint: {
                    const ctx = getContext("2d")
                    ctx.reset()
                    if (samples.length < 1)
                        return
                    // Until a minute has been seen, the line starts flat at
                    // the first value rather than as a sliver at the end.
                    const values = samples.length < 60 ? Array(60 - samples.length).fill(samples[0]).concat(samples) : samples
                    let peak = 1
                    for (const v of values)
                        peak = Math.max(peak, v)
                    const step = width / 59
                    const x0 = width - (values.length - 1) * step
                    const yOf = v => height - 2 - (height - 6) * (v / peak)
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

            Column {
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2

                StyledText {
                    text: "Upload"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                StyledText {
                    text: popout.service ? Fmt.speed(popout.service.uploadSpeed) : "–"
                    font.pixelSize: Theme.fontSizeSmall + 3
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
            }
        }

        Column {
            anchors.right: parent.right
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            visible: (statStrip.totals.left || 0) > 0
            spacing: 2

            StyledText {
                anchors.right: parent.right
                text: "Left"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.right: parent.right
                text: Fmt.bytes(statStrip.totals.left || 0)
                      + (statStrip.totals.eta >= 0 ? " · " + Fmt.eta(statStrip.totals.eta) : "")
                font.pixelSize: Theme.fontSizeSmall + 3
                font.weight: Font.DemiBold
                color: Theme.surfaceText
            }
        }
    }

    Item {
        width: parent.width
        height: statStrip.visible ? 12 : 0
    }

    // ---- aria2c is down ----------------------------------------------------
    //: The error itself and the fix, above the tabs; the list below stays as
    //: it was, since downloads pick up again once aria2c is back.
    Rectangle {
        id: aria2Banner

        readonly property bool shown: popout.online && !popout.service.aria2Running

        x: popout.inset
        width: parent.width - popout.inset * 2
        height: shown ? bannerColumn.implicitHeight + 28 : 0
        visible: shown
        radius: 16
        color: Theme.withAlpha(Theme.error, 0.06)
        border.width: 1
        border.color: Theme.withAlpha(Theme.error, 0.45)

        Column {
            id: bannerColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 14
            spacing: 8

            Row {
                spacing: 8

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "error"
                    size: 18
                    color: Theme.error
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "aria2c exited"
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.DemiBold
                    color: Theme.surfaceText
                }
            }

            //: aria2's own words, as it wrote them.
            StyledText {
                width: parent.width
                text: popout.service ? String(popout.service.aria2.last_error || "").replace(/\u001b\[[0-9;]*m/g, "").trim() : ""
                visible: text !== ""
                font.pixelSize: Theme.fontSizeSmall
                font.family: "monospace"
                color: Theme.surfaceText
                maximumLineCount: 3
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                visible: !popout.service || !popout.service.aria2.last_error
                text: "Downloads resume where they were once it is back."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Row {
                topPadding: 2
                spacing: 4

                PillButton {
                    size: 34
                    kind: "filled"
                    text: popout.service && popout.service.restarting === "aria2c" ? "Restarting…" : "Restart aria2c"
                    busy: !!popout.service && popout.service.restarting === "aria2c"
                    enabled: !!popout.service && popout.service.restarting === ""
                    onClicked: popout.service.restartAria2()
                }

                PillButton {
                    size: 34
                    kind: "text"
                    text: "Open log"
                    onClicked: {
                        popout.service.requestedLog = true
                        popout.service.requestedTab = popout.service.settingsTabIndex
                        popout.tabIndex = popout.service.settingsTabIndex
                    }
                }
            }
        }
    }

    Item {
        width: parent.width
        height: aria2Banner.shown ? 12 : 0
    }

    // ---- the last minute before shutting down or suspending ------------------
    AfterAllBanner {
        x: popout.inset
        width: parent.width - popout.inset * 2
        service: popout.service
    }

    Item {
        width: parent.width
        height: !!popout.service && !!popout.service.afterAll.deadline ? 12 : 0
    }

    //: The three tabs as one compact segmented strip: what DankTabBar drew in
    //: 52 px plus an underline that spilled below it now fits in 44.
    Rectangle {
        id: tabBar

        //: How many actions are on ("3"), or "off" beside Actions: the master
        //: switch and how much it governs, readable from any tab.
        readonly property string actionsBadge: {
            if (!popout.service || !popout.online)
                return ""
            if (!popout.service.rulesEnabled)
                return "off"
            const on = popout.service.rules.filter(r => r.enabled !== false).length
            return on > 0 ? String(on) : ""
        }
        readonly property var tabs: [
            {
                "text": "Downloads",
                "icon": "download",
                "badge": ""
            },
            {
                "text": "Actions",
                "icon": "auto_fix_high",
                "badge": actionsBadge
            },
            {
                "text": "Settings",
                "icon": "tune",
                "badge": ""
            }
        ]

        x: popout.inset
        width: parent.width - popout.inset * 2
        height: popout.bare ? 0 : 44
        visible: height > 0
        radius: 14
        color: Theme.surfaceContainerHigh

        Row {
            anchors.fill: parent
            anchors.margins: 4
            spacing: 4

            Repeater {
                model: tabBar.tabs

                Rectangle {
                    id: tab

                    required property var modelData
                    required property int index

                    readonly property bool selected: popout.tabIndex === index

                    width: (parent.width - 8) / 3
                    height: parent.height
                    radius: 10
                    color: selected ? Theme.primaryContainer
                                    : (tabArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent")

                    Row {
                        anchors.centerIn: parent
                        spacing: 6

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: tab.modelData.icon
                            size: 18
                            color: tab.selected ? Theme.onPrimaryContainer : Theme.surfaceVariantText
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: tab.modelData.text
                            font.pixelSize: Theme.fontSizeSmall + 1
                            font.weight: tab.selected ? Font.DemiBold : Font.Medium
                            color: tab.selected ? Theme.onPrimaryContainer : Theme.surfaceVariantText
                        }

                        Rectangle {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: tab.modelData.badge !== ""
                            width: badgeText.implicitWidth + 12
                            height: 18
                            radius: 9
                            color: tab.selected ? Theme.withAlpha(Theme.onPrimaryContainer, 0.14) : Theme.surfaceContainerHighest

                            StyledText {
                                id: badgeText

                                anchors.centerIn: parent
                                text: tab.modelData.badge
                                font.pixelSize: Theme.fontSizeSmall - 1
                                color: tab.selected ? Theme.onPrimaryContainer : Theme.surfaceVariantText
                            }
                        }
                    }

                    MouseArea {
                        id: tabArea

                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: popout.tabIndex = tab.index
                    }
                }
            }
        }
    }

    Item {
        width: parent.width
        height: tabBar.visible ? 12 : 0
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
        // ---- still connecting ---------------------------------------------
        //: Rows shaped like the real ones, so nothing jumps when data lands.
        Column {
            anchors.fill: parent
            anchors.leftMargin: popout.inset
            anchors.rightMargin: popout.inset
            visible: popout.connecting && popout.skeletonDue
            spacing: Theme.spacingS

            Repeater {
                model: 3

                Rectangle {
                    width: parent.width
                    height: 64
                    radius: Theme.cornerRadius
                    color: Theme.surfaceContainer

                    SequentialAnimation on opacity {
                        running: popout.connecting && popout.skeletonDue
                        loops: Animation.Infinite
                        NumberAnimation {
                            from: 1
                            to: 0.55
                            duration: 700
                        }
                        NumberAnimation {
                            from: 0.55
                            to: 1
                            duration: 700
                        }
                    }

                    Rectangle {
                        id: skTile

                        x: Theme.spacingM
                        anchors.verticalCenter: parent.verticalCenter
                        width: 36
                        height: 36
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainerHighest
                    }

                    Column {
                        anchors.left: skTile.right
                        anchors.leftMargin: Theme.spacingM
                        anchors.right: parent.right
                        anchors.rightMargin: Theme.spacingXL * 3
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 7

                        Rectangle {
                            width: parent.width * 0.6
                            height: 10
                            radius: 5
                            color: Theme.surfaceContainerHighest
                        }

                        Rectangle {
                            width: parent.width
                            height: 4
                            radius: 2
                            color: Theme.surfaceContainerHighest
                        }

                        Rectangle {
                            width: parent.width * 0.35
                            height: 8
                            radius: 4
                            color: Theme.surfaceContainerHighest
                        }
                    }
                }
            }
        }

        // ---- the manager is restarting ------------------------------------
        //: Not the offline screen: this was asked for, and it comes back.
        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacingXL * 2, 420)
            visible: !popout.online && !!popout.service && popout.service.restarting === "manager"
            spacing: Theme.spacingS

            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: "progress_activity"
                size: 32
                color: Theme.primary

                RotationAnimation on rotation {
                    running: parent.visible
                    loops: Animation.Infinite
                    from: 0
                    to: 360
                    duration: 1000
                }
            }

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Restarting the manager…"
                font.pixelSize: Theme.fontSizeLarge
                font.weight: Font.DemiBold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: "The panel reconnects by itself. Downloads in aria2c keep going."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }
        }

        Column {
            anchors.centerIn: parent
            width: Math.min(parent.width - Theme.spacingXL * 2, 420)
            visible: !popout.online && !popout.connecting && !(popout.service && popout.service.restarting === "manager")
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
                font.weight: Font.DemiBold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: "Nothing answered on"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Rectangle {
                width: parent.width
                height: 40
                radius: 12
                color: Theme.surfaceContainerHigh

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 12
                    anchors.right: copySocket.left
                    anchors.rightMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    text: popout.service ? popout.service.socketPath : ""
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: "monospace"
                    color: Theme.surfaceText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle
                }

                DankActionButton {
                    id: copySocket

                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 30
                    iconSize: 16
                    iconName: "content_copy"
                    iconColor: Theme.surfaceVariantText
                    tooltipText: "Copy the socket path"
                    onClicked: {
                        Quickshell.execDetached(["dms", "cl", "copy", popout.service.socketPath])
                        popout.service.notice("Copied")
                    }
                }
            }

            //: The exact commands, in monospace.
            StyledText {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                textFormat: Text.RichText
                text: "Start it with <span style=\"font-family:monospace\">./run.sh</span> or <span style=\"font-family:monospace\">systemctl --user start aria-download-manager</span>."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceText
            }

            Row {
                anchors.horizontalCenter: parent.horizontalCenter
                spacing: 8
                topPadding: 4

                PillButton {
                    kind: "filled"
                    text: "Retry now"
                    onClicked: {
                        popout.service.restart()
                        popout.service.refreshSnapshot()
                    }
                }

                //: A wrong socket path is the other common cause, and it is
                //: set there.
                PillButton {
                    kind: "outlined"
                    text: "Plugin settings"
                    onClicked: {
                        Quickshell.execDetached(["dms", "ipc", "call", "settings", "openWith", "plugin:ariaDownloadManager"])
                        if (popout.closePopout)
                            popout.closePopout()
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
            //: The list stays while aria2c is down, but reads as on hold.
            opacity: aria2Banner.shown && popout.tabIndex === 0 ? 0.55 : 1
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
