import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins
import "./components"
import "./lib/Fmt.js" as Fmt

//: The plugin's page in DMS Settings, as board 12 draws it: four groups of
//: rows on raised cards, each row a label with one grey line and its control
//: on the right, and a live preview of the bar pill. Rows read the live
//: settings and save through PluginSettings, the same store DMS's own
//: *Setting widgets use.
PluginSettings {
    id: settings

    pluginId: "ariaDownloadManager"

    //: Live settings, so the rows and the preview follow every change.
    readonly property var cfg: SettingsData.pluginSettings[pluginId] || ({})

    function get(key, fallback) {
        const v = settings.cfg[key]
        return v === undefined || v === null ? fallback : v
    }

    //: A group: its caps heading, then a card holding its rows.
    component Group: Column {
        property string title: ""
        default property alias rows: cardColumn.data

        width: parent ? parent.width : 0
        spacing: 8
        topPadding: 8

        StyledText {
            leftPadding: 4
            text: parent.title
            font.pixelSize: Theme.fontSizeSmall - 1
            font.weight: Font.Bold
            font.letterSpacing: 1
            color: Theme.primary
        }

        Rectangle {
            id: card

            width: parent.width
            height: cardColumn.implicitHeight + 8
            radius: 16
            //: DMS already sets the page on a surfaceContainerHigh panel, so
            //: the groups sit one step above it.
            color: Theme.surfaceContainerHighest

            Column {
                id: cardColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.topMargin: 4
                anchors.leftMargin: 16
                anchors.rightMargin: 16
            }
        }
    }

    //: One row: what it is on the left, the control on the right.
    component Row_: Item {
        property string label: ""
        property string description: ""
        property bool divider: true
        default property alias control: controlSlot.data

        width: parent ? parent.width : 0
        height: Math.max(56, rowText.implicitHeight + 22, controlSlot.childrenRect.height + 16)

        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: 1
            visible: parent.divider
            color: Theme.outlineVariant
            opacity: 0.6
        }

        Column {
            id: rowText

            anchors.left: parent.left
            anchors.right: controlSlot.left
            anchors.rightMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            spacing: 2

            StyledText {
                width: parent.width
                text: rowText.parent.label
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.DemiBold
                color: Theme.surfaceText
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }

            StyledText {
                width: parent.width
                visible: text !== ""
                text: rowText.parent.description
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }
        }

        Item {
            id: controlSlot

            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: childrenRect.width
            height: childrenRect.height
        }
    }

    // ---- connection --------------------------------------------------------
    Group {
        title: "CONNECTION"

        //: Whether the widget can reach the manager right now, beside the
        //: field that decides it, with a way to try again after fixing it.
        Column {
            width: parent.width
            topPadding: 12
            bottomPadding: 12
            spacing: 10

            Item {
                width: parent.width
                height: socketText.implicitHeight

                Column {
                    id: socketText

                    anchors.left: parent.left
                    anchors.right: socketState.left
                    anchors.rightMargin: 12
                    spacing: 2

                    StyledText {
                        text: "Manager socket"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: "Must match server.socket in config.yaml. Blank uses the default."
                        wrapMode: Text.WordWrap
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceVariantText
                    }
                }

                Row {
                    id: socketState

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 6

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 7
                        height: 7
                        radius: 3.5
                        color: Aria2Service.connected ? Theme.success : Theme.error
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Aria2Service.connected ? "Connected" : "Not connected"
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Aria2Service.connected ? Theme.success : Theme.error
                    }
                }
            }

            Item {
                width: parent.width
                height: 38

                FillField {
                    id: socketField

                    anchors.left: parent.left
                    anchors.right: testButton.left
                    anchors.rightMargin: 8
                    size: 38
                    mono: true
                    fill: Theme.surfaceContainer
                    placeholderText: "$XDG_RUNTIME_DIR/aria-download-manager.sock"
                    text: settings.get("socketPath", "")
                    onEditingFinished: {
                        if (text.trim() !== settings.get("socketPath", ""))
                            settings.saveValue("socketPath", text.trim())
                    }
                }

                PillButton {
                    id: testButton

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    size: 34
                    kind: "outlined"
                    text: "Test"
                    onClicked: {
                        Aria2Service.restart()
                        Aria2Service.refreshSnapshot()
                    }
                }
            }

            //: Not reachable: say what the widget needs, since it downloads
            //: nothing on its own.
            StyledText {
                width: parent.width
                visible: !Aria2Service.connected
                text: "Nothing answered on " + Aria2Service.socketPath + ". This widget is a front-end: start the manager first (run.sh, or the systemd user unit)."
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
        }
    }

    // ---- bar -----------------------------------------------------------------
    Group {
        title: "BAR"

        Row_ {
            divider: false
            label: "Label next to the icon"
            description: "Shown only while something is happening"

            Segmented {
                color: Theme.surfaceContainer
                model: ["Speed", "Count", "None"]
                currentIndex: Math.max(0, ["speed", "count", "none"].indexOf(settings.get("pillMode", "speed")))
                onPicked: index => settings.saveValue("pillMode", ["speed", "count", "none"][index])
            }
        }

        Row_ {
            label: "Progress ring"
            description: "Overall progress of running downloads around the icon"

            BoolSwitch {
                width: 52
                height: 32
                checked: settings.get("showProgressRing", true) !== false
                onToggled: value => settings.saveValue("showProgressRing", value)
            }
        }

        Row_ {
            label: "Hide when idle"
            description: "Take the icon off the bar when nothing is running or queued"

            BoolSwitch {
                width: 52
                height: 32
                checked: settings.get("hideWhenIdle", false) === true
                onToggled: value => settings.saveValue("hideWhenIdle", value)
            }
        }

        Row_ {
            label: "Click opens"
            description: "Right-click always gives quick actions"

            Segmented {
                color: Theme.surfaceContainer
                model: ["Popout", "Window"]
                currentIndex: settings.get("clickOpens", "popout") === "window" ? 1 : 0
                onPicked: index => settings.saveValue("clickOpens", index === 1 ? "window" : "popout")
            }
        }
    }

    // ---- live preview ----------------------------------------------------------
    //: What the pill will look like with the settings above, flipped through
    //: its states with made-up figures, so a choice can be judged without
    //: waiting for a real download.
    Group {
        id: preview

        property int stateIndex: 0
        readonly property string mode: settings.get("pillMode", "speed")
        readonly property bool ring: settings.get("showProgressRing", true) !== false

        title: "PREVIEW"

        Column {
            width: parent.width
            topPadding: 12
            bottomPadding: 12
            spacing: 12

            //: A strip of bar with neighbours either side, so the pill is
            //: seen at the size it will have.
            Rectangle {
                width: parent.width
                height: 40
                radius: 12
                color: Theme.surfaceContainerLowest

                Row {
                    anchors.centerIn: parent
                    spacing: 12

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 40
                        height: 10
                        radius: 5
                        color: Theme.surfaceContainerHighest
                    }

                    Row {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 6

                        BarGlyph {
                            anchors.verticalCenter: parent.verticalCenter
                            size: 22
                            iconName: ["downloading", "pause_circle", "download", "error"][preview.stateIndex]
                            tint: [Theme.primary, Theme.surfaceVariantText, Theme.surfaceText, Theme.error][preview.stateIndex]
                            progress: preview.stateIndex === 0 && preview.ring ? 0.62 : -1
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: {
                                switch (preview.stateIndex) {
                                case 0:
                                    return preview.mode === "none" ? "" : (preview.mode === "count" ? "2" : Fmt.speed(4414000))
                                case 1:
                                    return preview.mode === "none" ? "" : "3 paused"
                                case 3:
                                    return "aria2c down"
                                default:
                                    return ""
                                }
                            }
                            visible: text.length > 0
                            font.pixelSize: Theme.fontSizeSmall + 1
                            font.weight: Font.DemiBold
                            color: [Theme.primary, Theme.surfaceVariantText, Theme.surfaceText, Theme.error][preview.stateIndex]
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: preview.stateIndex === 0 && preview.mode === "count"
                            text: "+3"
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: Font.Medium
                            color: Theme.surfaceVariantText
                        }
                    }

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 30
                        height: 10
                        radius: 5
                        color: Theme.surfaceContainerHighest
                    }
                }
            }

            Segmented {
                color: Theme.surfaceContainer
                model: ["Downloading", "Paused", "Idle", "Error"]
                currentIndex: preview.stateIndex
                onPicked: index => preview.stateIndex = index
            }

            StyledText {
                width: parent.width
                text: "Flip through states to see what the bar will show with these settings."
                wrapMode: Text.WordWrap
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.surfaceVariantText
            }
        }
    }

    // ---- popout and updates ------------------------------------------------------
    Group {
        title: "POPOUT & UPDATES"

        //: Width and height side by side, each with its figure.
        Row_ {
            divider: false
            label: "Popout size"

            Row {
                spacing: 12

                Repeater {
                    model: [["popoutWidth", 640, 480, 1100], ["popoutHeight", 540, 360, 1000]]

                    Row {
                        id: sizePair

                        required property var modelData

                        spacing: 8

                        MiniSlider {
                            id: sizeSlider

                            anchors.verticalCenter: parent.verticalCenter
                            width: 110
                            minimum: sizePair.modelData[2]
                            maximum: sizePair.modelData[3]
                            step: 10
                            value: settings.get(sizePair.modelData[0], sizePair.modelData[1])
                            onCommitted: value => settings.saveValue(sizePair.modelData[0], value)
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            width: 52
                            horizontalAlignment: Text.AlignRight
                            text: sizeSlider.value + " px"
                            font.pixelSize: Theme.fontSizeSmall + 1
                            color: Theme.surfaceText
                        }
                    }
                }
            }
        }

        Row_ {
            label: "Bar refresh while closed"
            description: "How far behind the bar may lag a new download"

            Row {
                spacing: 8

                MiniSlider {
                    id: pollSlider

                    anchors.verticalCenter: parent.verticalCenter
                    width: 150
                    minimum: 1
                    maximum: 30
                    value: settings.get("idlePollSeconds", 3)
                    onCommitted: value => settings.saveValue("idlePollSeconds", value)
                }

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    width: 40
                    horizontalAlignment: Text.AlignRight
                    text: pollSlider.value + " s"
                    font.pixelSize: Theme.fontSizeSmall + 1
                    color: Theme.surfaceText
                }
            }
        }

        Row_ {
            label: "Always stream"
            description: "Keep a live connection open so the bar is never behind"

            BoolSwitch {
                width: 52
                height: 32
                checked: settings.get("alwaysStream", false) === true
                onToggled: value => settings.saveValue("alwaysStream", value)
            }
        }
    }

    // ---- notifications -----------------------------------------------------------
    //: The old single "notify" switch seeds both, so turning on toasts before
    //: the split keeps them on after it.
    Group {
        title: "NOTIFICATIONS"

        Row_ {
            divider: false
            label: "When a download finishes"

            BoolSwitch {
                width: 52
                height: 32
                checked: settings.get("notifyFinished", settings.cfg.notify === true) === true
                onToggled: value => settings.saveValue("notifyFinished", value)
            }
        }

        Row_ {
            label: "When something fails"
            description: "Download errors and aria2c stopping"

            BoolSwitch {
                width: 52
                height: 32
                checked: settings.get("notifyErrors", settings.cfg.notify === true) === true
                onToggled: value => settings.saveValue("notifyErrors", value)
            }
        }
    }
}
