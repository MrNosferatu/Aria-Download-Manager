import QtQuick
import Quickshell
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

    //: server.web_ui is off by default, and the manager only mounts the UI at
    //: startup — so a config change is pending until it restarts.
    readonly property bool webUiOn: service ? service.webUiEnabled : false
    readonly property bool webUiPending: service ? service.restartRequired : false

    spacing: Theme.spacingXS

    Repeater {
        model: Actions.GLOBAL

        DankActionButton {
            required property var modelData

            iconName: modelData.icon
            tooltipText: Actions.tooltipFor(modelData)
            buttonSize: 30
            onClicked: actions.service.post(modelData.path, null, modelData.ok)
        }
    }

    DankActionButton {
        iconName: actions.inWindow ? "picture_in_picture" : "open_in_new"
        tooltipText: actions.inWindow ? "Dock back into the bar" : "Open in window"
        buttonSize: 30
        onClicked: {
            if (actions.inWindow) {
                actions.dockRequested()
            } else {
                actions.detachRequested()
                actions.dismissRequested()
            }
        }
    }

    DankActionButton {
        iconName: "open_in_browser"
        tooltipText: Actions.webUiTooltip(actions.webUiOn, actions.webUiPending)
        buttonSize: 30
        enabled: actions.webUiOn
        opacity: enabled ? 1 : 0.5
        onClicked: {
            Quickshell.execDetached(["xdg-open", actions.service.baseUrl + "/"])
            actions.dismissRequested()
        }
    }
}
