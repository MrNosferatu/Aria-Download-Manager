import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/Units.js" as Units

// One aria2 global option as a row of the boards' settings cards (8 and 19):
// what it is on the left — a label, and under it the aria2 key or one grey
// line saying what it does — and the control on the right, with a dot and a
// reset once it is edited. `kind` is "text", "number", "stepper", "bool" or
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
    //: Bounds for a stepper; 0 as the maximum means none.
    property int minimum: 0
    property int maximum: 0
    //: Show the aria2 option name under a friendly label.
    property bool showKey: false
    //: The search words, marked in the label and the key.
    property string highlight: ""
    //: Changing this puts the field back to `original` — the tab's Discard.
    property int resetToken: 0
    //: A hairline above the row, between it and the one before.
    property bool divider: false
    //: The key is the label (every-option rows): set in monospace.
    property bool monoLabel: false

    //: Back to the saved value. The editors keep their own text once typed
    //: into, so they are rebuilt rather than told.
    function reset() {
        field.value = field.original
        editor.active = false
        editor.active = true
    }

    onResetTokenChanged: reset()

    //: The match gets a soft mark behind it, as board 19 draws it.
    function marked(text) {
        const plain = String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;")
        if (!field.highlight)
            return plain
        for (const needle of Fmt.searchForms(field.highlight)) {
            const at = plain.toLowerCase().indexOf(needle)
            if (at >= 0)
                return plain.slice(0, at) + "<span style=\"background-color:" + Theme.outlineVariant + "\">" + plain.slice(at, at + needle.length)
                        + "</span>" + plain.slice(at + needle.length)
        }
        return plain
    }

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

    implicitHeight: Math.max(52, textColumn.implicitHeight + 20)
    height: implicitHeight

    onValueChanged: field.edited(field.optionKey, field.value)
    // A reload re-seeds the field; typing breaks the binding on purpose.
    onOriginalChanged: field.value = field.original

    Rectangle {
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        height: 1
        visible: field.divider
        color: Theme.outlineVariant
        opacity: 0.6
    }

    Column {
        id: textColumn

        anchors.left: parent.left
        anchors.right: controls.left
        anchors.rightMargin: 12
        anchors.verticalCenter: parent.verticalCenter
        spacing: 2

        StyledText {
            width: parent.width
            text: field.marked(field.label)
            textFormat: field.highlight ? Text.RichText : Text.PlainText
            font.pixelSize: field.monoLabel ? Theme.fontSizeSmall + 1 : Theme.fontSizeMedium
            font.weight: field.monoLabel ? Font.Bold : Font.DemiBold
            font.family: field.monoLabel ? "monospace" : Theme.fontFamily
            color: Theme.surfaceText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            visible: field.showKey && field.label !== field.optionKey
            text: field.marked(field.optionKey)
            textFormat: field.highlight ? Text.RichText : Text.PlainText
            font.pixelSize: Theme.fontSizeSmall - 1
            font.family: "monospace"
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        StyledText {
            width: parent.width
            visible: field.description !== ""
            text: field.description
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
            maximumLineCount: 3
            elide: Text.ElideRight
        }
    }

    Row {
        id: controls

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        spacing: 8

        Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            width: 6
            height: 6
            radius: 3
            color: Theme.primary
            visible: field.dirty
        }

        Loader {
            id: editor

            anchors.verticalCenter: parent.verticalCenter
            sourceComponent: {
                if (field.isDirectory)
                    return directoryComponent
                if (field.unitKind !== "")
                    return unitComponent
                if (field.isBool)
                    return boolComponent
                if (field.kind === "stepper")
                    return stepperComponent
                if (field.isChoice)
                    return choiceComponent
                return field.kind === "number" ? numberComponent : textComponent
            }
        }

        //: Back to what is saved, for this one option.
        DankActionButton {
            anchors.verticalCenter: parent.verticalCenter
            visible: field.dirty
            buttonSize: 30
            iconSize: 16
            iconName: "undo"
            iconColor: Theme.surfaceVariantText
            tooltipText: "Back to " + (field.original === "" ? "not set" : field.original)
            onClicked: field.reset()
        }
    }

    Component {
        id: textComponent

        FillField {
            width: Math.min(240, Math.max(140, field.width * 0.42))
            text: field.value
            placeholderText: "not set"
            onTextChanged: field.value = text
        }
    }

    Component {
        id: numberComponent

        FillField {
            width: 64
            alignment: TextInput.AlignRight
            text: field.value
            placeholderText: "0"
            onTextChanged: field.value = text.trim()
        }
    }

    //: − count +, for the small integers: downloads at once, connections, parts.
    Component {
        id: stepperComponent

        Stepper {
            value: field.value
            minimum: field.minimum
            maximum: field.maximum
            onEdited: newValue => field.value = newValue
        }
    }

    Component {
        id: unitComponent

        UnitField {
            kind: field.unitKind
            raw: field.original
            split: true
            placeholderText: field.unitKind === "speed" ? "none" : "0"
            onEdited: newValue => field.value = newValue
        }
    }

    Component {
        id: directoryComponent

        DirectoryField {
            objectName: field.optionKey
            width: Math.max(200, field.width * 0.6)
            placeholderText: field.optionKey
            text: field.value
            onTextChanged: field.value = text
        }
    }

    Component {
        id: boolComponent

        //: aria2 does not report every option, and an unset one must not be
        //: written out as an explicit false just because it rendered. It
        //: stays marked "not set" until the switch is actually touched.
        Row {
            spacing: 8

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: field.value === ""
                text: "Not set"
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }

            BoolSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: field.value === "true"
                onToggled: value => field.value = value ? "true" : "false"
            }
        }
    }

    Component {
        id: choiceComponent

        Rectangle {
            id: choice

            width: choiceRow.implicitWidth + 20
            height: 36
            radius: 10
            color: choiceArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

            Row {
                id: choiceRow

                anchors.centerIn: parent
                spacing: 2

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: field.value === "" ? "Not set" : field.value
                    font.pixelSize: Theme.fontSizeSmall
                    color: field.value === "" ? Theme.surfaceVariantText : Theme.surfaceText
                }

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "arrow_drop_down"
                    size: 18
                    color: Theme.surfaceVariantText
                }
            }

            MouseArea {
                id: choiceArea

                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: choiceMenu.toggle()
            }

            MenuPopup {
                id: choiceMenu

                alignEnd: true
                menuWidth: 160
                entries: ["Not set"].concat(field.choices).map(c => ({
                                                                         "text": c,
                                                                         "checked": (c === "Not set" ? "" : c) === field.value
                                                                     }))
                onTriggered: index => field.value = index === 0 ? "" : field.choices[index - 1]
            }
        }
    }
}
