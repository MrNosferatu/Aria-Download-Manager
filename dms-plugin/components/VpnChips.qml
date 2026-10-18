import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Vpn.js" as Vpn

//: The VPN for the links being added (the manager's vpn.py): By site, each
//: link by whether its site is on the list; VPN, all of them through it; or
//: Direct. A line under the chips says what that comes to. Shown by the add
//: panel while the VPN is on in Settings.
Column {
    id: chips

    //: The links it could carry (no torrents: they always go direct).
    property var links: []
    property bool torrentsToo: false
    property var sites: []
    //: "auto", "on" or "off".
    property string choice: "auto"

    signal chosen(string value)

    readonly property int caught: Vpn.vpnCountOnList(links, sites)
    readonly property string hint: {
        const one = links.length === 1
        let text
        if (choice === "on")
            text = one ? "Uses the VPN, regardless of the site list." : "All " + links.length + " use the VPN, regardless of the site list."
        else if (choice === "off")
            text = one ? "Connects directly, regardless of the site list." : "All " + links.length + " connect directly, regardless of the site list."
        else if (one)
            text = Vpn.vpnHostOf(links[0]) + (caught ? " is on the VPN site list, so it will use the VPN." : " isn’t on the VPN site list, so it will connect directly.")
        else
            text = caught + " of " + links.length + " will use the VPN, based on the site list."
        return text + (torrentsToo ? " Torrents always connect directly." : "")
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
                name: chip.icon
                size: 16
                color: chip.selected ? Theme.onPrimaryContainer : Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
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

    Flow {
        width: parent.width
        spacing: 6

        Repeater {
            model: [["auto", "auto_awesome", "By site"], ["on", "shield", "VPN"], ["off", "link", "Direct"]]

            Chip {
                required property var modelData

                icon: modelData[1]
                label: modelData[2]
                selected: chips.choice === modelData[0]
                onActivated: chips.chosen(modelData[0])
            }
        }
    }

    StyledText {
        width: parent.width
        text: chips.hint
        wrapMode: Text.WordWrap
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
    }
}
