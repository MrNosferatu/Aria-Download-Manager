import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import "../lib/Fmt.js" as Fmt

//: A finished download's detail, opened from its row under Done (Revision 2,
//: board 4). A torrent shows its files as the same tree a live one has, with
//: what is on disk as its progress; changing a file's priority (or "don't
//: download") adds the torrent again for that choice a moment later, keeping
//: what is there. A one-file download shows the file, its link and its folder.
Column {
    id: detail

    property var service: null
    //: The History row's entry; its full record (files, magnet) is fetched.
    property var entry: ({})
    property var record: null
    //: file index -> priority, as the tree shows and edits them.
    property var levels: ({})

    signal forgotten

    readonly property var files: record ? (record.files || []) : []
    readonly property bool torrent: !!entry.isTorrent
    readonly property bool stopped: entry.status === "error" || entry.status === "removed"
    readonly property string magnet: record ? (record.magnet || (String(record.url || "").indexOf("magnet:") === 0 ? record.url : "")) : ""
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string folder: entry.dir || String(entry.path || "").replace(/\/[^/]*$/, "")

    function load() {
        if (!service || !entry.key)
            return
        service.get("/api/history/" + encodeURIComponent(entry.key), (data, error) => {
                        if (error)
                            return
                        detail.record = data
                        const next = ({})
                        for (const f of data.files || [])
                            next[String(f.index)] = f.level !== undefined && f.level !== null ? f.level : (f.selected ? 1 : 0)
                        detail.levels = next
                    })
    }

    //: The tree's shape: what is on disk counts as done.
    readonly property var treeFiles: files.map(f => ({
                                                         "index": String(f.index),
                                                         "path": f.path,
                                                         "length": f.length,
                                                         "completedLength": f.exists ? f.completed : 0
                                                     }))
    readonly property var treeProgress: {
        const out = ({})
        for (const f of files)
            out[String(f.index)] = f.exists ? f.completed : 0
        return out
    }
    readonly property var treeNotes: {
        const out = ({})
        for (const f of files) {
            if (f.selected && !f.exists)
                out[String(f.index)] = "not on disk"
        }
        return out
    }
    //: Wanted but not here: what a fetch would get.
    readonly property int toFetch: files.filter(f => (levels[String(f.index)] || 0) > 0 && !f.exists).length

    function fetch(indices, label) {
        service.post("/api/history/fetch", {
                         "key": entry.key,
                         "indices": indices
                     }, label, () => service.loadHistory())
    }

    //: A priority changed in the tree: fetch that choice once the clicks
    //: settle, so a few changes in a row are one re-add.
    Timer {
        id: fetchTimer

        interval: 1200
        onTriggered: {
            if (detail.toFetch === 0 || detail.magnet === "")
                return
            detail.service.post("/api/history/fetch", {
                                    "key": detail.entry.key,
                                    "levels": detail.levels
                                }, "Fetching " + detail.toFetch + (detail.toFetch === 1 ? " file" : " files"), () => detail.service.loadHistory())
        }
    }

    function readd() {
        service.post("/api/history/readd", {
                         "key": entry.key
                     }, "Added again", () => service.loadHistory())
    }

    Component.onCompleted: load()

    spacing: 10

    // ---- what can be done with it -------------------------------------------
    Flow {
        width: parent.width
        spacing: 8

        PillButton {
            size: 34
            kind: "filled"
            icon: detail.torrent ? "folder_open" : "open_in_new"
            text: detail.torrent ? "Open folder" : "Open"
            visible: detail.entry.file_exists !== false || detail.torrent
            onClicked: Quickshell.execDetached(["xdg-open", detail.torrent ? (detail.entry.path || detail.folder) : detail.entry.path])
        }

        PillButton {
            size: 34
            kind: "outlined"
            icon: "folder_open"
            text: "Show in folder"
            visible: !detail.torrent && !!detail.folder
            onClicked: Quickshell.execDetached(["xdg-open", detail.folder])
        }

        PillButton {
            size: 34
            kind: "outlined"
            icon: "link"
            text: "Copy magnet"
            visible: detail.torrent && detail.magnet !== ""
            onClicked: {
                Quickshell.execDetached(["dms", "cl", "copy", detail.magnet])
                detail.service.notice("Magnet copied")
            }
        }

        //: Stopped part-way it reads Resume: the parts on disk are kept.
        PillButton {
            size: 34
            kind: "outlined"
            icon: detail.stopped ? "play_arrow" : "refresh"
            text: detail.stopped ? "Resume" : (detail.torrent ? "Download all again" : "Download again")
            visible: detail.torrent ? (detail.magnet !== "" && detail.files.length > 0) || !!detail.entry.url : !!detail.entry.url
            onClicked: {
                if (detail.torrent && detail.files.length && detail.magnet)
                    detail.fetch(detail.files.map(f => f.index), detail.stopped ? "Resumed" : "Added again")
                else
                    detail.readd()
            }
        }

        PillButton {
            size: 34
            kind: "dangerText"
            icon: "delete"
            text: "Forget"
            onClicked: detail.service.post("/api/history/remove", {
                                               "key": detail.entry.key
                                           }, "Forgotten", () => {
                                               detail.forgotten()
                                               detail.service.loadHistory()
                                           })
        }
    }

    // ---- a one-file download: the file, its link, its folder -----------------
    Column {
        width: parent.width
        visible: !detail.torrent
        spacing: 4

        Repeater {
            model: [["File", detail.entry.path ? String(detail.entry.path).replace(/^.*\//, "") : (detail.entry.name || "")],
                ["Link", detail.entry.url || "—"], ["Folder", Fmt.homePath(detail.folder, detail.home) || "—"]]

            Item {
                id: fact

                required property var modelData

                width: parent.width
                height: 22

                StyledText {
                    id: factLabel

                    width: 56
                    anchors.verticalCenter: parent.verticalCenter
                    text: fact.modelData[0]
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.outline
                }

                StyledText {
                    anchors.left: factLabel.right
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    text: fact.modelData[1]
                    font.pixelSize: Theme.fontSizeSmall
                    font.family: fact.modelData[0] === "File" ? Theme.fontFamily : "monospace"
                    color: Theme.surfaceText
                    wrapMode: Text.NoWrap
                    elide: Text.ElideMiddle
                }
            }
        }
    }

    //: Stopped part-way: how far it got.
    Item {
        width: parent.width
        height: 18
        visible: detail.stopped && (detail.entry.total || 0) > 0

        Rectangle {
            anchors.left: parent.left
            anchors.right: partPct.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            height: 6
            radius: 3
            color: Theme.surfaceContainerHighest

            Rectangle {
                width: parent.width * Math.min(1, (detail.entry.completed || 0) / Math.max(1, detail.entry.total || 0))
                height: parent.height
                radius: 3
                color: Theme.primary
            }
        }

        StyledText {
            id: partPct

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: Math.floor((detail.entry.completed || 0) / Math.max(1, detail.entry.total || 0) * 100) + "% · " + Fmt.bytes(detail.entry.completed || 0)
                  + " of " + Fmt.bytes(detail.entry.total || 0)
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
        }
    }

    // ---- a torrent: its files, as the live tree ------------------------------
    StyledText {
        width: parent.width
        visible: detail.torrent && !!detail.record && detail.files.length === 0
        wrapMode: Text.WordWrap
        text: "Its file list was not recorded: it finished before this version of the manager kept one."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    FileTreeView {
        width: parent.width
        visible: detail.torrent && detail.files.length > 1
        files: detail.treeFiles
        base: detail.entry.dir || ""
        levels: detail.levels
        progress: detail.treeProgress
        notes: detail.treeNotes
        tileColor: Theme.surfaceContainer
        saving: fetchTimer.running
        onLevelsEdited: next => {
            detail.levels = next
            fetchTimer.restart()
        }
        onOpenRequested: path => Quickshell.execDetached(["xdg-open", path])
    }

    StyledText {
        width: parent.width
        visible: detail.torrent && detail.files.length > 1 && detail.magnet === ""
        wrapMode: Text.WordWrap
        text: "No magnet link was recorded, so changes here cannot fetch it again."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }
}
