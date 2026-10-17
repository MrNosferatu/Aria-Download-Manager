import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.Common
import qs.Widgets
import "../lib/Fmt.js" as Fmt

//: The card that answers "how is it going?" without a click: hovering the bar
//: pill for a moment shows it, leaving the pill hides it. A layer-shell window
//: of its own rather than a tooltip inside the bar, which would be clipped to
//: the bar's thickness, and rather than a DankPopout, which takes focus and
//: lays a dismiss layer over the screen. It takes no input at all, so it can
//: never get between the pointer and the pill.
PanelWindow {
    id: card

    property var service: null

    //: Whether a middle click on the pill flips pause/resume; the hint line
    //: only mentions it when it works.
    property bool middleClickWorks: false

    // Where to hang: the pill's popup anchor from PluginComponent.pillAnchor().
    property real triggerX: 0
    property real triggerY: 0
    property real triggerWidth: 0
    //: Bar edge, as DMS numbers it: 0 top, 1 bottom, 2 left, 3 right.
    property int edge: 0
    property var targetScreen: null

    readonly property bool online: !!service && service.connected
    readonly property bool down: online && !service.aria2Running
    readonly property bool busy: online && !down && service.activeCount > 0
    readonly property bool held: online && !down && !busy && service.waitingCount > 0
    readonly property var totals: service ? service.activeTotals : ({})

    readonly property string headline: {
        if (!service)
            return ""
        if (!online)
            return "Manager not running"
        if (down)
            return "aria2c stopped"
        if (busy)
            return service.activeCount + " downloading"
        if (service.pausedCount > 0 && service.queuedCount > 0)
            return service.pausedCount + " paused, " + service.queuedCount + " waiting"
        if (service.pausedCount > 0)
            return service.pausedCount + " paused"
        if (service.queuedCount > 0)
            return service.queuedCount + " waiting"
        return "Nothing downloading"
    }

    //: The figure beside the headline while running: how far, then how long.
    readonly property string figure: {
        if (!busy)
            return ""
        const bits = []
        if (totals.progress >= 0)
            bits.push(Math.floor(totals.progress * 100) + "%")
        if (totals.eta >= 0)
            bits.push(Fmt.eta(totals.eta))
        return bits.join(" · ")
    }

    //: Up to two running downloads by name; the rest is the manager's job.
    readonly property var names: busy ? service.downloads.filter(d => d.status === "active").slice(0, 2) : []

    readonly property string detail: {
        if (!service || busy)
            return ""
        if (!online)
            return service.socketPath
        if (down) {
            const waiting = service.activeCount + service.waitingCount
            return (service.aria2.last_error || "It stopped without saying why.")
                    + (waiting > 0 ? " " + waiting + (waiting === 1 ? " download is" : " downloads are") + " waiting for it." : "")
        }
        if (held)
            return "Nothing is moving." + (middleClickWorks ? " Middle-click resumes all." : "")
        const today = service.finishedToday
        if (today.count > 0)
            return today.count + " finished today · last: " + today.last
        return ""
    }

    readonly property string hint: {
        if (!online)
            return "Click · how to start it"
        if (down)
            return "Right-click · restart aria2c"
        const parts = ["Click · manager"]
        if (held && middleClickWorks)
            parts.push("Middle · resume all")
        else
            parts.push("Right-click · actions")
        if (busy && middleClickWorks)
            parts.push("Middle · pause all")
        return parts.join("   ")
    }

    function showAt(anchor, barEdge) {
        if (!anchor)
            return
        triggerX = anchor.trigger.x
        triggerY = anchor.trigger.y
        triggerWidth = anchor.trigger.width
        targetScreen = anchor.screen
        edge = barEdge
        visible = true
        body.opacity = 1
    }

    function hide() {
        body.opacity = 0
        visible = false
    }

    WlrLayershell.namespace: "dms:plugins:aria-download-manager-hover"
    WlrLayershell.layer: WlrLayershell.Overlay
    WlrLayershell.exclusiveZone: -1
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

    screen: targetScreen
    visible: false
    color: "transparent"
    mask: Region {}
    implicitWidth: 300
    implicitHeight: content.implicitHeight + 28

    anchors {
        top: true
        left: true
    }

    margins {
        left: {
            const screenWidth = card.targetScreen?.width ?? Screen.width
            let x = card.triggerX + card.triggerWidth / 2 - card.implicitWidth / 2
            if (card.edge === 2)
                x = card.triggerX
            else if (card.edge === 3)
                x = card.triggerX - card.implicitWidth
            return Math.round(Math.max(Theme.spacingS, Math.min(screenWidth - card.implicitWidth - Theme.spacingS, x)))
        }
        top: {
            const screenHeight = card.targetScreen?.height ?? Screen.height
            let y = card.triggerY
            if (card.edge === 1)
                y = card.triggerY - card.implicitHeight
            return Math.round(Math.max(Theme.spacingS, Math.min(screenHeight - card.implicitHeight - Theme.spacingS, y)))
        }
    }

    Rectangle {
        id: body

        anchors.fill: parent
        radius: 14
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: card.down ? Theme.withAlpha(Theme.error, 0.4) : Theme.withAlpha(Theme.outline, 0.25)
        opacity: 0

        Behavior on opacity {
            NumberAnimation {
                duration: Theme.shortDuration
                easing.type: Theme.standardEasing
            }
        }

        Column {
            id: content

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.leftMargin: 16
            anchors.rightMargin: 16
            anchors.topMargin: 14
            spacing: 9

            Item {
                width: parent.width
                height: Math.max(headIcon.height, headText.implicitHeight)

                DankIcon {
                    id: headIcon

                    anchors.left: parent.left
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !card.online || card.down
                    name: card.down ? "error" : "cloud_off"
                    size: 18
                    color: card.down ? Theme.error : Theme.surfaceVariantText
                }

                StyledText {
                    id: headText

                    anchors.left: headIcon.visible ? headIcon.right : parent.left
                    anchors.leftMargin: headIcon.visible ? Theme.spacingS : 0
                    anchors.right: figureText.left
                    anchors.rightMargin: Theme.spacingS
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.headline
                    font.pixelSize: Theme.fontSizeMedium
                    font.weight: Font.Bold
                    color: card.down ? Theme.error : Theme.surfaceText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }

                StyledText {
                    id: figureText

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: card.figure
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }
            }

            Repeater {
                model: card.names

                Item {
                    required property var modelData

                    width: content.width
                    height: nameText.implicitHeight

                    StyledText {
                        id: nameText

                        anchors.left: parent.left
                        anchors.right: pctText.left
                        anchors.rightMargin: Theme.spacingS
                        text: parent.modelData.name || parent.modelData.gid
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        elide: Text.ElideMiddle
                        wrapMode: Text.NoWrap
                    }

                    StyledText {
                        id: pctText

                        anchors.right: parent.right
                        text: parent.modelData.isMetadata ? "…" : Math.floor(parent.modelData.progress || 0) + "%"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: text.length > 0
                text: card.detail
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: card.online ? Text.WordWrap : Text.NoWrap
                // The socket path is the one long thing worth keeping whole at the end.
                elide: card.online ? Text.ElideNone : Text.ElideLeft
                maximumLineCount: 3
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.outlineVariant
            }

            StyledText {
                width: parent.width
                text: card.hint
                font.pixelSize: Theme.fontSizeSmall - 1
                lineHeight: 1.3
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }
    }
}
