import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Units.js" as Units

// A speed or a size as a number and a unit, instead of a text box of bytes.
// `raw` goes in (bytes or aria2 shorthand, "" when unset); `value` comes out as
// bytes, and `edited` fires whenever the user changes it. An untouched field
// gives back exactly `raw`, so rounding for display never counts as an edit.
Item {
    id: field

    //: "speed" or "size".
    property string kind: "speed"
    property string raw: ""
    property string placeholderText: kind === "speed" ? "no limit" : "0"

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

    implicitHeight: 40
    height: implicitHeight

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

    DankTextField {
        id: amountInput

        anchors.left: parent.left
        anchors.right: unitPicker.left
        anchors.rightMargin: Theme.spacingXS
        height: 40
        font.pixelSize: Theme.fontSizeSmall
        placeholderText: field.placeholderText
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
    }

    DankDropdown {
        id: unitPicker

        anchors.right: parent.right
        compactMode: true
        dropdownWidth: 96
        options: Units.labels(field.kind)
        currentValue: Units.labels(field.kind)[field._unit]
        onValueChanged: newValue => {
            const index = Units.labels(field.kind).indexOf(newValue)
            if (index < 0 || index === field._unit)
                return
            field._unit = index
            field.edited(field.value)
        }
    }
}
