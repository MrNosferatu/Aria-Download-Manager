import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt

Rectangle {
    id: card

    property var rule: ({})
    property int ruleIndex: 0
    property bool showJson: false
    //: Every control in the card shares this, so nothing looks bolted on.
    readonly property int fieldHeight: 40

    // value -> label. The values are the literal config keys, so they stay
    // snake_case in config.yaml and in the raw JSON editor.
    readonly property var actionValues: ["pause_resume", "force_pause_resume", "restart", "set_option", "stop", "log_only"]
    readonly property var actionLabels: ["Pause + resume", "Force pause + resume", "Restart (remove and re-add)", "Change its options", "Pause and leave paused", "Log only (do nothing)"]

    readonly property var fields: [["when.speed_below", "Speed below", "speed"], ["when.for_seconds", "Hold for (s)", "number"], ["when.min_age_seconds", "Ignore first (s)", "number"], ["cooldown_seconds", "Cooldown (s)", "number"], ["resume_after_seconds", "Resume after (s)", "number"], ["max_triggers", "Max triggers (0 = ∞)", "number"], ["when.min_progress", "Only above progress %", "number"], ["when.max_progress", "Only below progress %", "number"], ["when.connections_below", "Connections below", "number"], ["when.name_matches", "Name matches (regex)", "text"]]

    //: aria2's own status vocabulary. Anything already saved in the rule is
    //: kept, so a hand-edited config never loses a value it cannot show.
    readonly property var knownStatuses: ["active", "waiting", "paused", "error", "complete", "removed"]
    property var statuses: ((rule.when || ({})).statuses || ["active"]).slice()
    readonly property var statusOptions: {
        const out = knownStatuses.slice()
        for (const name of statuses) {
            if (out.indexOf(name) === -1)
                out.push(name)
        }
        return out
    }

    signal removed
    signal edited

    function actionLabelFor(value) {
        const at = actionValues.indexOf(value)
        return at >= 0 ? actionLabels[at] : String(value || "").replace(/_/g, " ")
    }

    height: body.implicitHeight + Theme.spacingS * 2
    radius: Theme.cornerRadius
    color: Theme.surfaceContainer
    border.width: 1
    border.color: Theme.withAlpha(Theme.outline, 0.12)
    opacity: card.rule.enabled === false ? 0.6 : 1

    Column {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: Theme.spacingS
        spacing: Theme.spacingXS

        // Title row: the rule's name stands alone, with only the on/off switch
        // and delete beside it. Everything else is a labelled field below.
        Row {
            width: parent.width
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: card.rule.enabled === false ? "toggle_off" : "toggle_on"
                size: Theme.iconSize
                color: card.rule.enabled === false ? Theme.surfaceVariantText : Theme.primary

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                        card.rule.enabled = card.rule.enabled === false
                        card.edited()
                    }
                }
            }

            DankTextField {
                id: nameField

                anchors.verticalCenter: parent.verticalCenter
                width: Math.max(0, parent.width - Theme.iconSize - deleteButton.width - Theme.spacingXS * 2)
                height: card.fieldHeight
                font.pixelSize: Theme.fontSizeMedium
                text: card.rule.name || ""
                placeholderText: "Rule name"
                Component.onCompleted: cursorPosition = 0
                onTextChanged: {
                    card.rule.name = text.trim()
                    card.edited()
                }
            }

            DankActionButton {
                id: deleteButton

                anchors.verticalCenter: parent.verticalCenter
                buttonSize: card.fieldHeight
                iconSize: Theme.iconSizeSmall
                iconName: "delete"
                iconColor: Theme.error
                circular: false
                tooltipText: "Delete rule"
                onClicked: card.removed()
            }
        }

        Column {
            width: parent.width
            spacing: 1

            StyledText {
                width: parent.width
                text: "Action"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankDropdown {
                width: parent.width
                height: card.fieldHeight
                compactMode: true
                currentValue: card.actionLabelFor(card.rule.action || "pause_resume")
                options: card.actionLabels
                onValueChanged: label => {
                    const at = card.actionLabels.indexOf(label)
                    if (at >= 0) {
                        card.rule.action = card.actionValues[at]
                        card.edited()
                    }
                }
            }
        }

        Grid {
            width: parent.width
            columns: 3
            columnSpacing: Theme.spacingS
            rowSpacing: Theme.spacingXS

            Repeater {
                model: card.fields

                Column {
                    id: fieldCell

                    required property var modelData

                    width: (parent.width - Theme.spacingS * 2) / 3
                    spacing: 1

                    StyledText {
                        width: parent.width
                        text: fieldCell.modelData[1]
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }

                    UnitField {
                        width: parent.width
                        visible: fieldCell.modelData[2] === "speed"
                        height: visible ? card.fieldHeight : 0
                        kind: "speed"
                        raw: {
                            const current = Fmt.getPath(card.rule, fieldCell.modelData[0])
                            return current === undefined || current === null ? "" : String(current)
                        }
                        onEdited: newValue => {
                            const number = Number(newValue)
                            Fmt.setPath(card.rule, fieldCell.modelData[0],
                                        newValue === "" || !isFinite(number) ? newValue : number)
                            card.edited()
                        }
                    }

                    DankTextField {
                        width: parent.width
                        visible: fieldCell.modelData[2] !== "speed"
                        height: visible ? card.fieldHeight : 0
                        font.pixelSize: Theme.fontSizeSmall
                        text: {
                            const raw = Fmt.getPath(card.rule, fieldCell.modelData[0])
                            return raw === undefined || raw === null ? "" : String(raw)
                        }
                        onEditingFinished: {
                            const kind = fieldCell.modelData[2]
                            let value = text.trim()
                            if (value === "") {
                                Fmt.setPath(card.rule, fieldCell.modelData[0], "")
                            } else if (kind === "number") {
                                Fmt.setPath(card.rule, fieldCell.modelData[0], Number(value))
                            } else {
                                Fmt.setPath(card.rule, fieldCell.modelData[0], value)
                            }
                            card.edited()
                        }
                    }
                }
            }
        }

        Column {
            width: parent.width
            spacing: 2

            StyledText {
                width: parent.width
                text: "Applies to statuses"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankFilterChips {
                width: parent.width
                chipHeight: 30
                multiSelect: true
                showCounts: false
                model: card.statusOptions.map(name => ({
                                                           "label": Fmt.label(name),
                                                           "value": name
                                                       }))
                selectedValues: card.statuses

                onSelectionToggled: (index, selected) => {
                    const name = card.statusOptions[index]
                    const next = card.statuses.filter(s => s !== name)
                    if (selected)
                        next.push(name)
                    // aria2 needs at least one status, and the daemon falls back
                    // to "active" anyway — say so rather than saving nothing.
                    Fmt.setPath(card.rule, "when.statuses", next.length ? next : ["active"])
                    card.statuses = next.length ? next : ["active"]
                    card.edited()
                }
            }
        }

        Column {
            width: parent.width
            spacing: 1

            StyledText {
                width: parent.width
                text: "Description"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            DankTextField {
                width: parent.width
                height: card.fieldHeight
                font.pixelSize: Theme.fontSizeSmall
                placeholderText: "What this rule is for (optional)"
                text: card.rule.description || ""
                Component.onCompleted: cursorPosition = 0
                onTextChanged: {
                    card.rule.description = text
                    card.edited()
                }
            }
        }

        StyledText {
            width: parent.width
            visible: card.rule.action === "set_option"
            text: "The set_option action needs an \"options\" mapping — edit it in the raw JSON below."
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.warning
            wrapMode: Text.WordWrap
        }

        Row {
            spacing: Theme.spacingXS

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: card.showJson ? "expand_less" : "expand_more"
                size: Theme.iconSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: "Raw JSON (full control)"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: {
                    if (!card.showJson)
                        jsonField.text = JSON.stringify(card.rule, null, 2)
                    card.showJson = !card.showJson
                }
            }
        }

        MultiLineField {
            id: jsonField

            width: parent.width
            visible: card.showJson
            minimumHeight: 120
        }

        DankButton {
            visible: card.showJson
            text: "Apply JSON"
            iconName: "code"
            buttonHeight: 28
            backgroundColor: Theme.surfaceContainerHigh
            textColor: Theme.surfaceText
            onClicked: {
                try {
                    const parsed = JSON.parse(jsonField.text)
                    for (const key in card.rule)
                        delete card.rule[key]
                    for (const key in parsed)
                        card.rule[key] = parsed[key]
                    card.edited()
                } catch (e) {
                    ToastService.showError("aria2c", "Invalid JSON: " + e.message)
                }
            }
        }
    }
}
