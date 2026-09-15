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

    readonly property color barColor: {
        if (!svc.connected)
            return Theme.surfaceVariantText
        if (attention)
            return Theme.error
        if (busy)
            return Theme.primary
        return Theme.surfaceText
    }

    readonly property string pillText: {
        if (!svc.connected)
            return "offline"
        if (pillMode === "none")
            return ""
        if (pillMode === "count")
            return svc.activeCount + (svc.waitingCount > 0 ? "/" + (svc.activeCount + svc.waitingCount) : "")
        return busy ? Fmt.speed(svc.downloadSpeed) : (svc.waitingCount > 0 ? svc.waitingCount + " queued" : "")
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
        if (svc.waitingCount > 0)
            return svc.waitingCount + " queued"
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

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: root.barIcon
                size: root.iconSize
                color: root.barColor
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: root.pillText
                visible: text.length > 0
                font.pixelSize: Theme.fontSizeSmall
                font.weight: Font.Medium
                color: root.barColor
            }
        }
    }

    verticalBarPill: Component {
        Column {
            spacing: 2

            DankIcon {
                anchors.horizontalCenter: parent.horizontalCenter
                name: root.barIcon
                size: root.iconSize
                color: root.barColor
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.svc.connected ? root.svc.activeCount : "–"
                visible: root.pillMode !== "none"
                font.pixelSize: Theme.fontSizeSmall - 1
                font.weight: Font.Medium
                color: root.barColor
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
