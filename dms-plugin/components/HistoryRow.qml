import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

//: One recorded download, laid out like a live row: the status tile, the name,
//: one line of facts, the one action that fits, and the rest behind ⋮.
//: Clicked, it opens its detail (HistoryDetail) like a live download's.
Rectangle {
    id: row

    property var service: null
    property var entry: ({})
    property bool expanded: false
    //: Selecting (the list's bulk mode): a box to tick, and a click anywhere
    //: ticks it; the detail and the row's own buttons step aside.
    property bool selectable: false
    property bool selected: false

    signal toggleSelected(bool range)

    onSelectableChanged: {
        if (selectable)
            expanded = false
    }

    readonly property bool failed: entry.status === "error"

    //: The manager stats each recorded path when it serves the history. Only an
    //: explicit false means the file has since been moved or deleted; undefined
    //: means the row never had a path to check.
    readonly property bool fileMissing: entry.file_exists === false

    readonly property color statusColor: {
        if (failed)
            return Theme.error
        if (fileMissing)
            return Theme.surfaceVariantText
        return entry.status === "complete" ? Theme.success : Theme.surfaceVariantText
    }

    readonly property string home: Quickshell.env("HOME") || ""

    function readd() {
        service.post("/api/history/readd", {
                         "key": entry.key
                     }, "Added again", () => service.loadHistory())
    }

    //: The one action that fits: open what is there, fetch again what is not,
    //: retry what failed.
    readonly property var primaryAction: {
        if (failed && entry.url)
            return {
                "icon": "refresh",
                "text": "Retry",
                "run": () => row.readd()
            }
        if (fileMissing && entry.url)
            return {
                "icon": "refresh",
                "text": "Again",
                "run": () => row.readd()
            }
        // Removed part-way: what is on disk is kept, so it resumes.
        if (entry.status === "removed" && entry.total && entry.completed < entry.total && entry.url)
            return {
                "icon": "play_arrow",
                "text": "Resume",
                "run": () => row.readd()
            }
        if (canOpen)
            return {
                "icon": "open_in_new",
                "text": "Open",
                "run": () => row.openFile()
            }
        return null
    }

    readonly property bool canOpen: !!entry.path && !fileMissing && !failed

    function openFile() {
        Quickshell.execDetached(["xdg-open", entry.path])
    }

    readonly property var moreActions: {
        const out = []
        if (canOpen) {
            out.push({
                         "icon": "open_in_new",
                         "text": "Open",
                         "run": () => row.openFile()
                     })
            //: DMS's own application picker, the shell's "Open with".
            out.push({
                         "icon": "apps",
                         "text": "Open with…",
                         "run": () => Quickshell.execDetached(["dms", "open", "--type", "file", entry.path])
                     })
        }
        if ((entry.dir || entry.path) && !fileMissing)
            out.push({
                         "icon": "folder_open",
                         "text": "Show in folder",
                         "run": () => Quickshell.execDetached(["xdg-open", entry.dir || entry.path.replace(/\/[^/]*$/, "")])
                     })
        if (entry.url && primaryAction && primaryAction.text === "Open")
            out.push({
                         "icon": "refresh",
                         "text": "Download again",
                         "run": () => row.readd()
                     })
        if (entry.url)
            out.push({
                         "icon": "link",
                         "text": "Copy link",
                         "run": () => {
                             Quickshell.execDetached(["dms", "cl", "copy", entry.url])
                             service.notice("Link copied")
                         }
                     })
        out.push({
                     "icon": "delete",
                     "text": "Forget",
                     "danger": true,
                     "run": () => service.post("/api/history/remove", {
                                                   "key": entry.key
                                               }, "Forgotten", () => service.loadHistory())
                 })
        return out
    }

    readonly property string metaText: {
        if (failed) {
            const known = service ? service.explainError(entry.error) : null
            return "Failed · " + (known ? known.why : (entry.error || "no reason recorded"))
        }
        const bits = entry.isTorrent ? ["Torrent", Fmt.bytes(entry.total || entry.completed)] : [Fmt.bytes(entry.total || entry.completed)]
        if (fileMissing)
            bits.push("was in " + Fmt.homePath(entry.dir, home))
        else if (entry.dir)
            bits.push(Fmt.homePath(entry.dir, home))
        const when = Fmt.shortWhen(entry.finished_at || entry.added_at)
        if (when)
            bits.push(when)
        return bits.join(" · ")
    }

    height: expanded ? 52 + detailLoader.height + 14 : 52
    radius: expanded ? 18 : 12
    color: {
        if (selected)
            return Theme.withAlpha(Theme.primary, 0.10)
        if (selectable && rowArea.containsMouse)
            return Theme.surfaceContainerHigh
        return expanded ? Theme.surfaceContainerHigh : Theme.surfaceContainer
    }
    border.width: failed || expanded ? 1 : 0
    border.color: failed ? Theme.withAlpha(Theme.error, 0.35) : Theme.outlineVariant

    //: The one-line head; the detail opens under it.
    Item {
        id: head

        width: parent.width
        height: 52
    }

    //: A double click opens the file; a right click brings up the menu at
    //: the pointer.
    MouseArea {
        id: rowArea

        anchors.fill: head
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        hoverEnabled: row.selectable
        cursorShape: Qt.PointingHandCursor
        onClicked: mouse => {
            if (row.selectable) {
                if (mouse.button === Qt.LeftButton)
                    row.toggleSelected((mouse.modifiers & Qt.ShiftModifier) !== 0)
            } else if (mouse.button === Qt.RightButton) {
                const at = rowArea.mapToItem(historyMenu.parent, mouse.x, mouse.y)
                historyMenu.openAt(at.x, at.y)
            } else {
                row.expanded = !row.expanded
            }
        }
        onDoubleClicked: mouse => {
            if (mouse.button === Qt.LeftButton && row.canOpen && !row.selectable)
                row.openFile()
        }
    }

    //: The box, while selecting; the click itself is the row's.
    DankIcon {
        id: picker

        anchors.left: parent.left
        anchors.leftMargin: 12
        anchors.verticalCenter: head.verticalCenter
        visible: row.selectable
        name: row.selected ? "check_box" : "check_box_outline_blank"
        size: 20
        color: row.selected ? Theme.primary : Theme.surfaceVariantText
    }

    Rectangle {
        id: tile

        anchors.left: row.selectable ? picker.right : parent.left
        anchors.leftMargin: row.selectable ? 8 : 10
        anchors.verticalCenter: head.verticalCenter
        width: 34
        height: 34
        radius: 10
        color: row.fileMissing ? Theme.surfaceContainerHigh : Theme.withAlpha(row.statusColor, 0.15)

        DankIcon {
            anchors.centerIn: parent
            name: Fmt.kindIcon(row.entry.name, !!row.entry.isTorrent, false)
            size: 18
            color: row.fileMissing ? Theme.outline : row.statusColor
        }
    }

    Row {
        id: actions

        anchors.right: parent.right
        anchors.rightMargin: 6
        anchors.verticalCenter: head.verticalCenter
        visible: !row.selectable
        width: visible ? implicitWidth : 0
        spacing: 4

        PillButton {
            anchors.verticalCenter: parent.verticalCenter
            visible: row.primaryAction !== null && !row.expanded
            size: 30
            kind: "outlined"
            icon: row.primaryAction && row.primaryAction.text !== "Open" ? row.primaryAction.icon : ""
            text: row.primaryAction ? row.primaryAction.text : ""
            onClicked: row.primaryAction.run()
        }

        DankActionButton {
            id: menuButton

            anchors.verticalCenter: parent.verticalCenter
            buttonSize: 30
            iconSize: 20
            iconName: row.expanded ? "expand_less" : "more_vert"
            iconColor: Theme.surfaceVariantText
            tooltipText: row.expanded ? "Fold" : "More"
            onClicked: row.expanded ? (row.expanded = false) : historyMenu.toggle()
        }
    }

    MenuPopup {
        id: historyMenu

        parent: menuButton
        alignEnd: true
        menuWidth: 220
        entries: {
            const out = []
            for (const a of row.moreActions) {
                // Only between groups: a lone Forget gets no rule above it.
                if (a.danger && out.length > 0)
                    out.push({
                                 "separator": true
                             })
                out.push({
                             "icon": a.icon,
                             "text": a.text,
                             "danger": !!a.danger
                         })
            }
            return out
        }
        onTriggered: index => {
            let n = -1
            for (let i = 0; i <= index; i++) {
                if (!entries[i].separator)
                    n++
            }
            if (!entries[index].separator)
                row.moreActions[n].run()
        }
    }

    Column {
        anchors.left: tile.right
        anchors.leftMargin: 10
        anchors.right: actions.left
        anchors.rightMargin: 10
        anchors.verticalCenter: head.verticalCenter
        spacing: 3

        Row {
            width: parent.width
            spacing: 8

            StyledText {
                width: Math.max(0, Math.min(implicitWidth, parent.width - (missingBadge.visible ? missingBadge.width + 8 : 0)))
                text: row.entry.name || row.entry.key || ""
                font.pixelSize: Theme.fontSizeSmall + 1
                font.weight: Font.DemiBold
                color: Theme.surfaceText
                wrapMode: Text.NoWrap
                elide: Text.ElideMiddle
            }

            Rectangle {
                id: missingBadge

                anchors.verticalCenter: parent.verticalCenter
                visible: row.fileMissing && !row.failed
                width: missingLabel.implicitWidth + 14
                height: 19
                radius: 6
                color: Theme.withAlpha(Theme.warning, 0.14)

                StyledText {
                    id: missingLabel

                    anchors.centerIn: parent
                    text: "File missing"
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.DemiBold
                    color: Theme.warning
                }
            }
        }

        StyledText {
            width: parent.width
            text: row.metaText
            font.pixelSize: Theme.fontSizeSmall
            color: row.failed ? Theme.error : Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }
    }

    Loader {
        id: detailLoader

        anchors.top: head.bottom
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.leftMargin: 12
        anchors.rightMargin: 12
        active: row.expanded
        height: active && item ? item.implicitHeight : 0

        sourceComponent: HistoryDetail {
            service: row.service
            entry: row.entry
            onForgotten: row.expanded = false
        }
    }
}
