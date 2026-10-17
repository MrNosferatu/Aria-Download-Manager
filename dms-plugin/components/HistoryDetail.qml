import QtQuick
import Quickshell
import qs.Common
import qs.Widgets
import "../lib/Fmt.js" as Fmt

//: A finished download's detail, opened from its History row (Revision 2,
//: board 4). A torrent lists its files, each done, skipped or no longer on
//: disk; ticking skipped or missing ones and "Download N more" adds the
//: torrent again for just those, keeping what is there. A one-file download
//: shows the file, its link and its folder.
Column {
    id: detail

    property var service: null
    //: The History row's entry; its full record (files, magnet) is fetched.
    property var entry: ({})
    property var record: null
    //: aria2 file indices ticked for fetching.
    property var picks: ({})

    signal forgotten

    readonly property var files: record ? (record.files || []) : []
    readonly property bool torrent: !!entry.isTorrent
    readonly property bool stopped: entry.status === "error" || entry.status === "removed"
    readonly property string magnet: record ? (record.magnet || (String(record.url || "").indexOf("magnet:") === 0 ? record.url : "")) : ""
    readonly property string home: Quickshell.env("HOME") || ""
    readonly property string folder: entry.dir || String(entry.path || "").replace(/\/[^/]*$/, "")

    function fileState(f) {
        if (!f.selected)
            return "skipped"
        return f.exists ? "done" : "missing"
    }

    readonly property var counts: {
        const out = {
            "done": 0,
            "missing": 0,
            "skipped": 0
        }
        for (const f of files)
            out[fileState(f)]++
        return out
    }
    readonly property var pickedFiles: files.filter(f => picks[f.index])
    readonly property real pickedBytes: pickedFiles.reduce((sum, f) => sum + f.length, 0)

    //: A file's path inside the torrent: its own top folder is the name already.
    function relative(path) {
        const top = String(entry.path || "") + "/"
        const base = String(entry.dir || "") + "/"
        if (path.indexOf(top) === 0)
            return path.slice(top.length)
        return path.indexOf(base) === 0 ? path.slice(base.length) : path
    }

    function load() {
        if (!service || !entry.key)
            return
        service.get("/api/history/" + encodeURIComponent(entry.key), (data, error) => {
                        if (!error)
                            detail.record = data
                    })
    }

    function togglePick(index) {
        const next = Object.assign({}, picks)
        if (next[index])
            delete next[index]
        else
            next[index] = true
        picks = next
    }

    function fetch(indices, label) {
        service.post("/api/history/fetch", {
                         "key": entry.key,
                         "indices": indices
                     }, label, () => {
                         detail.picks = ({})
                         service.loadHistory()
                     })
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

    // ---- a torrent: its files -------------------------------------------------
    StyledText {
        width: parent.width
        visible: detail.torrent && !!detail.record && detail.files.length === 0
        wrapMode: Text.WordWrap
        text: "Its file list was not recorded: it finished before this version of the manager kept one."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    Item {
        width: parent.width
        height: 26
        visible: detail.torrent && detail.files.length > 0

        StyledText {
            anchors.left: parent.left
            anchors.right: legend.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: detail.counts.done + " of " + detail.files.length + " files here" + (detail.counts.missing ? " · " + detail.counts.missing + " not on disk" : "")
                  + (detail.counts.skipped ? " · " + detail.counts.skipped + " skipped" : "")
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        Row {
            id: legend

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: 10

            Repeater {
                model: [["check_circle", "done", Theme.success], ["do_not_disturb_on", "skipped", Theme.outline], ["warning", "not on disk", Theme.warning]]

                Row {
                    id: legendItem

                    required property var modelData

                    spacing: 3

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: legendItem.modelData[0]
                        size: 14
                        color: legendItem.modelData[2]
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: legendItem.modelData[1]
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.outline
                    }
                }
            }
        }
    }

    Repeater {
        model: detail.torrent ? detail.files : []

        Item {
            id: fileRow

            required property var modelData
            readonly property string state: detail.fileState(modelData)
            readonly property bool picked: !!detail.picks[modelData.index]

            width: detail.width
            height: 34

            Rectangle {
                anchors.fill: parent
                radius: 8
                color: fileHover.hovered && fileRow.state !== "done" ? Theme.withAlpha(Theme.surfaceText, 0.05) : "transparent"
            }

            HoverHandler {
                id: fileHover
            }

            //: Done is a green check; skipped and missing are boxes to tick.
            Item {
                id: mark

                anchors.left: parent.left
                anchors.leftMargin: 6
                width: 28
                height: parent.height

                DankIcon {
                    anchors.centerIn: parent
                    visible: fileRow.state === "done"
                    name: "check_circle"
                    size: 20
                    color: Theme.success
                }

                Rectangle {
                    anchors.centerIn: parent
                    visible: fileRow.state !== "done"
                    width: 20
                    height: 20
                    radius: 5
                    color: fileRow.picked ? Theme.primary : "transparent"
                    border.width: fileRow.picked ? 0 : 2
                    border.color: fileRow.state === "missing" ? Theme.warning : Theme.outline

                    DankIcon {
                        anchors.centerIn: parent
                        visible: fileRow.picked
                        name: "check"
                        size: 16
                        color: Theme.onPrimary
                    }
                }
            }

            DankIcon {
                id: fileIcon

                anchors.left: mark.right
                anchors.leftMargin: 6
                anchors.verticalCenter: parent.verticalCenter
                name: Fmt.kindIcon(fileRow.modelData.path, false, false)
                size: 18
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.left: fileIcon.right
                anchors.leftMargin: 10
                anchors.right: note.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                text: detail.relative(fileRow.modelData.path)
                font.pixelSize: Theme.fontSizeSmall + 1
                color: fileRow.state === "missing" ? Theme.warning : (fileRow.state === "skipped" ? Theme.outline : Theme.surfaceText)
                wrapMode: Text.NoWrap
                elide: Text.ElideMiddle
            }

            StyledText {
                id: note

                anchors.right: fileSize.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: fileRow.state === "missing" ? "not on disk" : (fileRow.state === "skipped" ? "skipped" : "")
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.outline
            }

            StyledText {
                id: fileSize

                anchors.right: parent.right
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                width: 64
                horizontalAlignment: Text.AlignRight
                text: Fmt.bytes(fileRow.modelData.length)
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            MouseArea {
                anchors.fill: parent
                enabled: fileRow.state !== "done" && detail.magnet !== ""
                cursorShape: Qt.PointingHandCursor
                onClicked: detail.togglePick(fileRow.modelData.index)
            }
        }
    }

    // ---- fetch the picked ones ------------------------------------------------
    Item {
        width: parent.width
        height: 44
        visible: detail.torrent && detail.files.length > 0 && detail.counts.done < detail.files.length

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            color: Theme.outlineVariant
        }

        StyledText {
            anchors.left: parent.left
            anchors.right: moreButton.left
            anchors.rightMargin: 10
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 3
            text: detail.magnet === "" ? "No magnet link was recorded, so it cannot be added again."
                                       : detail.pickedFiles.length + " picked · " + Fmt.bytes(detail.pickedBytes) + " · into " + Fmt.homePath(detail.entry.path || detail.folder, detail.home)
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideMiddle
        }

        PillButton {
            id: moreButton

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.verticalCenterOffset: 3
            size: 36
            kind: "filled"
            icon: "download"
            text: "Download " + detail.pickedFiles.length + " more"
            enabled: detail.pickedFiles.length > 0 && detail.magnet !== ""
            onClicked: detail.fetch(detail.pickedFiles.map(f => f.index), "Fetching " + detail.pickedFiles.length + " more")
        }
    }
}
