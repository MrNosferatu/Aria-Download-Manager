import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets

//: The manager as a normal, movable, resizable window. Same content as the bar
//: popout — it hosts the very same Aria2Popout — but it survives a click
//: elsewhere, which the layer-shell popout cannot.
DankFloatingWindow {
    id: win

    property var service: null

    signal dockRequested

    readonly property int titleBarHeight: 44
    readonly property int margin: Theme.spacingM

    function show() {
        visible = true
    }

    function hide() {
        visible = false
    }

    function toggle() {
        visible = !visible
    }

    title: "aria2c manager"
    minimumSize: Qt.size(520, 420)
    implicitWidth: 760
    implicitHeight: 860
    visible: false

    onClosed: win.visible = false

    Item {
        anchors.fill: parent

        Item {
            id: titleBar

            anchors.top: parent.top
            anchors.left: parent.left
            anchors.right: parent.right
            height: win.titleBarHeight
            z: 10

            MouseArea {
                anchors.fill: parent
                onPressed: windowControls.tryStartMove()
                onDoubleClicked: windowControls.tryToggleMaximize()
            }

            Row {
                anchors.left: parent.left
                anchors.leftMargin: Theme.spacingM
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingS

                DankIcon {
                    anchors.verticalCenter: parent.verticalCenter
                    name: "download"
                    size: Theme.iconSize - 2
                    color: Theme.primary
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    text: "aria2c manager"
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Medium
                    color: Theme.surfaceText
                }
            }

            Row {
                anchors.right: parent.right
                anchors.rightMargin: Theme.spacingS
                anchors.verticalCenter: parent.verticalCenter
                spacing: Theme.spacingXS

                ManagerActions {
                    anchors.verticalCenter: parent.verticalCenter
                    service: win.service
                    inWindow: true
                    onDockRequested: {
                        win.hide()
                        win.dockRequested()
                    }
                }

                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: windowControls.canMaximize
                    circular: false
                    iconName: win.maximized ? "fullscreen_exit" : "fullscreen"
                    iconSize: Theme.iconSize - 4
                    iconColor: Theme.surfaceText
                    onClicked: windowControls.tryToggleMaximize()
                }

                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    circular: false
                    iconName: "close"
                    iconSize: Theme.iconSize - 4
                    iconColor: Theme.surfaceText
                    onClicked: win.hide()
                }
            }
        }

        Item {
            id: body

            anchors.top: titleBar.bottom
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: win.margin
            anchors.rightMargin: win.margin
            anchors.bottomMargin: win.margin

            Aria2Popout {
                id: popout

                width: body.width
                service: win.service
                inWindow: true
                hostVisible: win.visible
                // The window owns its height, so the tab area takes whatever is
                // left once the header, stats and tab bar have had their share.
                contentHeight: Math.max(200, body.height - chromeHeight)
            }
        }
    }

    FloatingWindowControls {
        id: windowControls

        targetWindow: win
    }
}
