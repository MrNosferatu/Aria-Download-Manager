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
    //: The rules as last saved: what each field is compared against, and
    //: what Discard goes back to.
    property var saved: []
    //: One card open at a time; -1 for none.
    property int openIndex: -1
    //: The wide window: the list on the left, the open action's editor and
    //: its own trigger history on the right.
    property bool wide: false
    //: Bumped by Discard and Apply JSON: the editor is built again from the
    //: rule, so no field keeps a value it was typed.
    property int resetRev: 0

    //: Each edited rule's name on the manager, "" for one not saved yet: the
    //: switch saves at once under that name even after an unsaved rename.
    property var origins: []

    readonly property int onCount: rules.filter(r => r.enabled !== false).length
    readonly property bool masterOn: !!service && service.rulesEnabled

    function savedFor(index) {
        const name = origins[index] || ""
        return name ? (saved.find(r => r.name === name) || null) : null
    }

    function othersOf(index) {
        return rules.filter((r, i) => i !== index).map(r => String(r.name || "").trim())
    }

    //: Values that differ from the saved rules, counting a removed or new
    //: action as one.
    readonly property int changeTotal: {
        let n = saved.filter(r => origins.indexOf(r.name) < 0).length
        for (let i = 0; i < rules.length; i++)
            n += Rules.changeCount(rules[i], savedFor(i))
        return n
    }
    readonly property bool dirty: changeTotal > 0
    //: Which actions have a field Save must wait for.
    readonly property bool blocked: rules.some((r, i) => Object.keys(Rules.problems(r, othersOf(i))).length > 0)
    //: The popout shows the open action instead of the list (board 2).
    readonly property bool editing: !wide && openIndex >= 0 && openIndex < rules.length

    function replaceAt(index, rule, rebuild) {
        const next = rules.slice()
        next[index] = rule
        rules = next
        saving = false
        if (rebuild)
            resetRev++
    }

    //: Set while our own save is on its way, so its answer reloads the tab.
    property bool saving: false

    function save() {
        saving = true
        service.saveRules(rules, service.rulesEnabled, service.speedSource)
    }

    //: Leaving the editor with unsaved edits asks once: Save, Discard or Keep
    //: editing. `then` is where it was going.
    function leave(then) {
        if (!dirty) {
            then()
            return
        }
        leavePrompt.then = then
        leavePrompt.visible = true
    }

    readonly property int scrollbarGutter: Layout.SCROLLBAR_GUTTER

    readonly property var speedValues: ["hybrid", "measured", "aria2"]
    readonly property var speedLabels: ["Hybrid", "Disk writes", "aria2 reported"]

    function reload() {
        if (!service)
            return
        // Edit a copy: the service keeps the server's version until we save.
        saved = JSON.parse(JSON.stringify(service.rules || []))
        rules = JSON.parse(JSON.stringify(service.rules || []))
        origins = rules.map(r => r.name)
        resetRev++
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
    }

    //: The switch on a row (or in the editor) saves straight away, like the
    //: master switch: it is never one of the unsaved edits. Only an action
    //: that is not on the manager yet waits for Save with the rest of it.
    function setEnabled(index, value) {
        const next = JSON.parse(JSON.stringify(rules))
        next[index].enabled = value
        rules = next
        const name = origins[index] || ""
        if (!name || !service)
            return
        saved = saved.map(r => r.name === name ? Object.assign({}, r, {
                                                                     "enabled": value
                                                                 }) : r)
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
            // A reload from elsewhere never wipes edits; our own save's does.
            if (!tab.dirty || tab.saving)
                tab.reload()
            tab.saving = false
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
        height: tab.editing ? 0 : masterColumn.implicitHeight + 32
        visible: !tab.editing
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
        height: tab.rules.length && !tab.editing ? 20 : 0
        visible: tab.rules.length > 0 && !tab.editing

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
        visible: !tab.editing
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
                    current: tab.wide && tab.openIndex === ruleCard.index
                    //: Master off: the whole list dims, still editable.
                    opacity: tab.masterOn ? 1 : 0.6
                    onRemoved: tab.removeAt(ruleCard.index)
                    onDuplicated: tab.duplicateAt(ruleCard.index)
                    onEnabledToggled: value => tab.setEnabled(ruleCard.index, value)
                    onToggleOpen: {
                        if (tab.openIndex === ruleCard.index)
                            return
                        if (tab.wide)
                            tab.leave(() => tab.openIndex = ruleCard.index)
                        else
                            tab.openIndex = ruleCard.index
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

    // ---- the open action: beside the list, or in its place (board 2) -------
    DankFlickable {
        id: editorFlick

        anchors.top: parent.top
        anchors.bottom: saveBar.visible ? saveBar.top : parent.bottom
        anchors.bottomMargin: saveBar.visible ? 12 : 0
        anchors.left: tab.wide ? listFlick.right : parent.left
        anchors.leftMargin: tab.wide ? 16 : 0
        anchors.right: parent.right
        visible: tab.wide || tab.editing
        clip: true
        contentHeight: editorColumn.implicitHeight
        contentWidth: width

        Column {
            id: editorColumn

            readonly property var rule: tab.openIndex >= 0 && tab.openIndex < tab.rules.length ? tab.rules[tab.openIndex] : null

            width: parent.width - tab.scrollbarGutter
            spacing: 10

            //: In the popout the editor takes the list's place; this is the
            //: way back to it.
            Item {
                width: parent.width
                height: 36
                visible: !tab.wide

                Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 4

                    DankActionButton {
                        anchors.verticalCenter: parent.verticalCenter
                        buttonSize: 36
                        iconSize: 22
                        iconName: "arrow_back"
                        iconColor: Theme.surfaceVariantText
                        tooltipText: "Back to actions"
                        onClicked: tab.leave(() => tab.openIndex = -1)
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Actions"
                        font.pixelSize: Theme.fontSizeSmall + 1
                        color: Theme.surfaceVariantText
                    }
                }
            }

            StyledText {
                width: parent.width
                visible: tab.wide && !editorColumn.rule
                topPadding: Theme.spacingXL
                horizontalAlignment: Text.AlignHCenter
                wrapMode: Text.WordWrap
                text: tab.rules.length ? "Pick an action on the left to edit it." : "Start from a template on the left."
                font.pixelSize: Theme.fontSizeMedium
                color: Theme.surfaceVariantText
            }

            //: Rebuilt from the rule on Discard (resetRev), so no field keeps
            //: a value it was typed.
            Repeater {
                model: editorColumn.rule ? [tab.openIndex + ":" + tab.resetRev] : []

                RuleEditor {
                    width: editorColumn.width
                    rule: editorColumn.rule
                    saved: tab.savedFor(tab.openIndex)
                    otherNames: tab.othersOf(tab.openIndex)
                    onEdited: rule => tab.replaceAt(tab.openIndex, rule, false)
                    onReplaced: rule => tab.replaceAt(tab.openIndex, rule, true)
                    onEnabledToggled: value => tab.setEnabled(tab.openIndex, value)
                    onRemoved: tab.removeAt(tab.openIndex)
                }
            }

            //: This action's own history, in a card under the editor.
            Rectangle {
                width: parent.width
                visible: tab.wide && !!editorColumn.rule
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
    //: Appears only when there is something to save; Save waits while a field
    //: is marked as not valid.
    Rectangle {
        id: saveBar

        readonly property var changedNames: {
            const out = []
            for (let i = 0; i < tab.rules.length; i++) {
                if (Rules.changeCount(tab.rules[i], tab.savedFor(i)) > 0)
                    out.push(tab.rules[i].name || "an action")
            }
            return out
        }

        anchors.bottom: parent.bottom
        width: parent.width - tab.scrollbarGutter
        height: 52
        visible: tab.dirty
        radius: 16
        color: Theme.inverseSurface

        StyledText {
            anchors.left: parent.left
            anchors.leftMargin: 16
            anchors.right: saveButtons.left
            anchors.rightMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            text: {
                if (tab.blocked)
                    return "Fix the marked fields to save"
                const n = tab.changeTotal
                const what = n === 1 ? "1 unsaved change" : n + " unsaved changes"
                return saveBar.changedNames.length === 1 ? what + " to " + saveBar.changedNames[0] : what
            }
            font.pixelSize: Theme.fontSizeSmall + 1
            font.weight: Font.Medium
            color: Theme.inverseOnSurface
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
                kind: "inverseText"
                text: "Discard"
                onClicked: tab.reload()
            }

            PillButton {
                kind: "inverseFilled"
                text: "Save"
                enabled: !tab.blocked
                onClicked: tab.save()
            }
        }
    }

    // ---- leaving with unsaved edits -----------------------------------------
    //: Asked once, on the way out of the editor: Save, Discard or Keep editing.
    Rectangle {
        id: leavePrompt

        property var then: null

        anchors.fill: parent
        visible: false
        color: Theme.withAlpha(Theme.surface, 0.6)
        z: 20

        MouseArea {
            anchors.fill: parent
            onClicked: leavePrompt.visible = false
        }

        Rectangle {
            anchors.centerIn: parent
            width: Math.min(parent.width - 32, 380)
            height: promptColumn.implicitHeight + 40
            radius: 24
            color: Theme.surfaceContainerHigh

            MouseArea {
                anchors.fill: parent
            }

            Column {
                id: promptColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 20
                spacing: 8

                StyledText {
                    width: parent.width
                    text: saveBar.changedNames.length === 1 ? "Save changes to " + saveBar.changedNames[0] + "?" : "Save your changes?"
                    font.pixelSize: Theme.fontSizeLarge
                    font.weight: Font.Bold
                    color: Theme.surfaceText
                    wrapMode: Text.WordWrap
                }

                StyledText {
                    width: parent.width
                    text: tab.blocked ? "Some fields are not valid yet, so they can only be discarded or fixed."
                                      : (tab.changeTotal === 1 ? "1 unsaved change." : tab.changeTotal + " unsaved changes.")
                    font.pixelSize: Theme.fontSizeSmall + 1
                    color: Theme.surfaceVariantText
                    wrapMode: Text.WordWrap
                }

                Row {
                    anchors.right: parent.right
                    topPadding: 8
                    spacing: 4

                    PillButton {
                        kind: "text"
                        text: "Keep editing"
                        onClicked: leavePrompt.visible = false
                    }

                    PillButton {
                        kind: "text"
                        text: "Discard"
                        onClicked: {
                            leavePrompt.visible = false
                            tab.reload()
                            if (leavePrompt.then)
                                leavePrompt.then()
                        }
                    }

                    PillButton {
                        kind: "filled"
                        text: "Save"
                        enabled: !tab.blocked
                        onClicked: {
                            leavePrompt.visible = false
                            tab.save()
                            if (leavePrompt.then)
                                leavePrompt.then()
                        }
                    }
                }
            }
        }
    }
}
