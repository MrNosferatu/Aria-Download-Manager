import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Fmt.js" as Fmt

//: A speed as a number and a unit in one bordered box (board 2): "125 | KiB/s ▾".
//: `raw` is bytes per second (or aria2 shorthand such as "2M"); `edited`
//: gives bytes back, "" when emptied, or the text itself when it is not a
//: number, so the field can be marked.
FormBox {
    id: field

    property var raw: ""
    property string placeholderText: ""

    signal edited(var raw)

    readonly property var units: [["KiB/s", 1024], ["MiB/s", 1048576]]
    readonly property var bytes: raw === "" || raw === undefined || raw === null ? null : Fmt.parseSize(String(raw))
    //: The unit the value reads best in, unless one was picked from the menu.
    property int pickedUnit: -1
    readonly property int unit: pickedUnit >= 0 ? pickedUnit : (bytes !== null && bytes >= 1048576 ? 1 : 0)
    readonly property string shown: {
        if (raw === "" || raw === undefined || raw === null)
            return ""
        if (bytes === null)
            return String(raw)
        return String(Number((bytes / units[unit][1]).toFixed(2)))
    }

    function send(text, unitIndex) {
        const t = String(text).trim()
        if (t === "")
            field.edited("")
        else if (isFinite(Number(t)))
            field.edited(Math.round(Number(t) * units[unitIndex][1]))
        else
            field.edited(t)
    }

    implicitWidth: 152
    width: implicitWidth
    focused: input.activeFocus || unitMenu.opened

    onShownChanged: {
        if (!input.activeFocus || Number(input.text) !== Number(shown) || input.text.trim() === "")
            input.text = shown
    }
    Component.onCompleted: input.text = shown

    TextInput {
        id: input

        anchors.left: parent.left
        anchors.right: divider.left
        anchors.leftMargin: 10
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        horizontalAlignment: TextInput.AlignRight
        color: field.invalid ? Theme.error : Theme.surfaceText
        selectionColor: Theme.primarySelected
        selectByMouse: true
        clip: true
        font.pixelSize: Theme.fontSizeMedium
        font.weight: Font.DemiBold
        onTextEdited: field.send(text, field.unit)

        StyledText {
            anchors.verticalCenter: parent.verticalCenter
            width: parent.width
            visible: input.text.length === 0
            horizontalAlignment: Text.AlignRight
            text: field.placeholderText
            font.pixelSize: Theme.fontSizeSmall + 1
            color: Theme.outline
        }
    }

    Rectangle {
        id: divider

        anchors.right: unitButton.left
        anchors.verticalCenter: parent.verticalCenter
        width: 1
        height: 20
        color: Theme.outlineVariant
    }

    Item {
        id: unitButton

        anchors.right: parent.right
        width: unitRow.implicitWidth + 12
        height: parent.height

        Row {
            id: unitRow

            anchors.centerIn: parent
            spacing: 0

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: field.units[field.unit][0]
                font.pixelSize: Theme.fontSizeSmall + 1
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
            anchors.fill: parent
            cursorShape: Qt.PointingHandCursor
            onClicked: unitMenu.toggle()
        }

        //: A new unit reinterprets the number rather than converting it:
        //: "125" stays 125, now in MiB/s.
        MenuPopup {
            id: unitMenu

            alignEnd: true
            menuWidth: 120
            entries: field.units.map((u, i) => ({
                                                    "text": u[0],
                                                    "checked": i === field.unit
                                                }))
            onTriggered: index => {
                field.pickedUnit = index
                if (input.text.trim() !== "")
                    field.send(input.text, index)
            }
        }
    }
}
