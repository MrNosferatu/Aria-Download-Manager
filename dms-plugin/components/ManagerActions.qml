import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Actions.js" as Actions

//: The header buttons for the manager, shared by the bar popout and the
//: detached window so both stay in step.
Row {
    id: actions

    property var service: null

    //: In the window the detach button becomes "dock back into the bar".
    property bool inWindow: false

    signal detachRequested
    signal dockRequested

    //: The popout asks to close itself after an action that moves the user
    //: somewhere else; the window ignores it.
    signal dismissRequested

    spacing: Theme.spacingXS

    //: Pause all and Resume all share one button that flips with the state:
    //: pause while anything runs, resume once nothing does.
    readonly property var pauseAction: Actions.GLOBAL.find(a => a.id === "pauseAll")
    readonly property var resumeAction: Actions.GLOBAL.find(a => a.id === "resumeAll")
    readonly property var purgeAction: Actions.GLOBAL.find(a => a.id === "purge")
    readonly property bool usable: !!service && service.connected && service.aria2Running
    readonly property bool running: usable && service.activeCount > 0
    readonly property var flipAction: running ? pauseAction : resumeAction
    //: With no manager the queue buttons have nothing to act on, so the
    //: header keeps only the way out (board 10).
    readonly property bool connected: !!service && service.connected

    DankActionButton {
        visible: actions.connected
        iconName: actions.flipAction.icon
        tooltipText: actions.running ? "Pause all (" + actions.service.activeCount + ")"
                                     : "Resume all" + (actions.usable && actions.service.waitingCount > 0 ? " (" + actions.service.waitingCount + ")" : "")
        buttonSize: 36
        iconSize: 20
        iconColor: Theme.surfaceText
        enabled: actions.usable
        opacity: enabled ? 1 : 0.4
        onClicked: actions.service.post(actions.flipAction.path, null, actions.flipAction.ok)
    }

    DankActionButton {
        readonly property int count: actions.usable ? actions.service.stoppedCount : 0

        visible: actions.connected
        iconName: actions.purgeAction.icon
        tooltipText: count > 0 ? Actions.tooltipFor(actions.purgeAction) + " (" + count + ")" : "Nothing finished to clear"
        buttonSize: 36
        iconSize: 20
        iconColor: Theme.surfaceText
        enabled: count > 0
        opacity: enabled ? 1 : 0.4
        onClicked: actions.service.post(actions.purgeAction.path, null, actions.purgeAction.ok)
    }

    Rectangle {
        anchors.verticalCenter: parent.verticalCenter
        visible: actions.connected
        width: 1
        height: 20
        color: Theme.outlineVariant
    }

    DankActionButton {
        visible: actions.connected || actions.inWindow
        iconName: actions.inWindow ? "picture_in_picture" : "open_in_new"
        tooltipText: actions.inWindow ? "Dock back into the bar" : "Open in window"
        buttonSize: 36
        iconSize: 20
        iconColor: Theme.surfaceText
        onClicked: {
            if (actions.inWindow) {
                actions.dockRequested()
            } else {
                actions.detachRequested()
                actions.dismissRequested()
            }
        }
    }
}
