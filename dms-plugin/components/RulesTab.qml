import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/Layout.js" as Layout
import "../lib/Rules.js" as Rules

Item {
    id: tab

    property var service: null
    property var rules: []
    property bool dirty: false
    //: One card open at a time; -1 for none.
    property int openIndex: -1
    //: The wide window: the list on the left, the open action's editor and
    //: its own trigger history on the right.
    property bool wide: false
    //: Bumped on every edit, so a card showing the same rule elsewhere
    //: refreshes its summary.
    property int editRev: 0

    //: Each edited rule's name on the manager, "" for one not saved yet: the
    //: switch saves at once under that name even after an unsaved rename.
    property var origins: []

    readonly property int onCount: rules.filter(r => r.enabled !== false).length
    readonly property bool masterOn: !!service && service.rulesEnabled

    readonly property int scrollbarGutter: Layout.SCROLLBAR_GUTTER

    readonly property var speedValues: ["hybrid", "measured", "aria2"]
    readonly property var speedLabels: ["Hybrid", "Disk writes", "aria2 reported"]

    function reload() {
        if (!service)
            return
        // Edit a copy: the service keeps the server's version until we save.
        rules = JSON.parse(JSON.stringify(service.rules || []))
        origins = rules.map(r => r.name)
        dirty = false
        if (openIndex >= rules.length)
            openIndex = -1
        // Side by side, the editor is never left empty when there is a rule.
        if (wide && openIndex < 0 && rules.length)
            openIndex = 0
    }

    onWideChanged: {
        if (wide && openIndex < 0 && rules.length)
            openIndex = 0
    }

    //: Adds a rule — a template's, or a blank one — and opens it.
    function addRule(template) {
        const next = JSON.parse(JSON.stringify(rules))
        const rule = template ? JSON.parse(JSON.stringify(template)) : {
                                    "name": "",
                                    "enabled": true,
                                    "description": "",
                                    "when": {
                                        "statuses": ["active"],
                                        "speed_below": 51200,
                                        "for_seconds": 3
                                    },
                                    "action": "pause_resume",
                                    "resume_after_seconds": 1.5
                                }
        // Names must be unique: they key the trigger counts and the log.
        const taken = next.map(r => r.name)
        let name = rule.name || "Action " + (next.length + 1)
        for (let n = 2; taken.indexOf(name) >= 0; n++)
            name = (rule.name || "Action") + " " + n
        rule.name = name
        next.push(rule)
        rules = next
        origins = origins.concat([""])
        openIndex = next.length - 1
        dirty = true
    }

    //: A copy under a free name, right after the original.
    function duplicateAt(index) {
        const next = JSON.parse(JSON.stringify(rules))
        const copy = JSON.parse(JSON.stringify(next[index]))
        const taken = next.map(r => r.name)
        let name = copy.name + " copy"
        for (let n = 2; taken.indexOf(name) >= 0; n++)
            name = copy.name + " copy " + n
        copy.name = name
        next.splice(index + 1, 0, copy)
        const from = origins.slice()
        from.splice(index + 1, 0, "")
        rules = next
        origins = from
        if (openIndex > index)
            openIndex++
        dirty = true
    }

    //: The switch on a row (or in the editor) saves straight away, like the
    //: master switch: it is never one of the unsaved edits. Only an action
    //: that is not on the manager yet waits for Save with the rest of it.
    function setEnabled(index, value) {
        const next = JSON.parse(JSON.stringify(rules))
        next[index].enabled = value
        rules = next
        const name = origins[index] || ""
        if (!name || !service) {
            dirty = true
            return
        }
        service.post("/api/rules/" + encodeURIComponent(name) + "/toggle", {
                         "enabled": value
                     }, (value ? "On: " : "Off: ") + name, () => {
                         service.rules = (service.rules || []).map(r => r.name === name ? Object.assign({}, r, {
                                                                                                             "enabled": value
                                                                                                         }) : r)
                     })
    }

    function removeAt(index) {
        const next = JSON.parse(JSON.stringify(rules))
        next.splice(index, 1)
        const from = origins.slice()
        from.splice(index, 1)
        rules = next
        origins = from
        if (openIndex === index)
            openIndex = -1
        else if (openIndex > index)
            openIndex--
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

    // ---- master switch ----------------------------------------------------
    //: It heads the tab it controls, saying what it does, with how a rule
    //: judges speed in the same card (board 7).
    Rectangle {
        id: masterCard

        readonly property bool on: !!tab.service && tab.service.rulesEnabled

        //: Side by side it heads the list column, leaving the editor the
        //: full height (board 20).
        width: tab.wide ? listFlick.width - tab.scrollbarGutter : parent.width - tab.scrollbarGutter
        height: masterColumn.implicitHeight + 32
        radius: 16
        color: Theme.surfaceContainerHigh

        Column {
            id: masterColumn

            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.margins: 16
            spacing: 12

            Item {
                width: parent.width
                height: Math.max(masterText.implicitHeight, masterSwitch.height)

                Column {
                    id: masterText

                    anchors.left: parent.left
                    anchors.right: masterSwitch.left
                    anchors.rightMargin: 16
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    StyledText {
                        text: "Automatic actions"
                        font.pixelSize: Theme.fontSizeMedium + 1
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        text: masterCard.on ? "Watch running downloads and step in when one stalls"
                                            : "Off — nothing below runs. You can still edit and switch them."
                        wrapMode: Text.WordWrap
                        maximumLineCount: 2
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                        elide: Text.ElideRight
                    }
                }

                BoolSwitch {
                    id: masterSwitch

                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    width: 52
                    height: 32
                    checked: masterCard.on
                    onToggled: value => tab.service.setRulesEnabled(value)
                }
            }

            //: How a rule judges speed, as one visible choice rather than a
            //: dropdown. Wraps under its label in a narrow column.
            Flow {
                width: parent.width
                spacing: 8

                StyledText {
                    height: 34
                    verticalAlignment: Text.AlignVCenter
                    rightPadding: 4
                    text: "Measure speed by"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Segmented {
                    color: Theme.surfaceContainer
                    model: tab.speedLabels
                    currentIndex: Math.max(0, tab.speedValues.indexOf(tab.service ? tab.service.speedSource : "hybrid"))
                    onPicked: index => {
                        if (tab.service.speedSource !== tab.speedValues[index])
                            tab.service.setSpeedSource(tab.speedValues[index])
                    }
                }
            }
        }
    }

    //: How many are on, and while the master switch is off, that none run.
    Item {
        id: countLine

        anchors.top: masterCard.bottom
        anchors.topMargin: 12
        width: masterCard.width
        height: tab.rules.length ? 20 : 0
        visible: tab.rules.length > 0

        StyledText {
            id: countText

            anchors.left: parent.left
            anchors.leftMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            width: Math.min(implicitWidth, parent.width - 8)
            text: tab.onCount + " of " + tab.rules.length + " on" + (tab.masterOn ? "" : " · none run while automatic actions are off")
            font.pixelSize: Theme.fontSizeSmall + 1
            font.weight: Font.DemiBold
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        StyledText {
            anchors.right: parent.right
            anchors.rightMargin: 4
            anchors.verticalCenter: parent.verticalCenter
            visible: tab.masterOn && parent.width - countText.width > implicitWidth + 32
            text: "Switch to turn one on or off · click the row to edit"
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.outline
        }
    }

    DankFlickable {
        id: listFlick

        anchors.top: countLine.bottom
        anchors.topMargin: countLine.visible ? 8 : 12
        anchors.bottom: saveBar.visible ? saveBar.top : parent.bottom
        anchors.bottomMargin: saveBar.visible ? 12 : 0
        width: tab.wide ? Math.round(parent.width * 0.42) : parent.width
        clip: true
        contentHeight: content.implicitHeight
        contentWidth: width

        Column {
            id: content

            // Leave the flickable's scrollbar its own strip; it is painted over
            // the right edge and otherwise lands on the cards.
            width: parent.width - tab.scrollbarGutter
            spacing: 8

            Repeater {
                model: tab.rules

                RuleCard {
                    id: ruleCard

                    required property var modelData
                    required property int index

                    width: content.width
                    rule: ruleCard.modelData
                    ruleIndex: ruleCard.index
                    open: !tab.wide && tab.openIndex === ruleCard.index
                    current: tab.wide && tab.openIndex === ruleCard.index
                    externalRev: tab.editRev
                    //: Master off: the whole list dims, still editable.
                    opacity: tab.masterOn || ruleCard.open ? 1 : 0.6
                    onRemoved: tab.removeAt(ruleCard.index)
                    onDuplicated: tab.duplicateAt(ruleCard.index)
                    onEnabledToggled: value => tab.setEnabled(ruleCard.index, value)
                    onEdited: {
                        tab.dirty = true
                        tab.editRev++
                    }
                    onToggleOpen: {
                        if (tab.wide)
                            tab.openIndex = ruleCard.index
                        else
                            tab.openIndex = (tab.openIndex === ruleCard.index ? -1 : ruleCard.index)
                    }
                }
            }

            //: A dashed full-width outline: room for one more.
            Item {
                id: newAction

                visible: tab.rules.length > 0
                width: parent.width
                height: 44

                Canvas {
                    anchors.fill: parent

                    property color tint: newArea.containsMouse ? Theme.outline : Theme.outlineVariant

                    onTintChanged: requestPaint()
                    onWidthChanged: requestPaint()

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        const r = 14
                        const w = width - 1, h = height - 1
                        ctx.strokeStyle = tint
                        ctx.lineWidth = 1
                        ctx.setLineDash([4, 3])
                        ctx.beginPath()
                        ctx.moveTo(0.5 + r, 0.5)
                        ctx.lineTo(w - r + 0.5, 0.5)
                        ctx.arcTo(w + 0.5, 0.5, w + 0.5, r + 0.5, r)
                        ctx.lineTo(w + 0.5, h - r + 0.5)
                        ctx.arcTo(w + 0.5, h + 0.5, w - r + 0.5, h + 0.5, r)
                        ctx.lineTo(r + 0.5, h + 0.5)
                        ctx.arcTo(0.5, h + 0.5, 0.5, h - r + 0.5, r)
                        ctx.lineTo(0.5, r + 0.5)
                        ctx.arcTo(0.5, 0.5, r + 0.5, 0.5, r)
                        ctx.stroke()
                    }
                }

                Row {
                    anchors.centerIn: parent
                    spacing: 8

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "add"
                        size: 18
                        color: Theme.surfaceText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "New action"
                        font.pixelSize: Theme.fontSizeSmall + 1
                        color: Theme.surfaceText
                    }
                }

                MouseArea {
                    id: newArea

                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: tab.addRule(null)
                }
            }

            // ---- no actions yet: start from a template (board 18) ----
            Rectangle {
                width: parent.width
                visible: tab.rules.length === 0
                height: visible ? emptyColumn.implicitHeight + 28 : 0
                radius: 18
                color: Theme.surfaceContainer

                Column {
                    id: emptyColumn

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 14
                    spacing: 8

                    Rectangle {
                        anchors.horizontalCenter: parent.horizontalCenter
                        width: 56
                        height: 56
                        radius: 28
                        color: Theme.surfaceContainerHighest

                        DankIcon {
                            anchors.centerIn: parent
                            name: "auto_fix_high"
                            size: 28
                            color: Theme.primary
                        }
                    }

                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        topPadding: 4
                        text: "Let the manager babysit downloads"
                        font.pixelSize: Theme.fontSizeLarge
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }

                    StyledText {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        wrapMode: Text.WordWrap
                        bottomPadding: 4
                        text: "An action watches running downloads and steps in when something goes wrong. Start from one of these:"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: Rules.TEMPLATES

                        Rectangle {
                            id: template

                            required property var modelData

                            width: emptyColumn.width
                            height: Math.max(56, templateText.implicitHeight + 20)
                            radius: 12
                            color: templateArea.containsMouse ? Theme.surfaceContainerHighest : Theme.surfaceContainerHigh

                            DankIcon {
                                id: templateIcon

                                anchors.left: parent.left
                                anchors.leftMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                name: template.modelData.icon
                                size: 22
                                color: Theme.primary
                            }

                            Column {
                                id: templateText

                                anchors.left: templateIcon.right
                                anchors.leftMargin: 14
                                anchors.right: templateAdd.left
                                anchors.rightMargin: 8
                                anchors.verticalCenter: parent.verticalCenter
                                spacing: 1

                                StyledText {
                                    text: template.modelData.title
                                    font.pixelSize: Theme.fontSizeMedium
                                    font.weight: Font.DemiBold
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    width: parent.width
                                    text: Rules.summary(template.modelData.rule)
                                    wrapMode: Text.WordWrap
                                    maximumLineCount: 2
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceVariantText
                                    elide: Text.ElideRight
                                }
                            }

                            DankIcon {
                                id: templateAdd

                                anchors.right: parent.right
                                anchors.rightMargin: 14
                                anchors.verticalCenter: parent.verticalCenter
                                name: "add"
                                size: 20
                                color: Theme.surfaceVariantText
                            }

                            MouseArea {
                                id: templateArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: tab.addRule(template.modelData.rule)
                            }
                        }
                    }

                    PillButton {
                        anchors.horizontalCenter: parent.horizontalCenter
                        size: 34
                        kind: "text"
                        icon: "add"
                        text: "Start from blank"
                        onClicked: tab.addRule(null)
                    }
                }
            }

            StyledText {
                leftPadding: 4
                topPadding: 8
                text: "Recent triggers"
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            StyledText {
                width: parent.width
                leftPadding: 4
                visible: !tab.service || tab.service.triggers.length === 0
                text: "No action has fired yet."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Repeater {
                model: tab.service ? tab.service.triggers.slice(0, 40) : []

                Row {
                    id: trigger

                    required property var modelData

                    width: content.width
                    height: 22
                    leftPadding: 4
                    spacing: 9

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: Fmt.time(trigger.modelData.ts)
                        font.pixelSize: Theme.fontSizeSmall
                        font.family: "monospace"
                        color: Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: trigger.modelData.rule
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.primary
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        width: Math.max(0, trigger.width - x - 4)
                        text: Rules.triggerLine(trigger.modelData)
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }
                }
            }
        }
    }

    // ---- wide: the open action beside the list ------------------------------
    DankFlickable {
        anchors.top: parent.top
        anchors.topMargin: 0
        anchors.bottom: saveBar.visible ? saveBar.top : parent.bottom
        anchors.bottomMargin: saveBar.visible ? 12 : 0
        anchors.left: listFlick.right
        anchors.leftMargin: 16
        anchors.right: parent.right
        visible: tab.wide
        clip: true
        contentHeight: editorColumn.implicitHeight
        contentWidth: width

        Column {
            id: editorColumn

            readonly property var rule: tab.openIndex >= 0 ? tab.rules[tab.openIndex] : null

            width: parent.width - tab.scrollbarGutter
            spacing: 8

            StyledText {
                width: parent.width
                visible: !editorColumn.rule
                topPadding: Theme.spacingXL
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: tab.rules.length ? "Pick an action on the left to edit it." : "Start from a template on the left."
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }

            Loader {
                width: parent.width
                active: !!editorColumn.rule

                sourceComponent: RuleCard {
                    width: editorColumn.width
                    //: The editor sits on the pane itself, unboxed (board 20).
                    border.width: 0
                    rule: editorColumn.rule
                    ruleIndex: tab.openIndex
                    open: true
                    externalRev: tab.editRev
                    onRemoved: tab.removeAt(tab.openIndex)
                    onEnabledToggled: value => tab.setEnabled(tab.openIndex, value)
                    onEdited: {
                        tab.dirty = true
                        tab.editRev++
                    }
                    onToggleOpen: tab.openIndex = -1
                }
            }

            //: This action's own history, in a card under the editor.
            Rectangle {
                width: parent.width
                visible: !!editorColumn.rule
                height: visible ? Math.max(140, ruleTriggers.implicitHeight + 24) : 0
                radius: 14
                color: Theme.surfaceContainer

                Column {
                    id: ruleTriggers

                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.margins: 12
                    spacing: 2

                    StyledText {
                        bottomPadding: 6
                        text: "Recent triggers of this action"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    Repeater {
                        model: editorColumn.rule && tab.service ? tab.service.triggers.filter(t => t.rule === editorColumn.rule.name).slice(0, 30) : []

                        Row {
                            id: ruleTrigger

                            required property var modelData

                            width: ruleTriggers.width
                            height: 20
                            spacing: 9

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: Fmt.time(ruleTrigger.modelData.ts)
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.family: "monospace"
                                color: Theme.surfaceVariantText
                            }

                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                width: Math.max(0, ruleTrigger.width - x)
                                text: Rules.triggerLine(ruleTrigger.modelData)
                                font.pixelSize: Theme.fontSizeSmall - 1
                                font.family: "monospace"
                                color: Theme.surfaceText
                                wrapMode: Text.NoWrap
                                elide: Text.ElideRight
                            }
                        }
                    }

                    StyledText {
                        visible: !!editorColumn.rule && !!tab.service && !tab.service.triggers.some(t => t.rule === editorColumn.rule.name)
                        text: "It has not fired yet."
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }
                }
            }
        }
    }

    // ---- unsaved changes ---------------------------------------------------
    //: Appears only when there is something to save.
    Rectangle {
        id: saveBar

        anchors.bottom: parent.bottom
        width: parent.width - tab.scrollbarGutter
        height: 50
        visible: tab.dirty
        radius: 16
        color: Theme.surfaceContainerHigh

        Rectangle {
            id: saveDot

            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.verticalCenter: parent.verticalCenter
            width: 6
            height: 6
            radius: 3
            color: Theme.primary
        }

        StyledText {
            anchors.left: saveDot.right
            anchors.leftMargin: 10
            anchors.right: saveButtons.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: tab.openIndex >= 0 && tab.rules[tab.openIndex] && tab.rules[tab.openIndex].name
                  ? "Unsaved changes in " + tab.rules[tab.openIndex].name : "Unsaved changes to actions"
            font.pixelSize: Theme.fontSizeSmall + 1
            color: Theme.surfaceText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        Row {
            id: saveButtons

            anchors.right: parent.right
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            spacing: 4

            PillButton {
                kind: "text"
                text: "Discard"
                onClicked: tab.reload()
            }

            PillButton {
                kind: "filled"
                text: "Save"
                onClicked: {
                    tab.service.saveRules(tab.rules, tab.service.rulesEnabled, tab.service.speedSource)
                    tab.dirty = false
                }
            }
        }
    }
}
