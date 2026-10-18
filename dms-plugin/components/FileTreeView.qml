import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/FileTree.js" as FileTree

//: A torrent's files as a tree, like qBittorrent's (boards 3, 5, 17): the
//: summary, Expand all, a filter for big torrents, then Name | Size |
//: Progress | Priority. Folders carry their files' totals. Changes go out
//: as `levelsEdited`; the owner saves them (a live download's detail) or
//: fetches them (a finished torrent in History). A file opens on a double
//: click.
Column {
    id: view

    //: {index, path, length, completedLength}, as aria2's getFiles.
    property var files: []
    //: The download's folder, cut off each path.
    property string base: ""
    //: file index -> 0 don't download, 1 normal, 2 high, 3 maximum.
    property var levels: ({})
    //: file index -> bytes done, read live by the rows.
    property var progress: ({})
    property bool reviewing: false
    property bool held: false
    property bool saving: false
    //: The tone of the filter field.
    property color tileColor: Theme.surfaceContainer
    //: file index -> a word on the row ("not on disk"), in the warning colour.
    property var notes: ({})

    signal levelsEdited(var levels)
    signal openRequested(string path)

    property var collapsed: ({})
    property string filter: ""
    property string sortKey: "name"
    property bool sortDesc: false

    readonly property var tree: FileTree.treeBuild(files, base)
    readonly property var rows: files.length > 1 ? FileTree.treeRows(tree, levels, collapsed, filter, sortKey, sortDesc) : []
    readonly property var summary: FileTree.treeSummary(files, levels)
    readonly property var pathByIndex: {
        const out = ({})
        for (const f of files)
            out[String(f.index)] = f.path
        return out
    }

    //: Back to unfolded and unfiltered, for another download.
    function reset() {
        collapsed = ({})
    }

    function doneOf(indices) {
        let total = 0
        for (const i of indices)
            total += progress[i] || 0
        return total
    }

    function toggleFold(key, open) {
        const next = Object.assign({}, collapsed)
        next[key] = open
        collapsed = next
    }

    function sortBy(key) {
        if (sortKey === key) {
            sortDesc = !sortDesc
        } else {
            sortKey = key
            sortDesc = key !== "name"   // biggest, most done, highest first
        }
    }

    spacing: 6

    //: The columns at the end of a row (Revision 2, board 3): size, progress
    //: and priority. The bar and the chip step aside for a held torrent,
    //: which only needs its choice, and the bar while reviewing.
    //: Narrower than the popout (the window's pane), progress moves under
    //: the name as a thin line and the other columns slim down, so the name
    //: keeps room.
    readonly property bool narrowFiles: width < 520
    readonly property int fileSizeWidth: narrowFiles ? 64 : 76
    readonly property int fileBarWidth: reviewing || held || narrowFiles ? 0 : 132
    readonly property int fileChipWidth: held ? 0 : (narrowFiles ? 72 : 84)
    readonly property int fileIndent: narrowFiles ? 14 : 22
    readonly property var levelWords: ["Skip", "Normal", "High", "Max"]
    //: The menu says it in full; the chip keeps the short word.
    readonly property var levelChoices: ["Don't download", "Normal", "High", "Max"]
    //: Every folder key, for "Collapse all".
    readonly property var folderKeys: {
        const out = []
        const walk = node => {
            for (const name in node.dirs) {
                out.push(node.dirs[name].key)
                walk(node.dirs[name])
            }
        }
        walk(tree)
        return out
    }
    readonly property bool anyCollapsed: Object.keys(collapsed).some(k => collapsed[k])

    Item {
        width: parent.width
        height: 30

        StyledText {
            anchors.left: parent.left
            anchors.right: foldAll.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: view.summary.chosen + " of " + view.summary.count + " files wanted · " + Fmt.bytes(view.summary.selected) + " of "
                  + Fmt.bytes(view.summary.total) + (view.tree.name ? " · inside " + view.tree.name + "/" : "")
                  + (view.saving ? " · saving…" : "")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        PillButton {
            id: foldAll

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            visible: view.folderKeys.length > 0
            size: 30
            kind: "surface"
            icon: view.anyCollapsed ? "unfold_more" : "unfold_less"
            text: view.anyCollapsed ? "Expand all" : "Collapse all"
            onClicked: {
                if (view.anyCollapsed) {
                    view.collapsed = ({})
                } else {
                    const all = ({})
                    for (const key of view.folderKeys)
                        all[key] = true
                    view.collapsed = all
                }
            }
        }
    }

    SearchPill {
        width: parent.width
        fill: view.reviewing ? Theme.surfaceContainerHigh : view.tileColor
        visible: view.reviewing || view.files.length >= 12
        size: 36
        placeholderText: "Filter files"
        onTextChanged: view.filter = text
    }

    //: Name | Size | Progress | Priority; a heading sorts by it.
    Item {
        width: parent.width
        height: 20

        //: Inline, so it cannot see `detail`: the sort comes in as properties.
        component Heading: StyledText {
            id: heading

            property string label: ""
            property bool on: false
            property bool desc: false
            signal clicked

            text: (label + (on ? (desc ? " ↓" : " ↑") : "")).toUpperCase()
            font.pixelSize: Theme.fontSizeSmall - 1
            font.weight: Font.Bold
            font.letterSpacing: 0.6
            color: on ? Theme.primary : Theme.outline

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: heading.clicked()
            }
        }

        Heading {
            anchors.left: parent.left
            anchors.leftMargin: 12
            anchors.verticalCenter: parent.verticalCenter
            label: "Name"
            on: view.sortKey === "name"
            desc: view.sortDesc
            onClicked: view.sortBy("name")
        }

        Row {
            anchors.right: parent.right
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            spacing: 8

            Heading {
                width: view.fileSizeWidth
                horizontalAlignment: Text.AlignRight
                label: "Size"
                on: view.sortKey === "size"
                desc: view.sortDesc
                onClicked: view.sortBy("size")
            }

            Heading {
                width: view.fileBarWidth
                visible: width > 0
                label: "Progress"
                on: view.sortKey === "progress"
                desc: view.sortDesc
                onClicked: view.sortBy("progress")
            }

            Heading {
                width: view.fileChipWidth
                visible: width > 0
                label: "Priority"
                on: view.sortKey === "priority"
                desc: view.sortDesc
                onClicked: view.sortBy("priority")
            }
        }
    }

    Repeater {
        model: view.rows

        Item {
            id: fileRow

            required property var modelData
            readonly property var r: modelData
            //: Progress over the wanted files only, so skipped ones do not
            //: hold a folder back; read from the live per-file figures.
            readonly property var wantedIndices: r.indices.filter(i => FileTree.treeLevelOf(view.levels, i) > 0)
            readonly property real wantedDone: view.doneOf(wantedIndices)
            readonly property real pct: r.wanted ? Math.min(100, wantedDone / r.wanted * 100) : 0
            readonly property bool skipped: r.state === 0
            readonly property string note: r.isDir ? "" : (view.notes[r.index] || "")

            width: view.width
            height: r.isDir ? 38 : 34

            Rectangle {
                anchors.fill: parent
                radius: 10
                color: rowHover.hovered ? Theme.withAlpha(Theme.surfaceText, 0.06)
                                        : (fileRow.r.isDir ? Theme.withAlpha(Theme.surfaceText, 0.03) : "transparent")
            }

            HoverHandler {
                id: rowHover
            }

            //: A file opens on a double click, once it is on disk.
            MouseArea {
                anchors.fill: parent
                enabled: !fileRow.r.isDir
                onDoubleClicked: {
                    const path = view.pathByIndex[fileRow.r.index]
                    if (path && !fileRow.note)
                        view.openRequested(path)
                }
            }

            Item {
                id: indent

                anchors.left: parent.left
                anchors.leftMargin: 8
                width: fileRow.r.depth * view.fileIndent + (fileRow.r.isDir || !view.folderKeys.length ? 0 : view.fileIndent)
                height: parent.height
            }

            //: Ticked, a dash or empty: all, some or none of it wanted.
            Item {
                id: check

                anchors.left: indent.right
                width: 26
                height: parent.height

                Rectangle {
                    anchors.centerIn: parent
                    width: 20
                    height: 20
                    radius: 5
                    color: fileRow.r.state > 0 ? Theme.primary : "transparent"
                    border.width: fileRow.r.state > 0 ? 0 : 2
                    border.color: Theme.outline

                    DankIcon {
                        anchors.centerIn: parent
                        visible: fileRow.r.state > 0
                        name: fileRow.r.state === 2 ? "check" : "remove"
                        size: 16
                        color: Theme.onPrimary
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: view.levelsEdited(FileTree.treeSetChosen(view.levels, fileRow.r.indices, fileRow.r.state !== 2))
                }
            }

            Item {
                id: fold

                anchors.left: check.right
                width: fileRow.r.isDir ? 22 : 0
                height: parent.height

                DankIcon {
                    anchors.centerIn: parent
                    visible: fileRow.r.isDir
                    name: fileRow.r.open ? "expand_more" : "chevron_right"
                    size: 20
                    color: Theme.surfaceVariantText
                }

                MouseArea {
                    anchors.fill: parent
                    enabled: fileRow.r.isDir
                    cursorShape: Qt.PointingHandCursor
                    onClicked: view.toggleFold(fileRow.r.key, fileRow.r.open)
                }
            }

            DankIcon {
                id: kindGlyph

                anchors.left: fold.right
                anchors.leftMargin: 4
                anchors.verticalCenter: parent.verticalCenter
                visible: !view.held
                name: fileRow.r.isDir ? (fileRow.r.open ? "folder_open" : "folder") : Fmt.kindIcon(fileRow.r.name, false, false)
                size: fileRow.r.isDir ? 20 : 18
                color: fileRow.r.isDir ? Theme.primary : (fileRow.skipped ? Theme.outline : Theme.surfaceVariantText)
            }

            Row {
                anchors.left: kindGlyph.visible ? kindGlyph.right : fold.right
                anchors.leftMargin: 6
                anchors.right: tail.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 6

                StyledText {
                    id: rowName

                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(0, Math.min(implicitWidth, parent.width - (dirCount.visible ? dirCount.implicitWidth + 6 : 0)))
                    text: fileRow.r.name
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle
                    font.pixelSize: Theme.fontSizeSmall + 1
                    font.weight: fileRow.r.isDir ? Font.DemiBold : Font.Normal
                    color: fileRow.note ? Theme.warning : (fileRow.skipped ? Theme.outline : Theme.surfaceText)

                    MouseArea {
                        anchors.fill: parent
                        enabled: fileRow.r.isDir
                        cursorShape: fileRow.r.isDir ? Qt.PointingHandCursor : Qt.ArrowCursor
                        onClicked: view.toggleFold(fileRow.r.key, fileRow.r.open)
                    }
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: fileRow.note !== ""
                    text: fileRow.note
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.warning
                }

                StyledText {
                    id: dirCount

                    anchors.verticalCenter: parent.verticalCenter
                    visible: fileRow.r.isDir && !view.narrowFiles
                    text: fileRow.r.count === 1 ? "1 file" : fileRow.r.count + " files"
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.outline
                }
            }

            //: Narrow: the progress as a line under the name.
            Rectangle {
                anchors.left: kindGlyph.visible ? kindGlyph.right : fold.right
                anchors.leftMargin: 6
                anchors.right: tail.left
                anchors.rightMargin: 8
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 4
                visible: view.narrowFiles && !view.reviewing && !view.held && !fileRow.skipped
                height: 3
                radius: 1.5
                color: Theme.surfaceContainerHighest

                Rectangle {
                    width: parent.width * fileRow.pct / 100
                    height: parent.height
                    radius: 1.5
                    color: fileRow.pct >= 100 ? Theme.success : Theme.primary
                }
            }

            Row {
                id: tail

                anchors.right: parent.right
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8

                //: The wanted bytes; "1.5 GiB of 3.8 GiB" when some are skipped.
                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: view.fileSizeWidth
                    horizontalAlignment: Text.AlignRight
                    text: fileRow.r.isDir && fileRow.r.wanted > 0 && fileRow.r.wanted < fileRow.r.size
                          ? Fmt.bytes(fileRow.r.wanted) + " of " + Fmt.bytes(fileRow.r.size) : Fmt.bytes(fileRow.r.size)
                    font.pixelSize: Theme.fontSizeSmall
                    color: fileRow.skipped ? Theme.outline : Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                    maximumLineCount: 2
                    lineHeight: 0.9
                }

                //: Bytes done over bytes wanted; green at 100%.
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: view.fileBarWidth
                    height: 16
                    visible: width > 0

                    Rectangle {
                        anchors.left: parent.left
                        anchors.right: pctText.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        height: 6
                        radius: 3
                        color: Theme.surfaceContainerHighest

                        Rectangle {
                            width: parent.width * fileRow.pct / 100
                            height: parent.height
                            radius: 3
                            visible: !fileRow.skipped
                            color: fileRow.pct >= 100 ? Theme.success : Theme.primary
                        }
                    }

                    StyledText {
                        id: pctText

                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34
                        horizontalAlignment: Text.AlignRight
                        text: fileRow.skipped ? (fileRow.r.isDir ? "—" : "skip") : Math.floor(fileRow.pct) + "%"
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }
                }

                //: Skip, Normal, High, Max, or Mixed when a folder's files
                //: differ. Setting a folder's sets every file inside.
                Item {
                    anchors.verticalCenter: parent.verticalCenter
                    width: view.fileChipWidth
                    height: 26
                    visible: width > 0

                    Rectangle {
                        id: levelChip

                        readonly property string word: fileRow.r.level === -1 ? "Mixed" : (view.levelWords[fileRow.r.level] || "Normal")
                        readonly property bool raised: fileRow.r.level >= 2

                        anchors.fill: parent
                        radius: 13
                        color: raised ? Theme.secondaryContainer : Theme.surfaceContainerHighest

                        StyledText {
                            anchors.left: parent.left
                            anchors.leftMargin: 10
                            anchors.verticalCenter: parent.verticalCenter
                            text: levelChip.word
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: levelChip.raised ? Font.DemiBold : Font.Medium
                            color: fileRow.r.level === 0 ? Theme.outline : Theme.surfaceText
                        }

                        DankIcon {
                            anchors.right: parent.right
                            anchors.rightMargin: 4
                            anchors.verticalCenter: parent.verticalCenter
                            name: "unfold_more"
                            size: 14
                            color: Theme.surfaceVariantText
                        }

                        MouseArea {
                            anchors.fill: parent
                            cursorShape: Qt.PointingHandCursor
                            onClicked: levelMenu.toggle()
                        }

                        MenuPopup {
                            id: levelMenu

                            alignEnd: true
                            menuWidth: 150
                            entries: view.levelChoices.map((w, i) => ({
                                                                         "text": w,
                                                                         "checked": i === fileRow.r.level
                                                                     }))
                            onTriggered: index => view.levelsEdited(FileTree.treeSetLevel(view.levels, fileRow.r.indices, index))
                        }
                    }
                }
            }
        }
    }
}
