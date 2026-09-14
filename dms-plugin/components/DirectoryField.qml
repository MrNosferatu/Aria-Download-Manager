import QtQuick
import qs.Common
import qs.Services
import qs.Widgets

// A path field with a real folder chooser beside it. The path stays editable by
// hand — the picker is a convenience, not the only way in.
Item {
    id: field

    property alias text: input.text
    property string placeholderText: "(default)"
    property string dialogTitle: "Choose a download directory"
    property string startDir: ""

    implicitHeight: 40
    height: implicitHeight

    function pick() {
        // zenity is the one GTK/Qt-agnostic chooser that is present on a stock
        // desktop; the field stays usable by typing if it is missing.
        const start = field.startDir || field.text || ""
        const args = ["zenity", "--file-selection", "--directory", "--title=" + field.dialogTitle]
        if (start)
            args.push("--filename=" + start.replace(/\/*$/, "/"))
        Proc.runCommand("ariaDownloadManager.pickDir." + field.objectName, args, (stdout, exitCode) => {
                            if (exitCode !== 0)
                                return   // cancelled
                            const path = stdout.trim()
                            if (path)
                                field.text = path
                        }, 0)
    }

    DankTextField {
        id: input

        anchors.left: parent.left
        anchors.right: browseButton.left
        anchors.rightMargin: Theme.spacingXS
        anchors.verticalCenter: parent.verticalCenter
        height: parent.height
        leftIconName: "folder"
        placeholderText: field.placeholderText
    }

    DankActionButton {
        id: browseButton

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        buttonSize: parent.height
        iconSize: Theme.iconSizeSmall
        iconName: "folder_open"
        tooltipText: "Browse…"
        backgroundColor: Theme.surfaceContainerHigh
        circular: false
        onClicked: field.pick()
    }
}
