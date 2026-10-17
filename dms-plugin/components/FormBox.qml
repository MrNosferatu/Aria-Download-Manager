import QtQuick
import qs.Common

//: The action editor's field (Revision 2, board 2): a bordered box that reads
//: as editable before it is touched. A brighter outline on hover, two pixels
//: of accent on focus; a changed value gets an accent border and a tinted
//: fill, an invalid one an error border. The control goes inside.
Rectangle {
    id: box

    //: Differs from the saved value.
    property bool changed: false
    property bool invalid: false
    //: Set by the control inside while it has the keyboard.
    property bool focused: false

    default property alias content: inner.data

    implicitHeight: 36
    height: implicitHeight
    radius: 10
    color: box.changed ? Theme.withAlpha(Theme.primary, 0.10) : Theme.surfaceContainerLow
    border.width: box.focused ? 2 : 1
    border.color: {
        if (box.invalid)
            return Theme.error
        if (box.focused || box.changed)
            return Theme.primary
        return hover.hovered ? Theme.outline : Theme.outlineVariant
    }

    HoverHandler {
        id: hover
    }

    Item {
        id: inner

        anchors.fill: parent
    }
}
