import QtQuick
import qs.Common
import qs.Widgets

// One aria2 global option. `kind` is "text", "number", "bool" or
// "select:a,b,c", matching the web UI's option table.
Item {
    id: field

    property string optionKey: ""
    property string label: ""
    property string kind: "text"
    property string original: ""
    property string value: ""

    readonly property bool dirty: value !== original
    readonly property bool isChoice: kind === "bool" || kind.indexOf("select:") === 0
    // aria2's dir is a path, so it gets the folder chooser rather than a bare
    // text box.
    readonly property bool isDirectory: optionKey === "dir"
    readonly property var choices: {
        if (kind === "bool")
            return ["true", "false"]
        if (kind.indexOf("select:") === 0)
            return kind.substring(7).split(",")
        return []
    }

    signal edited(string key, string newValue)

    implicitHeight: 60
    height: implicitHeight

    onValueChanged: field.edited(field.optionKey, field.value)
    // A reload re-seeds the field; typing breaks the binding on purpose.
    onOriginalChanged: field.value = field.original

    Column {
        anchors.fill: parent
        spacing: 2

        Row {
            width: parent.width
            spacing: Theme.spacingXS

            StyledText {
                text: field.label
                font.pixelSize: Theme.fontSizeSmall
                color: field.dirty ? Theme.primary : Theme.surfaceVariantText
                elide: Text.ElideRight
                width: Math.max(0, Math.min(implicitWidth, parent.width - 8))
            }

            Rectangle {
                anchors.verticalCenter: parent.verticalCenter
                width: 6
                height: 6
                radius: 3
                color: Theme.primary
                visible: field.dirty
            }
        }

        Loader {
            width: parent.width
            height: 40
            sourceComponent: field.isDirectory ? directoryComponent
                                              : (field.isChoice ? choiceComponent : textComponent)
        }
    }

    Component {
        id: textComponent

        DankTextField {
            height: 40
            text: field.value
            placeholderText: field.optionKey
            font.pixelSize: Theme.fontSizeSmall
            onTextChanged: field.value = text
        }
    }

    Component {
        id: directoryComponent

        DirectoryField {
            objectName: field.optionKey
            implicitHeight: 32
            placeholderText: field.optionKey
            text: field.value
            onTextChanged: field.value = text
        }
    }

    Component {
        id: choiceComponent

        DankDropdown {
            height: 40
            currentValue: field.value === "" ? "(unset)" : field.value
            options: ["(unset)"].concat(field.choices)
            compactMode: true
            onValueChanged: newValue => field.value = (newValue === "(unset)" ? "" : newValue)
        }
    }
}
