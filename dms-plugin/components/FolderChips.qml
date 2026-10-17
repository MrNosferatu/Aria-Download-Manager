import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

//: "Save to" as one tap: Sort by type (when the manager sorts), the preset
//: folders, and the system chooser for anything else. `path` is "" for the
//: manager's choice — the download folder, or the type's folder when sorting
//: is on — and an absolute path otherwise.
Flow {
    id: chips

    //: GET /api/folders: {base, sorting, presets: [{label, path}], suggested}
    property var info: ({})
    property string path: ""
    //: Where the manager would put it, shown on the default chip.
    property string suggested: info.suggested || ""
    property string home: ""

    //: The folder picked; the owner stores it and hands it back as `path`.
    signal chosen(string chosenPath)

    readonly property var presets: (info.presets || []).filter(p => p.path !== info.base)
    readonly property bool custom: path !== "" && !presets.some(p => p.path === path) && path !== info.base

    function shortPath(p) {
        const text = String(p || "")
        return home && text.indexOf(home) === 0 ? "~" + text.slice(home.length) : text
    }

    function pick() {
        const start = chips.path || chips.info.base || ""
        const args = ["zenity", "--file-selection", "--directory", "--title=Choose a download folder"]
        if (start)
            args.push("--filename=" + start.replace(/\/*$/, "/"))
        Proc.runCommand("ariaDownloadManager.folderChips", args, (stdout, exitCode) => {
                            if (exitCode === 0 && stdout.trim())
                                chips.chosen(stdout.trim())
                        }, 0)
    }

    spacing: Theme.spacingXS

    component Chip: Rectangle {
        id: chip

        property string label: ""
        property string icon: ""
        property bool selected: false

        signal activated

        width: chipRow.implicitWidth + Theme.spacingM * 2
        height: 32
        radius: 16
        color: selected ? Theme.primaryContainer : (chipArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent")
        border.width: selected ? 0 : 1
        border.color: Theme.withAlpha(Theme.outline, 0.5)

        Row {
            id: chipRow

            anchors.centerIn: parent
            spacing: 5

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: chip.icon !== ""
                name: chip.icon
                size: 16
                color: chip.selected ? Theme.onPrimaryContainer : Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: chip.label !== ""
                // A picked folder can be a long path: keep its start and end.
                width: Math.min(implicitWidth, 280)
                wrapMode: Text.NoWrap
                elide: Text.ElideMiddle
                text: chip.label
                font.pixelSize: Theme.fontSizeSmall
                font.weight: chip.selected ? Font.Bold : Font.Medium
                color: chip.selected ? Theme.onPrimaryContainer : Theme.surfaceText
            }
        }

        MouseArea {
            id: chipArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: chip.activated()
        }
    }

    //: The manager's own choice: by type when sorting is on, otherwise the
    //: download folder.
    Chip {
        icon: chips.info.sorting ? "auto_awesome" : "folder"
        label: chips.info.sorting ? "Sort by type" + (chips.suggested ? " → " + chips.shortPath(chips.suggested) : "")
                                  : chips.shortPath(chips.info.base || "Download folder")
        selected: chips.path === "" || chips.path === chips.info.base
        onActivated: chips.chosen("")
    }

    Repeater {
        model: chips.presets

        Chip {
            required property var modelData

            label: modelData.label
            selected: chips.path === modelData.path
            onActivated: chips.chosen(modelData.path)
        }
    }

    //: Anything else: the chooser, which then shows the folder it picked.
    Chip {
        icon: "folder_open"
        label: chips.custom ? chips.shortPath(chips.path) : ""
        selected: chips.custom
        onActivated: chips.pick()
    }
}
