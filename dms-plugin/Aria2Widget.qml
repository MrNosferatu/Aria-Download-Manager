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
    readonly property bool showWhenIdle: pluginData.showWhenIdle !== false
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

    readonly property bool busy: svc.activeCount > 0
    readonly property bool attention: svc.connected && !svc.aria2Running
    readonly property int errorCount: svc.counts.error || 0
    readonly property int queuedCount: svc.counts.waiting || 0
    readonly property int pausedCount: svc.counts.paused || 0

    //: Fraction done across everything downloading, or -1 when no running
    //: download knows its size yet. Seeders are left out: they are finished
    //: and would pin the bar at full.
    readonly property real overallProgress: {
        let done = 0
        let total = 0
        for (const d of svc.downloads) {
            if (d.status !== "active" || d.seeder || d.isMetadata)
                continue
            const size = Number(d.total) || 0
            if (size <= 0)
                continue
            total += size
            done += Math.min(size, Number(d.completed) || 0)
        }
        return total > 0 ? done / total : -1
    }

    readonly property string barIcon: {
        if (!svc.connected)
            return "cloud_off"
        if (attention)
            return "error"
        // Both states keep the download glyph: the widget has to read as a
        // downloader at a glance, and a tick mark reads as a checklist.
        if (busy)
            return "downloading"
        return "download"
    }

    //: Follows the bar's own widget colours when there is nothing to say, so
    //: an idle pill sits with its neighbours instead of standing out.
    readonly property color barColor: {
        if (!svc.connected)
            return Theme.widgetInactiveIconColor ?? Theme.surfaceVariantText
        if (attention)
            return Theme.error
        if (busy)
            return Theme.primary
        return Theme.widgetIconColor ?? Theme.surfaceText
    }

    readonly property color labelColor: (busy || attention || !svc.connected) ? barColor : (Theme.widgetTextColor ?? Theme.surfaceText)

    readonly property string idleText: queuedCount > 0 ? queuedCount + " queued" : (pausedCount > 0 ? pausedCount + " paused" : "")

    //: True while the label is a speed — the only case that reserves width.
    readonly property bool labelIsSpeed: svc.connected && pillMode === "speed" && busy

    readonly property string pillText: {
        if (pillMode === "none")
            return ""
        if (!svc.connected)
            return "offline"
        if (pillMode === "count")
            return busy ? svc.activeCount + (svc.waitingCount > 0 ? "/" + (svc.activeCount + svc.waitingCount) : "") : idleText
        return busy ? Fmt.speedShort(svc.downloadSpeed) : idleText
    }

    readonly property string verticalText: {
        if (pillMode === "none" || !svc.connected || !busy)
            return ""
        return pillMode === "count" ? String(svc.activeCount) : Fmt.speedShort(svc.downloadSpeed, true)
    }

    //: "Show when idle" off tucks the pill away while there is nothing to
    //: report. Offline, a failed download, or an open panel all keep it up —
    //: the first two are news, and the panel hangs off the pill.
    readonly property bool idleHidden: !showWhenIdle && svc.connected && !attention && !busy
                                       && svc.waitingCount === 0 && errorCount === 0 && !root.interactionActive

    onIdleHiddenChanged: applyIdleVisibility()

    function applyIdleVisibility() {
        // Older DMS builds have no override; there the pill simply stays.
        if (typeof root.setVisibilityOverride !== "function")
            return
        if (root.idleHidden)
            root.setVisibilityOverride(false)
        else
            root.clearVisibilityOverride()
    }

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
        onTriggered: {
            root.tryClaimWindow()
            root.applyIdleVisibility()
        }
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
        if (!svc.connected)
            return "Manager offline"
        if (busy)
            return svc.activeCount + " active · " + Fmt.speed(svc.downloadSpeed)
                    + (overallProgress >= 0 ? " · " + Math.floor(overallProgress * 100) + "%" : "")
        if (idleText)
            return idleText
        if (errorCount > 0)
            return errorCount + " failed"
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

            PillIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.barIcon
                size: root.iconSize
                color: root.barColor
                progress: root.busy ? root.overallProgress : -1
                alert: root.svc.connected && root.errorCount > 0
            }

            StyledText {
                id: pillLabel

                anchors.verticalCenter: parent.verticalCenter
                text: root.pillText
                visible: text.length > 0
                //: A speed is given the width of its widest form, so
                //: the pill and everything beside it hold still while
                //: the number moves.
                width: root.labelIsSpeed ? Math.max(implicitWidth, Math.ceil(speedMetrics.advanceWidth)) : implicitWidth
                font.pixelSize: root.textSize || Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.labelColor

                TextMetrics {
                    id: speedMetrics

                    font: pillLabel.font
                    text: "88.8 MiB/s"
                }

                Behavior on color {
                    ColorAnimation {
                        duration: Theme.shortDuration
                    }
                }
            }
        }
    }

    verticalBarPill: Component {
        Column {
            // Leaves room for the progress line hung under the icon.
            spacing: root.busy ? Theme.spacingXS : 2

            PillIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.barIcon
                size: root.iconSize
                color: root.barColor
                progress: root.busy ? root.overallProgress : -1
                alert: root.svc.connected && root.errorCount > 0
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.verticalText
                visible: text.length > 0
                font.pixelSize: (root.textSize || Theme.fontSizeSmall) - 1
                font.weight: Font.Medium
                color: root.labelColor
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
