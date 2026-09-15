import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Units.js" as Units

// One aria2 global option. `kind` is "text", "number", "bool" or
// "select:a,b,c", matching the manager page's option table.
Item {
    id: field

    property string optionKey: ""
    property string label: ""
    property string kind: "text"
    //: One plain line saying what the option does. Same text the manager page shows.
    property string description: ""
    property string original: ""
    property string value: ""

    //: By value: "32M" and "33554432" are the same setting.
    readonly property bool dirty: !Units.same(value, original)
    readonly property bool isBool: kind === "bool"
    //: A real choice between named values. A boolean is not one of these — it
    //: gets a switch, the same as every other yes/no in the product.
    readonly property bool isChoice: kind.indexOf("select:") === 0
    // aria2's dir is a path, so it gets the folder chooser rather than a bare
    // text box.
    readonly property bool isDirectory: optionKey === "dir"
    //: "speed" or "size" for an option measured in bytes; they get a number and
    //: a unit instead of a text box of bytes.
    readonly property string unitKind: Units.kindFor(optionKey)
    readonly property var choices: {
        if (kind.indexOf("select:") === 0)
            return kind.substring(7).split(",")
        return []
    }

    signal edited(string key, string newValue)

    //: Driven by the content, not guessed at. The Column used to be anchored to
    //: fill this Item while the Item's height was a hand-written formula, so any
    //: row whose description wrapped overflowed into the row below it.
    implicitHeight: layout.implicitHeight
    height: implicitHeight

    onValueChanged: field.edited(field.optionKey, field.value)
    // A reload re-seeds the field; typing breaks the binding on purpose.
    onOriginalChanged: field.value = field.original

    Column {
        id: layout

        width: parent.width
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

        StyledText {
            id: descriptionText

            width: parent.width
            visible: field.description !== ""
            text: field.description
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }

        Loader {
            width: parent.width
            height: 40
            sourceComponent: {
                if (field.isDirectory)
                    return directoryComponent
                if (field.unitKind !== "")
                    return unitComponent
                if (field.isBool)
                    return boolComponent
                return field.isChoice ? choiceComponent : textComponent
            }
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
        id: unitComponent

        UnitField {
            kind: field.unitKind
            raw: field.original
            onEdited: newValue => field.value = newValue
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
        id: boolComponent

        Item {
            //: aria2 does not report every option, and an unset one must not be
            //: written out as an explicit false just because it rendered. It
            //: stays marked "not set" until the switch is actually touched.
            Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                BoolSwitch {
                    anchors.verticalCenter: parent.verticalCenter
                    checked: field.value === "true"
                    onToggled: value => field.value = value ? "true" : "false"
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: field.value === ""
                    text: "Not set"
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                }
            }
        }
    }

    Component {
        id: choiceComponent

        DankDropdown {
            height: 40
            currentValue: field.value === "" ? "Not set" : field.value
            options: ["Not set"].concat(field.choices)
            compactMode: true
            onValueChanged: newValue => field.value = (newValue === "Not set" ? "" : newValue)
        }
    }
}
