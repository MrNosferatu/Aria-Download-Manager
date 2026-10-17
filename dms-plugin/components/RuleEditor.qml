import QtQuick
import qs.Common
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/Rules.js" as Rules

//: One automatic action as a form (Revision 2, board 2): labelled groups —
//: Applies to, Trigger, Then, Limits — with the labels in a fixed column and
//: every value in a bordered field. A field that differs from the saved
//: action is tinted with a dot; one that is not valid says why, and the tab
//: holds Save until it is fixed.
//:
//: The form never edits `rule` in place: each change is a new copy handed up
//: through `edited`. Discard rebuilds the editor from the saved action, so no
//: field can keep a value it was typed.
Rectangle {
    id: editor

    property var rule: ({})
    //: The action as last saved; null for one not saved yet.
    property var saved: null
    //: The other actions' names, which this one's must not repeat.
    property var otherNames: []

    property bool showJson: false
    property bool confirmingDelete: false
    //: An option row whose name is still being typed ("Other option…").
    property bool addingOption: false

    signal edited(var rule)
    //: The whole action replaced (Apply JSON): the tab rebuilds the form.
    signal replaced(var rule)
    //: The switch: saved at once by the tab, never part of the unsaved edits.
    signal enabledToggled(bool value)
    signal removed

    readonly property var when: rule.when || ({})
    readonly property var issues: Rules.problems(rule, otherNames)
    readonly property int labelWidth: 120
    readonly property int labelGap: 12
    readonly property string action: rule.action || "pause_resume"

    function value(path) {
        const v = Fmt.getPath(editor.rule, path)
        return v === undefined || v === null ? "" : v
    }

    function changed(path) {
        if (!editor.saved)
            return false
        const a = Fmt.getPath(editor.rule, path)
        const b = Fmt.getPath(editor.saved, path)
        return JSON.stringify(a === undefined || a === "" ? null : a) !== JSON.stringify(b === undefined || b === "" ? null : b)
    }

    function patch(change) {
        const next = JSON.parse(JSON.stringify(editor.rule))
        if (!next.when)
            next.when = {}
        change(next)
        editor.edited(next)
    }

    function set(path, v) {
        patch(r => Fmt.setPath(r, path, v))
    }

    //: Numbers as numbers; anything else kept as typed, so it can be marked.
    function setNumber(path, text) {
        const t = String(text).trim()
        set(path, t === "" ? "" : (isFinite(Number(t)) ? Number(t) : t))
    }

    // ---- applies to ---------------------------------------------------------
    readonly property var statusChoices: [["active", "Active"], ["waiting", "Queued"], ["paused", "Paused"]]
    readonly property var statuses: when.statuses || ["active"]

    function toggleStatus(status) {
        const on = editor.statuses.indexOf(status) >= 0
        const next = editor.statusChoices.map(c => c[0]).filter(s => s === status ? !on : editor.statuses.indexOf(s) >= 0)
        patch(r => r.when.statuses = next)
    }

    readonly property int kindIndex: when.torrent_only ? 1 : (when.http_only ? 2 : 0)

    function setKind(index) {
        patch(r => {
                  delete r.when.torrent_only
                  delete r.when.http_only
                  if (index === 1)
                      r.when.torrent_only = true
                  else if (index === 2)
                      r.when.http_only = true
              })
    }

    // ---- trigger --------------------------------------------------------------
    readonly property string cmp: Rules.blank(when.speed_below) && !Rules.blank(when.speed_above) ? "above" : "below"
    readonly property var speedRaw: cmp === "above" ? when.speed_above : when.speed_below

    function setCmp(word) {
        if (word === editor.cmp)
            return
        const speed = editor.speedRaw
        patch(r => {
                  delete r.when.speed_below
                  delete r.when.speed_above
                  if (!Rules.blank(speed))
                      r.when[word === "above" ? "speed_above" : "speed_below"] = speed
              })
    }

    function setSpeed(raw) {
        const key = editor.cmp === "above" ? "speed_above" : "speed_below"
        patch(r => {
                  delete r.when.speed_below
                  delete r.when.speed_above
                  if (raw !== "")
                      r.when[key] = raw
              })
    }

    // ---- then: the options a "change its options" action sets ---------------
    readonly property var optionKinds: ({
                                            "max-download-limit": ["Download limit", "speed"],
                                            "max-upload-limit": ["Upload limit", "speed"],
                                            "max-connection-per-server": ["Connections", "count"]
                                        })
    readonly property var optionKeys: Object.keys(rule.options || ({}))

    function setOption(key, v) {
        patch(r => {
                  r.options = Object.assign({}, r.options || {})
                  r.options[key] = v
              })
    }

    function removeOption(key) {
        patch(r => {
                  r.options = Object.assign({}, r.options || {})
                  delete r.options[key]
              })
    }

    // ---- limits ---------------------------------------------------------------
    readonly property var setLimits: Rules.LIMITS.filter(l => Rules.limitSet(editor.rule, l[0]))
    readonly property var unsetLimits: Rules.LIMITS.filter(l => !Rules.limitSet(editor.rule, l[0]))
    readonly property var limitWords: ({
                                           "when.min_age_seconds": "start",
                                           "cooldown_seconds": "cooldown",
                                           "max_triggers": "times",
                                           "when.min_progress": "past %",
                                           "when.max_progress": "before %",
                                           "when.connections_below": "connections",
                                           "when.name_matches": "name"
                                       })

    // ---- JSON -----------------------------------------------------------------
    function openJson() {
        jsonField.text = JSON.stringify(editor.rule, null, 2)
        editor.showJson = true
    }

    function applyJson() {
        editor.showJson = false
        editor.replaced(JSON.parse(jsonField.text))
    }

    readonly property string jsonProblem: showJson ? Rules.jsonProblem(jsonField.text) : ""

    implicitHeight: body.implicitHeight + 32
    height: implicitHeight
    radius: 18
    color: confirmingDelete ? Theme.withAlpha(Theme.error, 0.06) : Theme.surfaceContainer
    border.width: 1
    border.color: confirmingDelete ? Theme.withAlpha(Theme.error, 0.5) : Theme.withAlpha(Theme.primary, 0.35)

    // ---- pieces -------------------------------------------------------------
    //: A group's caps heading.
    component Heading: StyledText {
        font.pixelSize: Theme.fontSizeSmall - 1
        font.weight: Font.Bold
        font.letterSpacing: 0.9
        color: Theme.outline
    }

    //: A rule between groups.
    component Rule_: Rectangle {
        height: 1
        color: Theme.outlineVariant
        opacity: 0.7
    }

    //: A label in the fixed column, the control beside it, a dot when it
    //: differs from the saved action and, under it, what is wrong with it.
    component FormRow: Item {
        id: formRow

        property string label: ""
        property bool dirty: false
        property string message: ""
        property int labelWidth: 120
        property int gap: 12
        default property alias control: slot.data

        width: parent ? parent.width : 0
        height: Math.max(36, slot.childrenRect.height) + (message ? 20 : 0)

        StyledText {
            x: 0
            width: formRow.labelWidth
            height: 36
            verticalAlignment: Text.AlignVCenter
            text: formRow.label
            font.pixelSize: Theme.fontSizeSmall + 1
            color: Theme.surfaceVariantText
            wrapMode: Text.NoWrap
            elide: Text.ElideRight
        }

        Row {
            id: slot

            x: formRow.labelWidth + formRow.gap
            spacing: 8
        }

        Rectangle {
            x: slot.x + slot.childrenRect.width + 8
            y: 14
            width: 8
            height: 8
            radius: 4
            visible: formRow.dirty
            color: Theme.primary
        }

        StyledText {
            x: slot.x
            y: Math.max(36, slot.childrenRect.height) + 3
            visible: formRow.message !== ""
            text: formRow.message
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.error
        }
    }

    //: Words after a control: "seconds", "% done".
    component Unit: StyledText {
        height: 36
        verticalAlignment: Text.AlignVCenter
        font.pixelSize: Theme.fontSizeSmall + 1
        color: Theme.surfaceVariantText
    }

    //: An × at the end of a row that removes it.
    component RemoveButton: DankActionButton {
        buttonSize: 32
        iconSize: 18
        iconName: "close"
        iconColor: Theme.outline
    }

    //: A dashed pill that adds a row and opens a menu of what can be added.
    component AddPill: Item {
        id: addPill

        property string text: ""
        property string hint: ""
        //: The hint is cut short rather than running out of the card.
        property real maximumWidth: 10000
        signal clicked

        width: Math.min(addRow.implicitWidth + 24, maximumWidth)
        height: 34

        Canvas {
            anchors.fill: parent

            property color tint: addArea.containsMouse ? Theme.surfaceText : Theme.outline

            onTintChanged: requestPaint()
            onWidthChanged: requestPaint()
            onPaint: {
                const ctx = getContext("2d")
                ctx.reset()
                const r = (height - 1) / 2
                ctx.strokeStyle = tint
                ctx.lineWidth = 1
                ctx.setLineDash([4, 3])
                ctx.beginPath()
                ctx.moveTo(r + 0.5, 0.5)
                ctx.lineTo(width - r - 0.5, 0.5)
                ctx.arc(width - r - 0.5, r + 0.5, r, -Math.PI / 2, Math.PI / 2)
                ctx.lineTo(r + 0.5, height - 0.5)
                ctx.arc(r + 0.5, r + 0.5, r, Math.PI / 2, Math.PI * 1.5)
                ctx.stroke()
            }
        }

        Row {
            id: addRow

            anchors.verticalCenter: parent.verticalCenter
            x: 10
            spacing: 6

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "add"
                size: 18
                color: Theme.surfaceText
            }

            StyledText {
                id: addLabel

                anchors.verticalCenter: parent.verticalCenter
                text: addPill.text
                font.pixelSize: Theme.fontSizeSmall + 1
                color: Theme.surfaceText
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: addPill.hint !== ""
                width: Math.min(implicitWidth, addPill.maximumWidth - 24 - addRow.spacing * 2 - 18 - addLabel.implicitWidth)
                text: "· " + addPill.hint
                font.pixelSize: Theme.fontSizeSmall + 1
                color: Theme.outline
                wrapMode: Text.NoWrap
                elide: Text.ElideRight
            }
        }

        MouseArea {
            id: addArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: addPill.clicked()
        }
    }

    Column {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.margins: 16
        anchors.topMargin: 14
        spacing: 14

        // ---- header: on/off, the name, JSON, delete --------------------------
        Item {
            width: parent.width
            height: 54
            visible: !editor.confirmingDelete

            BoolSwitch {
                id: ruleSwitch

                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.bottomMargin: 2
                width: 52
                height: 32
                checked: editor.rule.enabled !== false
                onToggled: value => editor.enabledToggled(value)
            }

            StyledText {
                anchors.left: nameField.left
                anchors.top: parent.top
                text: "Name"
                font.pixelSize: Theme.fontSizeSmall - 1
                color: Theme.outline
            }

            FormText {
                id: nameField

                anchors.left: ruleSwitch.right
                anchors.leftMargin: 10
                anchors.right: headButtons.left
                anchors.rightMargin: 8
                anchors.bottom: parent.bottom
                implicitHeight: 34
                bold: true
                text: editor.rule.name || ""
                placeholderText: "Name this action"
                changed: editor.changed("name")
                invalid: !!editor.issues["name"]
                onEdited: text => editor.set("name", text.trim())
            }

            Row {
                id: headButtons

                anchors.right: parent.right
                anchors.bottom: parent.bottom
                spacing: 2

                DankActionButton {
                    buttonSize: 36
                    iconSize: 20
                    iconName: editor.showJson ? "edit_note" : "data_object"
                    iconColor: Theme.surfaceVariantText
                    tooltipText: editor.showJson ? "Back to the form" : "Edit as JSON"
                    onClicked: editor.showJson ? (editor.showJson = false) : editor.openJson()
                }

                DankActionButton {
                    buttonSize: 36
                    iconSize: 20
                    iconName: "delete"
                    iconColor: Theme.error
                    tooltipText: "Delete action"
                    onClicked: editor.confirmingDelete = true
                }
            }
        }

        StyledText {
            visible: !editor.confirmingDelete && !!editor.issues["name"]
            leftPadding: 62
            topPadding: -10
            text: editor.issues["name"] || ""
            font.pixelSize: Theme.fontSizeSmall - 1
            color: Theme.error
        }

        // ---- deleting: says what goes, takes effect on save -----------------
        Column {
            width: parent.width
            visible: editor.confirmingDelete
            spacing: 6

            StyledText {
                text: "Delete “" + (editor.rule.name || "this action") + "”?"
                font.pixelSize: Theme.fontSizeMedium + 1
                font.weight: Font.Bold
                color: Theme.surfaceText
            }

            StyledText {
                width: parent.width
                wrapMode: Text.WordWrap
                text: "This takes effect when you save."
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.surfaceVariantText
            }

            Row {
                topPadding: 4
                spacing: 6

                PillButton {
                    size: 32
                    kind: "dangerFilled"
                    text: "Delete"
                    onClicked: {
                        editor.confirmingDelete = false
                        editor.removed()
                    }
                }

                PillButton {
                    size: 32
                    kind: "text"
                    text: "Keep"
                    onClicked: editor.confirmingDelete = false
                }
            }
        }

        // ---- the form -------------------------------------------------------
        Column {
            width: parent.width
            visible: !editor.confirmingDelete && !editor.showJson
            spacing: 14

            // Applies to
            Column {
                width: parent.width
                spacing: 8

                Heading {
                    text: "APPLIES TO"
                }

                FormRow {
                    label: "Downloads that are"
                    labelWidth: editor.labelWidth
                    dirty: editor.changed("when.statuses")
                    message: editor.issues["when.statuses"] || ""

                    Repeater {
                        model: editor.statusChoices

                        Rectangle {
                            id: statusChip

                            required property var modelData
                            readonly property bool on: editor.statuses.indexOf(modelData[0]) >= 0

                            width: chipRow.implicitWidth + 24
                            height: 32
                            y: 2
                            radius: 10
                            color: on ? Theme.secondaryContainer : (chipArea.containsMouse ? Theme.withAlpha(Theme.surfaceText, 0.06) : "transparent")
                            border.width: on ? 0 : 1
                            border.color: Theme.outlineVariant

                            Row {
                                id: chipRow

                                anchors.centerIn: parent
                                spacing: 4

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    visible: statusChip.on
                                    name: "check"
                                    size: 16
                                    color: Theme.surfaceText
                                }

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: statusChip.modelData[1]
                                    font.pixelSize: Theme.fontSizeSmall + 1
                                    font.weight: statusChip.on ? Font.DemiBold : Font.Medium
                                    color: statusChip.on ? Theme.surfaceText : Theme.surfaceVariantText
                                }
                            }

                            MouseArea {
                                id: chipArea

                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: editor.toggleStatus(statusChip.modelData[0])
                            }
                        }
                    }
                }

                FormRow {
                    label: "Kind"
                    labelWidth: editor.labelWidth
                    dirty: editor.changed("when.torrent_only") || editor.changed("when.http_only")

                    Segmented {
                        y: 2
                        color: Theme.surfaceContainerHigh
                        model: ["Any", "Torrents", "Normal"]
                        currentIndex: editor.kindIndex
                        onPicked: index => editor.setKind(index)
                    }
                }
            }

            Rule_ {
                width: parent.width
            }

            // Trigger
            Column {
                width: parent.width
                spacing: 8

                Heading {
                    text: "TRIGGER"
                }

                FormRow {
                    label: "Speed stays"
                    labelWidth: editor.labelWidth
                    dirty: editor.changed("when.speed_below") || editor.changed("when.speed_above")
                    message: editor.issues["when.speed"] || ""

                    FormSelect {
                        labels: ["below", "above"]
                        currentIndex: editor.cmp === "above" ? 1 : 0
                        onPicked: index => editor.setCmp(index === 1 ? "above" : "below")
                    }

                    FormSpeed {
                        raw: editor.speedRaw === undefined ? "" : editor.speedRaw
                        placeholderText: "none"
                        changed: editor.changed("when.speed_below") || editor.changed("when.speed_above")
                        invalid: !!editor.issues["when.speed"] && !Rules.blank(editor.speedRaw)
                        onEdited: raw => editor.setSpeed(raw)
                    }
                }

                FormRow {
                    label: "For at least"
                    labelWidth: editor.labelWidth
                    dirty: editor.changed("when.for_seconds")
                    message: editor.issues["when.for_seconds"] || ""

                    FormStepper {
                        value: String(editor.value("when.for_seconds") === "" ? 0 : editor.value("when.for_seconds"))
                        changed: editor.changed("when.for_seconds")
                        onEdited: v => editor.setNumber("when.for_seconds", v)
                    }

                    Unit {
                        text: "seconds"
                    }
                }
            }

            Rule_ {
                width: parent.width
            }

            // Then
            Column {
                width: parent.width
                spacing: 8

                Heading {
                    text: "THEN"
                }

                FormRow {
                    label: "Do"
                    labelWidth: editor.labelWidth
                    dirty: editor.changed("action")

                    FormSelect {
                        width: Math.min(280, editor.width - editor.labelWidth - 80)
                        labels: Rules.ACTION_LABELS
                        currentIndex: Math.max(0, Rules.ACTION_VALUES.indexOf(editor.action))
                        changed: editor.changed("action")
                        onPicked: index => editor.set("action", Rules.ACTION_VALUES[index])
                    }
                }

                FormRow {
                    visible: Rules.resumes(editor.action)
                    label: "Resume after"
                    labelWidth: editor.labelWidth
                    dirty: editor.changed("resume_after_seconds")
                    message: editor.issues["resume_after_seconds"] || ""

                    FormStepper {
                        step: 0.5
                        value: String(editor.value("resume_after_seconds") === "" ? 0 : editor.value("resume_after_seconds"))
                        changed: editor.changed("resume_after_seconds")
                        onEdited: v => editor.setNumber("resume_after_seconds", v)
                    }

                    Unit {
                        text: "seconds"
                    }

                    Unit {
                        visible: Number(editor.value("resume_after_seconds") || 0) === 0
                        text: "0 = straight back"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.warning
                    }
                }

                // The options a "change its options" action sets, one row each.
                Repeater {
                    model: editor.action === "set_option" ? editor.optionKeys : []

                    Item {
                        id: optionRow

                        required property string modelData
                        readonly property var kind: editor.optionKinds[modelData] || [modelData, "text"]

                        width: parent.width
                        height: 36

                        StyledText {
                            width: editor.labelWidth
                            height: 36
                            verticalAlignment: Text.AlignVCenter
                            text: optionRow.kind[0]
                            font.pixelSize: optionRow.kind[1] === "text" ? Theme.fontSizeSmall : Theme.fontSizeSmall + 1
                            font.family: optionRow.kind[1] === "text" ? "monospace" : Theme.fontFamily
                            color: Theme.surfaceVariantText
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }

                        Loader {
                            x: editor.labelWidth + editor.labelGap
                            sourceComponent: optionRow.kind[1] === "speed" ? optionSpeed : (optionRow.kind[1] === "count" ? optionCount : optionText)
                        }

                        Component {
                            id: optionSpeed

                            FormSpeed {
                                raw: editor.rule.options[optionRow.modelData]
                                placeholderText: "none"
                                changed: editor.changed("options." + optionRow.modelData)
                                onEdited: raw => editor.setOption(optionRow.modelData, raw === "" ? "0" : String(raw))
                            }
                        }

                        Component {
                            id: optionCount

                            FormStepper {
                                minimum: 1
                                maximum: 16
                                value: String(editor.rule.options[optionRow.modelData])
                                changed: editor.changed("options." + optionRow.modelData)
                                onEdited: v => editor.setOption(optionRow.modelData, v)
                            }
                        }

                        Component {
                            id: optionText

                            FormText {
                                width: 180
                                mono: true
                                text: String(editor.rule.options[optionRow.modelData])
                                placeholderText: "value"
                                changed: editor.changed("options." + optionRow.modelData)
                                onEdited: text => editor.setOption(optionRow.modelData, text)
                            }
                        }

                        RemoveButton {
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            tooltipText: "Stop changing " + optionRow.kind[0]
                            onClicked: editor.removeOption(optionRow.modelData)
                        }
                    }
                }

                //: "Other option…": its aria2 name first, then its value.
                Item {
                    width: parent.width
                    height: 36
                    visible: editor.action === "set_option" && editor.addingOption

                    FormText {
                        id: newOptionKey

                        x: editor.labelWidth + editor.labelGap
                        width: 220
                        mono: true
                        placeholderText: "aria2 option, e.g. split"
                        onEditingFinished: {
                            const key = text.trim()
                            if (key) {
                                editor.setOption(key, "")
                                text = ""
                            }
                            editor.addingOption = false
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: 34
                    visible: editor.action === "set_option"

                    AddPill {
                        id: addOption

                        x: editor.labelWidth + editor.labelGap
                        text: "Add an option"
                        onClicked: optionMenu.toggle()

                        MenuPopup {
                            id: optionMenu

                            menuWidth: 220
                            readonly property var known: Object.keys(editor.optionKinds).filter(k => editor.optionKeys.indexOf(k) < 0)
                            entries: known.map(k => ({
                                                         "text": editor.optionKinds[k][0]
                                                     })).concat([{
                                                                     "text": "Other option…"
                                                                 }])
                            onTriggered: index => {
                                if (index < known.length) {
                                    const key = known[index]
                                    editor.setOption(key, editor.optionKinds[key][1] === "count" ? "4" : "2M")
                                } else {
                                    editor.addingOption = true
                                    newOptionKey.focusInput()
                                }
                            }
                        }
                    }

                    StyledText {
                        anchors.left: addOption.right
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !!editor.issues["options"]
                        text: editor.issues["options"] || ""
                        font.pixelSize: Theme.fontSizeSmall - 1
                        color: Theme.error
                    }
                }
            }

            Rule_ {
                width: parent.width
            }

            // Limits
            Column {
                width: parent.width
                spacing: 8

                Heading {
                    text: "LIMITS"
                }

                StyledText {
                    visible: editor.setLimits.length === 0
                    text: "None: it may run on any download, any number of times."
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.outline
                }

                Repeater {
                    model: editor.setLimits

                    Item {
                        id: limitRow

                        required property var modelData
                        readonly property string path: modelData[0]
                        readonly property string message: editor.issues[path] || ""

                        width: parent.width
                        height: 36 + (message ? 20 : 0)

                        StyledText {
                            width: editor.labelWidth
                            height: 36
                            verticalAlignment: Text.AlignVCenter
                            text: limitRow.modelData[1]
                            font.pixelSize: Theme.fontSizeSmall + 1
                            color: Theme.surfaceVariantText
                            wrapMode: Text.NoWrap
                            elide: Text.ElideRight
                        }

                        Row {
                            id: limitControl

                            x: editor.labelWidth + editor.labelGap
                            spacing: 8

                            Loader {
                                sourceComponent: limitRow.modelData[4] === "text" ? limitText : limitNumber
                            }

                            Unit {
                                text: limitRow.modelData[2]
                            }
                        }

                        Rectangle {
                            x: limitControl.x + limitControl.width + 8
                            y: 14
                            width: 8
                            height: 8
                            radius: 4
                            visible: editor.changed(limitRow.path)
                            color: Theme.primary
                        }

                        Component {
                            id: limitNumber

                            FormStepper {
                                step: limitRow.modelData[5] || 1
                                maximum: limitRow.path.indexOf("progress") >= 0 ? 100 : 0
                                value: String(editor.value(limitRow.path))
                                changed: editor.changed(limitRow.path)
                                onEdited: v => editor.setNumber(limitRow.path, v)
                            }
                        }

                        Component {
                            id: limitText

                            FormText {
                                width: 180
                                mono: true
                                text: String(editor.value(limitRow.path))
                                changed: editor.changed(limitRow.path)
                                invalid: limitRow.message !== ""
                                onEdited: text => editor.set(limitRow.path, text)
                            }
                        }

                        StyledText {
                            x: limitControl.x
                            y: 39
                            visible: limitRow.message !== ""
                            text: limitRow.message
                            font.pixelSize: Theme.fontSizeSmall - 1
                            color: Theme.error
                        }

                        RemoveButton {
                            anchors.right: parent.right
                            y: 2
                            tooltipText: "Remove “" + limitRow.modelData[1] + "”"
                            onClicked: editor.set(limitRow.path, "")
                        }
                    }
                }

                Item {
                    width: parent.width
                    height: 34
                    visible: editor.unsetLimits.length > 0

                    AddPill {
                        x: editor.labelWidth + editor.labelGap
                        maximumWidth: parent.width - x
                        text: "Add a limit"
                        hint: editor.unsetLimits.map(l => editor.limitWords[l[0]]).join(", ")
                        onClicked: limitMenu.toggle()

                        MenuPopup {
                            id: limitMenu

                            menuWidth: 280
                            entries: editor.unsetLimits.map(l => ({
                                                                      "text": l[1],
                                                                      "detail": l[2]
                                                                  }))
                            onTriggered: index => {
                                const l = editor.unsetLimits[index]
                                editor.set(l[0], l[3])
                            }
                        }
                    }
                }
            }

            // Note
            Column {
                width: parent.width
                topPadding: 2
                spacing: 4

                StyledText {
                    text: "Note"
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.outline
                }

                FormText {
                    width: parent.width
                    text: editor.rule.description || ""
                    placeholderText: "What this action is for (optional)"
                    changed: editor.changed("description")
                    onEdited: text => editor.set("description", text)
                }
            }
        }

        // ---- raw JSON, behind { } -----------------------------------------
        Rectangle {
            width: parent.width
            visible: !editor.confirmingDelete && editor.showJson
            height: Math.max(140, jsonField.contentHeight + 24)
            radius: 10
            color: Theme.surfaceContainerLowest

            TextEdit {
                id: jsonField

                anchors.fill: parent
                anchors.margins: 12
                color: Theme.surfaceText
                selectByMouse: true
                selectionColor: Theme.primarySelected
                //: Long values wrap rather than run out of the box.
                wrapMode: TextEdit.Wrap
                font.pixelSize: Theme.fontSizeSmall - 0.5
                font.family: "monospace"
            }
        }

        Row {
            visible: !editor.confirmingDelete && editor.showJson && editor.jsonProblem !== ""
            spacing: 6

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "error"
                size: 16
                color: Theme.error
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: editor.jsonProblem
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
            }
        }

        Row {
            anchors.right: parent.right
            visible: !editor.confirmingDelete && editor.showJson
            spacing: 6

            PillButton {
                size: 36
                kind: "text"
                text: "Discard"
                onClicked: editor.showJson = false
            }

            PillButton {
                size: 36
                kind: "filled"
                text: "Apply JSON"
                enabled: editor.jsonProblem === ""
                onClicked: editor.applyJson()
            }
        }
    }
}
