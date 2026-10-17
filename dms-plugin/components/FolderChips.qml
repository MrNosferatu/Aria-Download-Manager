import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

//: "Save to" as one tap (Revision 2, board 5): Auto · by type first when the
//: links mix types, then the download folder, each type's folder, and "Other
//: folder…", the system chooser. `path` is "auto" or an absolute path; the
//: row wraps rather than squeezing a chip down to its icon.
Flow {
    id: chips

    //: GET /api/folders: {base, sorting, presets: [{label, path, category}], extensions}
    property var info: ({})
    property string path: ""
    property string home: ""
    //: The links are of more than one type: offer Auto · by type.
    property bool autoOffered: false

    //: The folder picked ("auto" for by type); the owner stores it and hands
    //: it back as `path`.
    signal chosen(string chosenPath)

    readonly property var presets: (info.presets || []).filter(p => p.path !== info.base)
    readonly property bool custom: path !== "" && path !== "auto" && !presets.some(p => p.path === path) && path !== info.base
    readonly property var categoryIcons: ({
                                              "archive": "folder_zip",
                                              "music": "music_note",
                                              "video": "movie",
                                              "image": "image"
                                          })

    function shortPath(p) {
        const text = String(p || "")
        return home && text.indexOf(home) === 0 ? "~" + text.slice(home.length) : text
    }

    function pick() {
        const start = chips.custom ? chips.path : (chips.info.base || "")
        const args = ["zenity", "--file-selection", "--directory", "--title=Choose a download folder"]
        if (start)
            args.push("--filename=" + start.replace(/\/*$/, "/"))
        Proc.runCommand("ariaDownloadManager.folderChips", args, (stdout, exitCode) => {
                            if (exitCode === 0 && stdout.trim())
                                chips.chosen(stdout.trim())
                        }, 0)
    }

    spacing: 6

    component Chip: Rectangle {
        id: chip

        property string label: ""
        property string icon: ""
        property bool selected: false

        signal activated

        width: chipRow.implicitWidth + 22
        height: 34
        radius: 17
        color: selected ? Theme.primaryContainer : (chipArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent")
        border.width: selected ? 0 : 1
        border.color: Theme.outlineVariant

        Row {
            id: chipRow

            anchors.centerIn: parent
            spacing: 6

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: chip.icon !== ""
                name: chip.icon
                size: 16
                color: chip.selected ? Theme.onPrimaryContainer : Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                // A picked folder can be a long path: keep its start and end.
                width: Math.min(implicitWidth, 280)
                wrapMode: Text.NoWrap
                elide: Text.ElideMiddle
                text: chip.label
                font.pixelSize: Theme.fontSizeSmall + 1
                font.weight: chip.selected ? Font.DemiBold : Font.Medium
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

    Chip {
        visible: chips.autoOffered
        icon: "auto_awesome"
        label: "Auto · by type"
        selected: chips.path === "auto"
        onActivated: chips.chosen("auto")
    }

    Chip {
        icon: "home"
        label: chips.shortPath(chips.info.base || "Download folder")
        selected: chips.path === chips.info.base
        onActivated: chips.chosen(chips.info.base || "")
    }

    Repeater {
        model: chips.presets

        Chip {
            required property var modelData

            icon: chips.categoryIcons[modelData.category] || "folder"
            label: modelData.label
            selected: chips.path === modelData.path
            onActivated: chips.chosen(modelData.path)
        }
    }

    //: Anything else: the chooser. Once used, it shows the folder it picked.
    Chip {
        icon: "create_new_folder"
        label: chips.custom ? chips.shortPath(chips.path) : "Other folder…"
        selected: chips.custom
        onActivated: chips.pick()
    }
}
