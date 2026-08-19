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

    layerNamespacePlugin: "aria2c-manager"

    property var popoutService: null

    readonly property var svc: Aria2Service
    readonly property string pillMode: pluginData.pillMode || "speed"
    readonly property bool showWhenIdle: pluginData.showWhenIdle !== false
    readonly property int popoutHeightSetting: parseInt(pluginData.popoutHeight || "540") || 540

    readonly property bool busy: svc.activeCount > 0
    readonly property bool attention: svc.connected && !svc.aria2Running

    readonly property string barIcon: {
        if (!svc.connected)
            return "cloud_off"
        if (attention)
            return "error"
        if (busy)
            return "download"
        return "download_done"
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

    Connections {
        target: root.svc
        function onPopoutToggleRequested() {
            // Only a bar-hosted instance owns a popout. DMS also builds
            // throwaway instances to probe for a control-center widget, and
            // those must not answer the broadcast.
            if (root.axis)
                root.triggerPopout()
        }
    }

    // ---- control center --------------------------------------------------
    ccWidgetIcon: barIcon
    ccWidgetPrimaryText: "Downloads"
    ccWidgetSecondaryText: {
        if (!svc.connected)
            return "manager offline"
        if (busy)
            return svc.activeCount + " active · " + Fmt.speed(svc.downloadSpeed)
        if (svc.waitingCount > 0)
            return svc.waitingCount + " queued"
        return "idle"
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
        }
    }
}
