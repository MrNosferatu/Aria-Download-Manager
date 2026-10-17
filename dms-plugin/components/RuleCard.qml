import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Rules.js" as Rules

//: One automatic action in the list (Revision 2, board 1): its on/off switch,
//: its name and what it does in words. Clicking it opens the editor
//: (RuleEditor); right-click offers Edit, Duplicate and Delete.
Rectangle {
    id: card

    property var rule: ({})
    //: Marked as the one being edited beside the list.
    property bool current: false

    signal removed
    signal toggleOpen
    signal duplicated
    //: The switch: saved at once by the tab, never part of the unsaved edits.
    signal enabledToggled(bool value)

    readonly property bool on: card.rule.enabled !== false
    readonly property string summary: Rules.summary(card.rule)

    height: Math.max(64, folded.height + 20)
    radius: 14
    color: Theme.surfaceContainer
    border.width: current ? 1 : 0
    border.color: Theme.primary

    Item {
        id: body

        anchors.fill: parent
        anchors.leftMargin: 14
        anchors.rightMargin: 12

        // ---- folded: the switch, the name, what it does (board 1) ---------
        Item {
            id: folded

            width: parent.width
            height: Math.max(40, foldedText.implicitHeight)
            anchors.verticalCenter: parent.verticalCenter

            //: Click opens it, right-click offers the rest; the switch and
            //: the chevron sit above this and take their own clicks.
            MouseArea {
                id: foldedArea

                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        const at = foldedArea.mapToItem(rowMenu.parent, mouse.x, mouse.y)
                        rowMenu.openAt(at.x, at.y)
                    } else {
                        card.toggleOpen()
                    }
                }
            }

            BoolSwitch {
                id: rowSwitch

                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 52
                height: 32
                checked: card.on
                onToggled: value => card.enabledToggled(value)
            }

            Column {
                id: foldedText

                anchors.left: rowSwitch.right
                anchors.leftMargin: 14
                anchors.right: foldedChevron.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3

                Row {
                    width: parent.width
                    spacing: 8

                    StyledText {
                        id: foldedName

                        width: Math.min(implicitWidth, parent.width - (offTag.visible ? offTag.width + 8 : 0))
                        anchors.verticalCenter: parent.verticalCenter
                        text: card.rule.name || "Unnamed action"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: card.on ? Theme.surfaceText : Theme.outline
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }

                    //: Said in words as well as by the dimming.
                    Rectangle {
                        id: offTag

                        anchors.verticalCenter: parent.verticalCenter
                        visible: !card.on
                        width: offText.implicitWidth + 16
                        height: 20
                        radius: 10
                        color: Theme.surfaceContainerHighest

                        StyledText {
                            id: offText

                            anchors.centerIn: parent
                            text: "Off"
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: card.summary
                    font.pixelSize: Theme.fontSizeSmall
                    color: card.on ? Theme.surfaceVariantText : Theme.withAlpha(Theme.surfaceVariantText, 0.55)
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }
            }

            DankIcon {
                id: foldedChevron

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron_right"
                size: 22
                color: Theme.outline
            }

            MenuPopup {
                id: rowMenu

                parent: foldedChevron
                menuWidth: 180
                entries: [{
                        "icon": "edit",
                        "text": "Edit"
                    }, {
                        "icon": "content_copy",
                        "text": "Duplicate"
                    }, {
                        "separator": true
                    }, {
                        "icon": "delete",
                        "text": "Delete",
                        "danger": true
                    }]
                onTriggered: index => {
                    if (index === 0)
                        card.toggleOpen()
                    else if (index === 1)
                        card.duplicated()
                    else if (index === 3)
                        card.removed()
                }
            }
        }
    }
}
