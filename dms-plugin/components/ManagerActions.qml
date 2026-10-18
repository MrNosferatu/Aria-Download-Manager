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

    //: Clearing asks first: one stray click would empty the list.
    DankActionButton {
        id: purgeButton

        readonly property int count: actions.usable ? actions.service.clearableCount : 0

        visible: actions.connected
        iconName: actions.purgeAction.icon
        tooltipText: count > 0 ? Actions.tooltipFor(actions.purgeAction) + " (" + count + ")" : "Nothing finished to clear"
        buttonSize: 36
        iconSize: 20
        iconColor: Theme.surfaceText
        enabled: count > 0
        opacity: enabled ? 1 : 0.4
        onClicked: purgeConfirm.toggle()

        MenuPopup {
            id: purgeConfirm

            alignEnd: true
            menuWidth: 250
            entries: [{
                    "heading": "Clear " + purgeButton.count + (purgeButton.count === 1 ? " download?" : " downloads?")
                }, {
                    "icon": actions.purgeAction.icon,
                    "text": "Clear from the list",
                    "detail": "files are kept",
                    "danger": true
                }, {
                    "icon": "close",
                    "text": "Cancel"
                }]
            onTriggered: index => {
                if (index === 1)
                    actions.service.clearFinished()
            }
        }
    }

    //: When the downloads finish: shut down, suspend, or nothing (a one-off);
    //: tinted while one is set.
    DankActionButton {
        readonly property string armed: actions.connected ? (actions.service.afterAll.action || "") : ""

        visible: actions.connected
        iconName: armed === "suspend" ? "bedtime" : "power_settings_new"
        tooltipText: armed ? "When downloads finish: " + (armed === "shutdown" ? "shut down" : "suspend") : "When downloads finish…"
        buttonSize: 36
        iconSize: 20
        iconColor: armed ? Theme.primary : Theme.surfaceText
        onClicked: afterMenu.toggle()

        MenuPopup {
            id: afterMenu

            readonly property string armed: parent.armed

            alignEnd: true
            menuWidth: 230
            entries: [{
                    "heading": "When downloads finish"
                }, {
                    "icon": "block",
                    "text": "Do nothing",
                    "checked": armed === ""
                }, {
                    "icon": "bedtime",
                    "text": "Suspend",
                    "checked": armed === "suspend"
                }, {
                    "icon": "power_settings_new",
                    "text": "Shut down",
                    "checked": armed === "shutdown"
                }]
            onTriggered: index => actions.service.setAfterAll(["", "", "suspend", "shutdown"][index])
        }
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
