import QtQuick
import qs.Common
import qs.Widgets

//: The last minute before the one-off shut down or suspend (the manager's
//: afterall.py), counted down second by second between the state's frames,
//: with Cancel. Shown in the popout and the window while it counts.
Rectangle {
    id: banner

    property var service: null

    readonly property var after: service ? service.afterAll : ({})
    readonly property bool shown: !!after.deadline
    property int secondsLeft: 0

    Timer {
        running: banner.shown
        interval: 1000
        repeat: true
        triggeredOnStart: true
        onTriggered: banner.secondsLeft = Math.max(0, Math.round(banner.after.deadline - Date.now() / 1000))
    }

    height: shown ? 52 : 0
    visible: shown
    radius: 14
    color: Theme.withAlpha(Theme.warning, 0.14)
    border.width: 1
    border.color: Theme.withAlpha(Theme.warning, 0.4)

    DankIcon {
        id: icon

        anchors.left: parent.left
        anchors.leftMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        name: banner.after.action === "suspend" ? "bedtime" : "power_settings_new"
        size: 20
        color: Theme.warning
    }

    StyledText {
        anchors.left: icon.right
        anchors.leftMargin: Theme.spacingS
        anchors.right: cancel.left
        anchors.rightMargin: Theme.spacingS
        anchors.verticalCenter: parent.verticalCenter
        text: (banner.after.action === "suspend" ? "Suspending" : "Shutting down") + " in " + banner.secondsLeft + " s. All downloads have finished."
        font.pixelSize: Theme.fontSizeSmall + 1
        font.weight: Font.DemiBold
        color: Theme.surfaceText
        wrapMode: Text.NoWrap
        elide: Text.ElideRight
    }

    PillButton {
        id: cancel

        anchors.right: parent.right
        anchors.rightMargin: 8
        anchors.verticalCenter: parent.verticalCenter
        size: 36
        kind: "filled"
        text: "Cancel"
        onClicked: banner.service.setAfterAll("")
    }
}
