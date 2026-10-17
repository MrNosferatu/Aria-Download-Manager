import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "./components"
import "./lib/Fmt.js" as Fmt

PluginComponent {
    id: root

    layerNamespacePlugin: "aria-download-manager"

    property var popoutService: null

    readonly property var svc: Aria2Service
    readonly property string pillMode: pluginData.pillMode || "speed"
    readonly property int popoutHeightSetting: parseInt(pluginData.popoutHeight || "540") || 540

    //: "popout" keeps the bar-anchored panel on left click; "window" makes the
    //: standalone window the default and leaves the popout to hover.
    readonly property bool clickOpensWindow: pluginData.clickOpens === "window"

    //: Only a bar-hosted instance may own the window, and only one of them —
    //: see Aria2Service.claimWindow.
    property bool ownsWindow: false

    //: Lifted for the length of one openPopout() call. Without it, docking the
    //: window back into the bar would run through pillClickAction and reopen
    //: the very window we just closed.
    property bool _forcePopout: false

    readonly property bool showRing: pluginData.showProgressRing !== false

    readonly property bool online: svc.connected
    readonly property bool busy: online && svc.activeCount > 0
    readonly property bool attention: online && !svc.aria2Running
    //: Held work and no running work: paused or waiting downloads only. Gets
    //: its own glyph so it never passes for idle.
    readonly property bool held: online && !attention && !busy && svc.waitingCount > 0

    readonly property string barIcon: {
        if (!online)
            return "cloud_off"
        if (attention)
            return "error"
        // Running and idle keep the download glyph: the widget has to read as a
        // downloader at a glance, and a tick mark reads as a checklist.
        if (busy)
            return "downloading"
        if (held)
            return svc.pausedCount > 0 ? "pause_circle" : "schedule"
        return "download"
    }

    readonly property color barColor: {
        if (!online)
            return Theme.surfaceVariantText
        if (attention)
            return Theme.error
        if (busy)
            return Theme.primary
        if (held)
            return Theme.surfaceVariantText
        return Theme.surfaceText
    }

    //: Overall progress of the running downloads for the ring, or -1 to leave
    //: it off (nothing running, sizes unknown, or turned off in settings).
    readonly property real ringProgress: showRing && busy ? svc.activeTotals.progress : -1

    readonly property bool unseenBadge: online && !busy && svc.unseenFinished > 0

    readonly property string heldText: svc.pausedCount > 0
                                       ? svc.pausedCount + " paused"
                                       : svc.queuedCount + " queued"

    //: Words appear only when something needs saying: offline and idle are
    //: icon-only, aria2c being down says so outright.
    readonly property string pillText: {
        if (!online)
            return ""
        if (attention)
            return "aria2c down"
        if (pillMode === "none")
            return ""
        if (held)
            return heldText
        if (!busy)
            return ""
        if (pillMode === "count")
            return String(svc.activeCount)
        return Fmt.speed(svc.downloadSpeed)
    }

    //: Count mode's second number: what is waiting behind the running ones.
    readonly property string pillExtra: pillMode === "count" && busy && svc.waitingCount > 0
                                        ? "+" + svc.waitingCount : ""

    //: Speed changes every tick; reserving the widest it can get keeps the
    //: pill from shoving its neighbours along the bar each second.
    readonly property bool steadyLabel: busy && pillMode === "speed"

    popoutWidth: parseInt(pluginData.popoutWidth || "640") || 640

    //: Claiming from Component.onCompleted would risk shadowing the base
    //: PluginComponent's own handler, so the claim runs a tick later — and
    //: again if this instance is handed an axis after the fact.
    function tryClaimWindow() {
        if (!root.ownsWindow && root.axis)
            root.ownsWindow = root.svc.claimWindow(root)
    }

    onAxisChanged: tryClaimWindow()

    Timer {
        interval: 0
        running: true
        onTriggered: root.tryClaimWindow()
    }

    Component.onDestruction: root.svc.releaseWindow(root)

    Connections {
        target: root.svc
        function onPopoutToggleRequested() {
            // Only a bar-hosted instance owns a popout. DMS also builds
            // throwaway instances to probe for a control-center widget, and
            // those must not answer the broadcast.
            if (root.axis)
                root.triggerPopout()
        }
        function onWindowToggleRequested(forceShow) {
            if (!root.ownsWindow)
                return
            if (forceShow)
                root.showWindow()
            else
                root.toggleWindow()
        }
    }

    // ---- standalone window ----------------------------------------------
    //: Built on first use, so a bar that never detaches never pays for one.
    function showWindow() {
        if (!root.ownsWindow) {
            // Another bar holds the window — ask whoever that is.
            root.svc.windowToggleRequested(true)
            return
        }
        windowLoader.active = true
        windowLoader.item.show()
    }

    function toggleWindow() {
        if (!root.ownsWindow) {
            root.svc.windowToggleRequested(false)
            return
        }
        windowLoader.active = true
        windowLoader.item.toggle()
    }

    LazyLoader {
        id: windowLoader

        active: false

        Aria2Window {
            service: root.svc
            onDockRequested: root.openPopout()
        }
    }

    // ---- right-click quick actions ---------------------------------------
    QuickMenu {
        id: quickMenu

        service: root.svc
        onWindowRequested: root.showWindow()
        onPopoutRequested: root.openPopout()
    }

    pillRightClickAction: (x, y, width, section, screen) => {
        const barPosition = root.axis?.edge === "left" ? 2 : (root.axis?.edge === "right" ? 3 : (root.axis?.edge === "top" ? 0 : 1))
        quickMenu.setTriggerPosition(x, y, width, section, screen, barPosition, root.barThickness, root.barSpacing, root.barConfig)
        quickMenu.toggle()
    }

    //: With "window" picked, the pill opens the real window instead of the
    //: bar-anchored popout. A bar that lost the window claim keeps the popout.
    pillClickAction: (root.clickOpensWindow && root.ownsWindow && !root._forcePopout) ? (() => root.toggleWindow()) : null

    //: The bar popout, whatever the pill is currently wired to do.
    function openPopout() {
        root._forcePopout = true
        root.triggerPopout()
        root._forcePopout = false
    }

    // ---- control center --------------------------------------------------
    ccWidgetIcon: barIcon
    ccWidgetPrimaryText: "Downloads"
    ccWidgetSecondaryText: {
        if (!online)
            return "Manager offline"
        if (attention)
            return "aria2c stopped"
        if (busy) {
            const progress = svc.activeTotals.progress
            return svc.activeCount + " active · " + Fmt.speed(svc.downloadSpeed)
                    + (progress >= 0 ? " · " + Math.floor(progress * 100) + "%" : "")
        }
        if (held)
            return heldText
        if (svc.unseenFinished > 0)
            return svc.unseenFinished + " finished"
        return "Idle"
    }
    ccWidgetIsActive: busy
    ccWidgetIsToggle: false

    onCcWidgetToggled: root.triggerPopout()

    // ---- bar pills -------------------------------------------------------
    horizontalBarPill: Component {
        Row {
            id: pillRow

            spacing: Theme.spacingXS

            BarGlyph {
                anchors.verticalCenter: parent.verticalCenter
                iconName: root.barIcon
                tint: root.barColor
                size: root.iconSize
                progress: root.ringProgress
                badge: root.unseenBadge
                dim: !root.online
            }

            StyledText {
                id: pillLabel

                anchors.verticalCenter: parent.verticalCenter
                text: root.pillText
                visible: text.length > 0
                width: root.steadyLabel ? Math.max(implicitWidth, widest.width) : implicitWidth
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.barColor

                TextMetrics {
                    id: widest

                    font: pillLabel.font
                    // Fmt.speed never gets wider than four digits and a binary unit.
                    text: "0000 KiB/s"
                }
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.pillExtra
                visible: text.length > 0
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: Theme.surfaceVariantText
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            //: The vertical bar has room for a short figure only: the speed
            //: split onto two lines, or a count. Idle and offline show nothing.
            readonly property var parts: {
                if (root.attention || root.pillMode === "none")
                    return []
                if (root.held)
                    return [String(root.svc.waitingCount)]
                if (!root.busy)
                    return []
                if (root.pillMode === "count")
                    return [String(root.svc.activeCount)]
                return Fmt.speed(root.svc.downloadSpeed).split(" ")
            }

            BarGlyph {
                anchors.horizontalCenter: parent.horizontalCenter
                iconName: root.barIcon
                tint: root.barColor
                size: root.iconSize
                progress: root.ringProgress
                badge: root.unseenBadge
                dim: !root.online
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: parent.parts.length > 0 ? parent.parts[0] : ""
                visible: text.length > 0
                font.pixelSize: Theme.fontSizeSmall - 1
                font.weight: Font.Medium
                color: root.barColor
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: parent.parts.length > 1 ? parent.parts[1] : ""
                visible: text.length > 0
                font.pixelSize: Theme.fontSizeSmall - 3
                color: Theme.surfaceVariantText
            }
        }
    }

    // ---- popout ----------------------------------------------------------
    popoutContent: Component {
        Aria2Popout {
            width: root.popoutWidth - Theme.spacingS * 2
            service: root.svc
            contentHeight: root.popoutHeightSetting
            onDetachRequested: root.showWindow()
        }
    }
}
