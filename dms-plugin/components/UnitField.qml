import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Units.js" as Units

// A speed or a size as a number and a unit, instead of a text box of bytes.
// `raw` goes in (bytes or aria2 shorthand, "" when unset); `value` comes out as
// bytes, and `edited` fires whenever the user changes it. An untouched field
// gives back exactly `raw`, so rounding for display never counts as an edit.
// Drawn as the boards' filled field: the number, then the unit as a small
// menu at the right end ("2  MiB/s ▾").
Rectangle {
    id: field

    //: "speed" or "size".
    property string kind: "speed"
    property string raw: ""
    property string placeholderText: kind === "speed" ? "No limit" : "0"
    //: Shown in front of a value once there is one ("Speed limit: 2"), so a
    //: filled-in form still says which field is which.
    property string label: ""
    //: Board 6's form: the number in its own small box, right-aligned, and
    //: the unit in a second box beside it.
    property bool split: false
    //: The box's tone; one step darker than whatever card it sits on.
    property color fill: Theme.surfaceContainerHigh

    property string _startAmount: ""
    property int _startUnit: Units.DEFAULT_UNIT
    property int _unit: Units.DEFAULT_UNIT
    //: Set while the field loads a value, so that is not taken for typing.
    property bool _loading: false

    readonly property string value: {
        if (amountInput.text.trim() === _startAmount && _unit === _startUnit)
            return raw
        return Units.join(amountInput.text, _unit, kind, raw)
    }

    signal edited(string value)

    implicitHeight: 36
    implicitWidth: split ? 64 + 6 + unitButton.width : 200
    height: implicitHeight
    radius: 10
    color: split ? "transparent" : field.fill
    border.width: amountInput.activeFocus && !split ? 1 : 0
    border.color: Theme.primary

    Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        width: 64
        visible: field.split
        radius: 10
        color: field.fill
        border.width: amountInput.activeFocus ? 1 : 0
        border.color: Theme.primary
    }

    function load() {
        const parts = Units.split(field.raw, field.kind)
        field._loading = true
        field._startAmount = parts.amount
        field._startUnit = parts.unit
        field._unit = parts.unit
        amountInput.text = parts.amount
        field._loading = false
    }

    onRawChanged: load()
    onKindChanged: load()
    Component.onCompleted: load()

    StyledText {
        id: prefix

        anchors.left: parent.left
        anchors.leftMargin: 10
        anchors.verticalCenter: parent.verticalCenter
        visible: field.label !== "" && amountInput.text.trim() !== ""
        text: field.label + ":"
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }

    TextInput {
        id: amountInput

        anchors.left: prefix.visible ? prefix.right : parent.left
        anchors.leftMargin: prefix.visible ? 5 : 10
        anchors.right: unitButton.left
        anchors.rightMargin: field.split ? 16 : 6
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: field.split ? TextInput.AlignRight : TextInput.AlignLeft
        color: Theme.surfaceText
        selectionColor: Theme.primarySelected
        selectByMouse: true
        clip: true
        font.pixelSize: Theme.fontSizeSmall
        font.family: Theme.fontFamily
        onTextChanged: {
            if (!field._loading)
                field.edited(field.value)
        }
        // Shorthand typed into the box ("12M") is shown back as number + unit.
        onEditingFinished: {
            if (!/[a-z]/i.test(text))
                return
            const parts = Units.split(text, field.kind)
            if (parts.amount === "" && text.trim() !== "")
                return
            field._unit = parts.unit
            text = parts.amount
        }

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: amountInput.text.length === 0
            horizontalAlignment: field.split ? Text.AlignRight : Text.AlignLeft
            text: field.placeholderText
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.outline
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }
    }

    Rectangle {
        id: unitButton

        anchors.right: parent.right
        anchors.rightMargin: field.split ? 0 : 4
        anchors.verticalCenter: parent.verticalCenter
        width: unitRow.implicitWidth + (field.split ? 18 : 12)
        height: field.split ? parent.height : parent.height - 8
        radius: field.split ? 10 : 8
        color: field.split ? (unitArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.10) : field.fill)
                           : (unitArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.08) : "transparent")

        Row {
            id: unitRow

            anchors.centerIn: parent
            spacing: 0

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: Units.labels(field.kind)[field._unit]
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "arrow_drop_down"
                size: 18
                color: Theme.surfaceVariantText
            }
        }

        MouseArea {
            id: unitArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: unitMenu.toggle()
        }

        MenuPopup {
            id: unitMenu

            alignEnd: true
            menuWidth: 120
            entries: Units.labels(field.kind).map((label, index) => ({
                                                                         "text": label,
                                                                         "checked": index === field._unit
                                                                     }))
            onTriggered: index => {
                if (index === field._unit)
                    return
                field._unit = index
                field.edited(field.value)
            }
        }
    }
}
