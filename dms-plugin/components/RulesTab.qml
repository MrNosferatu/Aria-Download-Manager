import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/Layout.js" as Layout

Item {
    id: tab

    property var service: null
    property var rules: []
    property bool dirty: false

    readonly property int scrollbarGutter: Layout.SCROLLBAR_GUTTER

    readonly property var speedValues: ["hybrid", "measured", "aria2"]
    readonly property var speedLabels: ["measured, else aria2 (default)", "measured write speed only", "aria2's reported speed"]

    function reload() {
        if (!service)
            return
        // Edit a copy: the service keeps the server's version until we save.
        rules = JSON.parse(JSON.stringify(service.rules || []))
        dirty = false
    }

    function addRule() {
        const next = JSON.parse(JSON.stringify(rules))
        next.push({
                      "name": "rule-" + (next.length + 1),
                      "enabled": true,
                      "description": "",
                      "when": {
                          "statuses": ["active"],
                          "speed_below": 51200,
                          "for_seconds": 3,
                          "min_age_seconds": 8
                      },
                      "action": "pause_resume",
                      "resume_after_seconds": 1.5,
                      "cooldown_seconds": 25,
                      "max_triggers": 20
                  })
        rules = next
        dirty = true
    }

    function removeAt(index) {
        const next = JSON.parse(JSON.stringify(rules))
        next.splice(index, 1)
        rules = next
        dirty = true
    }

    Component.onCompleted: {
        if (service) {
            service.loadRules()
            reload()
        }
    }

    Connections {
        target: tab.service
        function onRulesLoaded() {
            if (!tab.dirty)
                tab.reload()
        }
    }

    // Same shape as the Settings tab header: one Row with one spacing value, so
    // the gaps between the control and its buttons match across tabs.
    Row {
        id: header

        width: parent.width
        height: 44
        spacing: Theme.spacingS

        DankDropdown {
            id: speedSource

            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(0, parent.width - addButton.width - saveButton.width - Theme.spacingS * 2)
            height: 40
            compactMode: true
            currentValue: {
                const at = tab.speedValues.indexOf(tab.service ? tab.service.speedSource : "hybrid")
                return tab.speedLabels[at >= 0 ? at : 0]
            }
            options: tab.speedLabels
            onValueChanged: label => {
                const at = tab.speedLabels.indexOf(label)
                if (at >= 0 && tab.service.speedSource !== tab.speedValues[at])
                    tab.service.setSpeedSource(tab.speedValues[at])
            }
        }

        DankButton {
            id: addButton

            anchors.verticalCenter: parent.verticalCenter
            width: 120
            text: "New rule"
            iconName: "add"
            buttonHeight: 40
            backgroundColor: Theme.surfaceContainerHigh
            textColor: Theme.surfaceText
            onClicked: tab.addRule()
        }

        DankButton {
            id: saveButton

            anchors.verticalCenter: parent.verticalCenter
            width: 100
            text: tab.dirty ? "Save •" : "Save"
            iconName: "save"
            buttonHeight: 40
            backgroundColor: Theme.primary
            textColor: Theme.onPrimary
            onClicked: {
                tab.service.saveRules(tab.rules, tab.service.rulesEnabled, tab.service.speedSource)
                tab.dirty = false
            }
        }
    }

    DankFlickable {
        anchors.top: header.bottom
        anchors.topMargin: Theme.spacingS
        anchors.bottom: parent.bottom
        width: parent.width
        clip: true
        contentHeight: content.implicitHeight
        contentWidth: width

        Column {
            id: content

            // Leave the flickable's scrollbar its own strip; it is painted over
            // the right edge and otherwise lands on the cards.
            width: parent.width - tab.scrollbarGutter
            spacing: Theme.spacingS

            StyledText {
                width: parent.width
                text: "A rule fires when its conditions hold continuously for the hold time, then that download enters cooldown."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Repeater {
                model: tab.rules

                RuleCard {
                    id: ruleCard

                    required property var modelData
                    required property int index

                    width: content.width
                    rule: ruleCard.modelData
                    ruleIndex: ruleCard.index
                    onRemoved: tab.removeAt(ruleCard.index)
                    onEdited: tab.dirty = true
                }
            }

            StyledText {
                width: parent.width
                visible: tab.rules.length === 0
                text: "No rules yet. A typical one pauses and resumes a download that stalls under 50 KiB/s for 3 seconds."
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
                wrapMode: Text.WordWrap
            }

            Rectangle {
                width: parent.width
                height: 1
                color: Theme.withAlpha(Theme.outline, 0.15)
            }

            StyledText {
                text: "Recent triggers"
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                visible: !tab.service || tab.service.triggers.length === 0
                text: "No rule has fired yet."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: tab.service ? tab.service.triggers.slice(0, 40) : []

                Row {
                    id: trigger

                    required property var modelData

                    width: content.width
                    spacing: Theme.spacingS

                    StyledText {
                        width: 58
                        text: Fmt.time(trigger.modelData.ts)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        width: Math.max(0, parent.width - 58 - Theme.spacingS)
                        text: trigger.modelData.rule + " · " + String(trigger.modelData.action || "").replace(/_/g, " ")
                              + " → " + trigger.modelData.name + " @ " + Fmt.speed(trigger.modelData.speed)
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }
}
