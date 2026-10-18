import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Item {
    id: tab

    property var service: null

    //: Embedded under a section header that already names the log and counts
    //: its entries, so the tab's own title would just say it twice.
    property bool compact: false

    //: "all", "errors", "actions" or "aria2c".
    property string filter: "all"

    readonly property var events: service ? service.events : []
    readonly property var filters: [
        ["all", "All", events.length],
        ["errors", "Errors", events.filter(ev => ev.level === "error" || ev.level === "warn" || ev.level === "warning").length],
        ["actions", "Actions", events.filter(ev => ev.level === "rule").length],
        ["aria2c", "aria2c", events.filter(ev => ev.source === "aria2c").length]
    ]
    readonly property var shown: {
        switch (filter) {
        case "errors":
            return events.filter(ev => ev.level === "error" || ev.level === "warn" || ev.level === "warning")
        case "actions":
            return events.filter(ev => ev.level === "rule")
        case "aria2c":
            return events.filter(ev => ev.source === "aria2c")
        default:
            return events
        }
    }

    //: aria2c's own lines arrive with its terminal colours still in them.
    function clean(message) {
        return String(message || "").replace(/\u001b\[[0-9;]*m/g, "").replace(/\s+/g, " ").trim()
    }

    function copyAll() {
        const lines = shown.map(ev => Fmt.dateTime(ev.ts) + "  " + (ev.level || "") + "  " + clean(ev.message))
        Quickshell.execDetached(["dms", "cl", "copy", lines.join("\n")])
        service.notice("Copied " + lines.length + (lines.length === 1 ? " line" : " lines"))
    }

    function levelColor(level) {
        switch (level) {
        case "error":
            return Theme.error
        case "warn":
        case "warning":
            return Theme.warning
        case "rule":
            return Theme.primary
        default:
            return Theme.surfaceVariantText
        }
    }

    Item {
        id: header

        width: parent.width
        height: tab.compact ? 36 : 40

        StyledText {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: !tab.compact
            text: "Event log · " + (tab.service ? tab.service.events.length : 0)
            font.pixelSize: Theme.fontSizeMedium
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        //: Filter chips on the left, what to do with the lines on the right.
        Row {
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            visible: tab.compact
            spacing: Theme.spacingXS

            Repeater {
                model: tab.filters

                Rectangle {
                    id: filterChip

                    required property var modelData

                    readonly property bool selected: tab.filter === modelData[0]

                    width: filterLabel.implicitWidth + Theme.spacingM * 2
                    height: 28
                    radius: 14
                    color: selected ? Theme.primaryContainer : "transparent"
                    border.width: selected ? 0 : 1
                    border.color: filterChip.modelData[0] === "errors" && filterChip.modelData[2] > 0 ? Theme.withAlpha(Theme.error, 0.5)
                                                                                                       : Theme.withAlpha(Theme.outline, 0.5)

                    StyledText {
                        id: filterLabel

                        anchors.centerIn: parent
                        text: filterChip.modelData[1] + " " + filterChip.modelData[2]
                        font.pixelSize: Theme.fontSizeSmall - 1
                        font.weight: filterChip.selected ? Font.DemiBold : Font.Medium
                        color: filterChip.selected ? Theme.onPrimaryContainer
                                                   : (filterChip.modelData[0] === "errors" && filterChip.modelData[2] > 0 ? Theme.error : Theme.surfaceText)
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: tab.filter = filterChip.modelData[0]
                    }
                }
            }
        }

        Row {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 32
                iconSize: Theme.iconSizeSmall
                iconName: "content_copy"
                tooltipText: "Copy all shown lines"
                onClicked: tab.copyAll()
            }

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 32
                iconSize: Theme.iconSizeSmall
                iconName: "refresh"
                tooltipText: "Reload from the manager"
                onClicked: tab.service.loadLog()
            }

            DankActionButton {
                anchors.verticalCenter: parent.verticalCenter
                buttonSize: 32
                iconSize: Theme.iconSizeSmall
                iconName: "clear_all"
                tooltipText: "Clear this view (the manager keeps its log)"
                onClicked: tab.service.events = []
            }
        }
    }

    //: The lines as a code block (board 19): monospace, the time dimmed,
    //: then what kind of line it is in its colour, then the message.
    Rectangle {
        id: codeBox

        anchors.top: header.bottom
        anchors.topMargin: 8
        anchors.bottom: footer.top
        anchors.bottomMargin: 8
        width: parent.width
        radius: 10
        color: Theme.surfaceContainerLowest

        DankListView {
            id: list

            anchors.fill: parent
            anchors.margins: 6
            clip: true
            spacing: 0
            model: tab.shown

            //: Error lines are tinted, so two among a hundred are seen.
            delegate: Item {
                id: line

                required property var modelData

                readonly property bool isError: modelData.level === "error"
                //: The word after the time: an action's name, "error", or who
                //: wrote it when that is not the manager itself.
                readonly property string kind: {
                    const ev = line.modelData
                    if (ev.level === "rule")
                        return ev.rule || "action"
                    if (ev.level && ev.level !== "info")
                        return Fmt.label(ev.level).toLowerCase()
                    return ev.source === "aria2c" ? "aria2c" : ""
                }

                width: list.width
                height: 21

                Rectangle {
                    anchors.fill: parent
                    radius: 5
                    visible: line.isError || lineArea.containsMouse
                    color: line.isError ? Theme.withAlpha(Theme.error, 0.10) : Theme.withAlpha(Theme.surfaceText, 0.05)
                }

                Row {
                    anchors.left: parent.left
                    anchors.leftMargin: 6
                    anchors.right: parent.right
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 8

                    StyledText {
                        id: timeText

                        anchors.verticalCenter: parent.verticalCenter
                        text: Fmt.time(line.modelData.ts)
                        font.pixelSize: Theme.fontSizeSmall - 0.5
                        font.family: "monospace"
                        color: Theme.outline
                    }

                    StyledText {
                        id: kindText

                        anchors.verticalCenter: parent.verticalCenter
                        visible: line.kind !== ""
                        text: line.kind
                        font.pixelSize: Theme.fontSizeSmall - 0.5
                        font.family: "monospace"
                        color: line.modelData.level === "rule" ? Theme.warning : tab.levelColor(line.modelData.level)
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, parent.width - timeText.width - (kindText.visible ? kindText.width + 8 : 0) - 8)
                        //: An action's line already starts with its name in brackets.
                        text: tab.clean(line.modelData.message).replace(/^\[[^\]]*\]\s*/, line.modelData.level === "rule" ? "" : "$&")
                        font.pixelSize: Theme.fontSizeSmall - 0.5
                        font.family: "monospace"
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }
                }

                MouseArea {
                    id: lineArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        Quickshell.execDetached(["dms", "cl", "copy", tab.clean(line.modelData.message)])
                        tab.service.notice("Copied")
                    }
                }
            }
        }
    }

    StyledText {
        id: footer

        anchors.bottom: parent.bottom
        anchors.left: parent.left
        anchors.leftMargin: 2
        height: 18
        verticalAlignment: Text.AlignVCenter
        text: "Click a line to copy it · newest first · live"
        font.pixelSize: Theme.fontSizeSmall - 1
        color: Theme.surfaceVariantText
    }

    StyledText {
        anchors.centerIn: parent
        visible: list.count === 0
        text: tab.filter === "all" ? "Nothing logged yet." : "Nothing under this filter."
        font.pixelSize: Theme.fontSizeMedium
        color: Theme.surfaceVariantText
    }
}
