import QtQuick
import Quickshell
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import "../lib/Fmt.js" as Fmt

PopoutComponent {
    id: popout

    property var service: null
    property int contentHeight: 540
    readonly property int inset: Theme.spacingS
    property int tabIndex: service ? service.requestedTab : 0

    //: Set when this instance lives in the detached window instead of the bar
    //: popout. The window owns the title bar and the header actions, so the
    //: popout's own header steps aside and only the status line stays.
    property bool inWindow: false

    //: The popout learns whether it is on screen from its parent popout; the
    //: window has no parentPopout and drives this from its own visibility.
    property bool hostVisible: true

    signal detachRequested

    //: Everything above the tab content, so a host that owns its height (the
    //: window) can work out how much is left for the tabs. Spelled out term by
    //: term rather than derived from implicitHeight, which would bind back
    //: through contentHeight.
    readonly property int chromeHeight: headerHeight + detailsHeight + statStrip.height
                                        + Theme.spacingS + tabBar.height
                                        + Theme.spacingL + Theme.spacingXS

    Connections {
        target: popout.service
        function onRequestedTabChanged() {
            popout.tabIndex = popout.service.requestedTab
        }
    }

    readonly property bool online: service && service.connected

    // While this popout is on screen it pings the service, which streams for as
    // long as the pings keep coming. Closing simply stops the pings.
    readonly property bool showing: parentPopout ? parentPopout.shouldBeVisible : hostVisible

    onShowingChanged: {
        if (showing && service)
            service.viewerPing()
    }

    Component.onCompleted: {
        if (showing && service)
            service.viewerPing()
    }

    Timer {
        interval: 1000
        repeat: true
        running: popout.showing
        triggeredOnStart: true
        onTriggered: {
            if (popout.service)
                popout.service.viewerPing()
        }
    }

    headerText: inWindow ? "" : "Aria Download Manager"
    detailsText: {
        if (!service)
            return ""
        if (!service.connected)
            return "manager offline — " + service.socketPath
        const aria2 = service.aria2
        if (!aria2.running)
            return "aria2c not running — " + (aria2.last_error || "see the Log tab")
        return "aria2c " + (aria2.version || "") + " · pid " + (aria2.pid !== undefined && aria2.pid !== null ? aria2.pid : "ext")
    }
    showCloseButton: !inWindow

    headerActions: Component {
        ManagerActions {
            service: popout.service
            onDetachRequested: popout.detachRequested()
            onDismissRequested: {
                if (popout.closePopout)
                    popout.closePopout()
            }
        }
    }

    // ---- live stat strip -------------------------------------------------
    Rectangle {
        id: statStrip

        x: popout.inset
        width: parent.width - popout.inset * 2
        height: 46
        radius: Theme.cornerRadius
        color: Theme.surfaceContainerHigh

        Row {
            // Bounded by the rules switch on the right: without this the stats
            // run underneath it once the popout is narrowed.
            anchors.left: parent.left
            anchors.leftMargin: Theme.spacingM
            anchors.right: rulesSwitch.left
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingL
            clip: true

            Repeater {
                model: [
                    {
                        "label": "Down",
                        "value": popout.service ? Fmt.speed(popout.service.downloadSpeed) : "–",
                        "accent": true
                    },
                    {
                        "label": "Up",
                        "value": popout.service ? Fmt.speed(popout.service.uploadSpeed) : "–",
                        "accent": false
                    },
                    {
                        "label": "Active",
                        "value": popout.service ? String(popout.service.activeCount) : "0",
                        "accent": false
                    },
                    {
                        "label": "Queued",
                        "value": popout.service ? String(popout.service.waitingCount) : "0",
                        "accent": false
                    },
                    {
                        "label": "Stopped",
                        "value": popout.service ? String(popout.service.stoppedCount) : "0",
                        "accent": false
                    }
                ]

                Column {
                    id: statCell

                    required property var modelData

                    spacing: 0

                    StyledText {
                        text: statCell.modelData.label
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        text: statCell.modelData.value
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: statCell.modelData.accent ? Theme.primary : Theme.surfaceText
                    }
                }
            }
        }

        Row {
            id: rulesSwitch

            anchors.right: parent.right
            anchors.rightMargin: Theme.spacingM
            anchors.verticalCenter: parent.verticalCenter
            spacing: Theme.spacingS

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Rules"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            BoolSwitch {
                anchors.verticalCenter: parent.verticalCenter
                checked: popout.service ? popout.service.rulesEnabled : false
                onToggled: value => popout.service.setRulesEnabled(value)
            }
        }
    }

    Item {
        width: parent.width
        height: Theme.spacingS
    }

    DankTabBar {
        id: tabBar

        width: parent.width
        tabHeight: 52
        equalWidthTabs: true
        currentIndex: popout.tabIndex
        model: [
            {
                "text": "Downloads",
                "icon": "download"
            },
            {
                "text": "Rules",
                "icon": "bolt"
            },
            {
                "text": "Settings",
                "icon": "tune"
            }
        ]

        onTabClicked: index => popout.tabIndex = index
    }

    Item {
        // DankTabBar paints its active indicator and divider below its own
        // height (y = height + 7 and + 10), so the content has to start clear
        // of them or the first row sits on top of the underline.
        width: parent.width
        height: Theme.spacingL + Theme.spacingXS
    }

    Item {
        id: contentArea

        width: parent.width
        height: popout.contentHeight

        Loader {
            anchors.fill: parent
            anchors.leftMargin: popout.inset
            anchors.rightMargin: popout.inset
            sourceComponent: {
                switch (popout.tabIndex) {
                case 0:
                    return downloadsTab
                case 1:
                    return rulesTab
                default:
                    return settingsTab
                }
            }
        }
    }

    Component {
        id: downloadsTab
        DownloadsTab {
            service: popout.service
        }
    }

    Component {
        id: settingsTab
        SettingsTab {
            service: popout.service
        }
    }

    Component {
        id: rulesTab
        RulesTab {
            service: popout.service
        }
    }

}
