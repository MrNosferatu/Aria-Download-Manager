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
}
