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
    //: Wide enough for a rail, the list and a detail pane side by side;
    //: narrower, the window shows the popout's layout.
    readonly property bool wideLayout: body.width >= 900

    function show() {
        visible = true
    }

    function hide() {
        visible = false
    }

    function toggle() {
        visible = !visible
    }

    //: Fills the screen, or puts the window back. niri ignores a floating
    //: window's own maximize request, so the manager asks the compositor; the
    //: plain request is the fallback where it cannot.
    property bool filled: false

    function toggleMaximize() {
        if (!service || !service.connected) {
            windowControls.tryToggleMaximize()
            return
        }
        service.request("POST", "/api/window/maximize", {
                            "title": win.title,
                            "exact": true
                        }, (data, error) => {
                            if (error || !data || !data.by) {
                                windowControls.tryToggleMaximize()
                                return
                            }
                            if (data.maximized !== null && data.maximized !== undefined)
                                win.filled = data.maximized
                            else
                                win.filled = !win.filled
                        })
    }

    title: "Aria Download Manager"
    minimumSize: Qt.size(520, 420)
    implicitWidth: 1120
    implicitHeight: 820
    visible: false

    onClosed: win.visible = false
    //: On niri / Hyprland a new window tiles; the manager asks the compositor to
    //: float this one (desktop.float_windows), so no window rule is needed.
    onVisibleChanged: {
        // A reopened window comes back at its normal size.
        if (!visible)
            filled = false
        if (visible && service)
            service.request("POST", "/api/window/float", {
                                "title": win.title,
                                "exact": true,
                                "width": win.implicitWidth,
                                "height": win.implicitHeight
                            })
    }

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
                onDoubleClicked: win.toggleMaximize()
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
                    text: "Aria Download Manager"
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
                    iconName: win.filled || win.maximized ? "fullscreen_exit" : "fullscreen"
                    iconSize: Theme.iconSize - 4
                    iconColor: Theme.surfaceText
                    tooltipText: win.filled || win.maximized ? "Restore size" : "Fill the screen"
                    onClicked: win.toggleMaximize()
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

            Loader {
                anchors.fill: parent
                active: win.wideLayout

                sourceComponent: WideManager {
                    service: win.service
                    hostVisible: win.visible
                }
            }

            Aria2Popout {
                id: popout

                width: body.width
                visible: !win.wideLayout
                service: win.service
                inWindow: true
                hostVisible: win.visible && !win.wideLayout
                // The window owns its height, so the tab area takes whatever is
                // left once the header, stats and tab bar have had their share.
                contentHeight: Math.max(200, body.height - chromeHeight)
            }
        }
    }

    FloatingWindowControls {
        id: windowControls

        targetWindow: win
    }}
