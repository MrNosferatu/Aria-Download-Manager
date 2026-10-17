import QtQuick
import qs.Common
import qs.Services
import qs.Widgets
import "../lib/Fmt.js" as Fmt
import "../lib/Rules.js" as Rules
import "../lib/Units.js" as Units

//: One automatic action. Folded, it is one row: its on/off switch, its name
//: and what it does in words. Open, the four things that matter read
//: as a sentence with editable words in it; the optional conditions are chips
//: that can be added and removed; the raw JSON is behind { }.
Rectangle {
    id: card

    property var rule: ({})
    property int ruleIndex: 0
    property bool open: false
    //: Bumped by the tab when another card showing the same rule edits it
    //: (the wide window shows a rule in the list and in the editor at once).
    property int externalRev: 0
    //: Marked as the one being edited beside the list.
    property bool current: false

    property bool showJson: false
    property bool confirmingDelete: false

    signal removed
    signal edited
    signal toggleOpen
    signal duplicated
    //: The switch: saved at once by the tab, never part of the unsaved edits.
    signal enabledToggled(bool value)

    readonly property bool on: card.rule.enabled !== false

    //: The rule object is edited in place, so bindings that read it go
    //: through this counter to notice.
    property int rev: 0

    readonly property var when: {
        card.rev
        return card.rule.when || ({})
    }

    function value(path) {
        card.rev
        const v = Fmt.getPath(card.rule, path)
        return v === undefined || v === null ? "" : v
    }

    function set(path, v) {
        Fmt.setPath(card.rule, path, v)
        card.rev++
        card.edited()
    }

    function setNumber(path, text) {
        const t = String(text).trim()
        set(path, t === "" ? "" : (isFinite(Number(t)) ? Number(t) : t))
    }

    readonly property string summary: {
        card.rev
        card.externalRev
        return Rules.summary(card.rule)
    }

    // ---- the sentence's choices -------------------------------------------
    readonly property var statusPresets: [["active", ["active"]], ["waiting", ["waiting"]], ["paused", ["paused"]],
        ["active or waiting", ["active", "waiting"]], ["unfinished", ["active", "waiting", "paused"]]]
    readonly property string statusWord: {
        const now = (card.when.statuses || ["active"]).slice().sort().join(",")
        for (const p of statusPresets)
            if (p[1].slice().sort().join(",") === now)
                return p[0]
        return (card.when.statuses || ["active"]).join(" or ")
    }
    readonly property var statusWords: {
        const out = statusPresets.map(p => p[0])
        if (out.indexOf(statusWord) === -1)
            out.push(statusWord)
        return out
    }

    readonly property string kindWord: card.when.torrent_only ? "torrent" : (card.when.http_only ? "normal download" : "download")

    //: What the main condition watches: the speed falling below a figure,
    //: rising above one, or the connections thinning out.
    readonly property string mode: {
        if (card.when.speed_above !== undefined && card.when.speed_above !== "")
            return "above"
        if ((card.when.speed_below === undefined || card.when.speed_below === "")
                && card.when.connections_below !== undefined && card.when.connections_below !== "")
            return "connections"
        return "below"
    }
    readonly property var modeWords: ["below", "above", "with few connections"]

    function setMode(word) {
        const speed = card.value("when.speed_below") || card.value("when.speed_above") || 51200
        if (word === "below") {
            Fmt.setPath(card.rule, "when.speed_above", "")
            set("when.speed_below", speed)
        } else if (word === "above") {
            Fmt.setPath(card.rule, "when.speed_below", "")
            set("when.speed_above", speed)
        } else {
            Fmt.setPath(card.rule, "when.speed_below", "")
            Fmt.setPath(card.rule, "when.speed_above", "")
            set("when.connections_below", card.value("when.connections_below") || 2)
        }
    }

    readonly property var actionValues: ["pause_resume", "force_pause_resume", "restart", "set_option", "stop", "log_only"]
    readonly property var actionWords: actionValues.map(v => Rules.ACTION_WORDS[v])
    readonly property bool resumes: (card.rule.action || "pause_resume").indexOf("pause_resume") >= 0

    // ---- optional conditions ------------------------------------------------
    readonly property var conditions: [
        {
            "path": "when.min_age_seconds",
            "pre": "Ignore the first",
            "unit": "s",
            "start": 8
        },
        {
            "path": "cooldown_seconds",
            "pre": "Cooldown",
            "unit": "s",
            "start": 25
        },
        {
            "path": "max_triggers",
            "pre": "At most",
            "unit": "times",
            "start": 5
        },
        {
            "path": "when.min_progress",
            "pre": "Only past",
            "unit": "%",
            "start": 5
        },
        {
            "path": "when.max_progress",
            "pre": "Only before",
            "unit": "%",
            "start": 95
        },
        {
            "path": "when.connections_below",
            "pre": "Under",
            "unit": "connections",
            "start": 2
        },
        {
            "path": "when.name_matches",
            "pre": "Name matches",
            "unit": "",
            "start": "\\.iso$",
            "text": true
        }
    ]
    //: Whether a condition is in force. The connections figure is the
    //: sentence's own when it is the main condition, and "at most 0 times"
    //: is how config.yaml says "no limit".
    function isSet(c) {
        const v = card.value(c.path)
        if (v === "" || (c.path === "max_triggers" && Number(v) === 0))
            return false
        return true
    }
    readonly property var setConditions: {
        card.rev
        return conditions.filter(c => isSet(c) && !(c.path === "when.connections_below" && card.mode === "connections"))
    }
    readonly property var unsetConditions: {
        card.rev
        return conditions.filter(c => !isSet(c) && !(c.path === "when.connections_below" && card.mode === "connections"))
    }

    readonly property var optionKeys: {
        card.rev
        return Object.keys(card.rule.options || ({}))
    }

    function addOption(key, v) {
        const options = Object.assign({}, card.rule.options || ({}))
        options[key] = v
        card.rule.options = options
        card.rev++
        card.edited()
    }

    function removeOption(key) {
        const options = Object.assign({}, card.rule.options || ({}))
        delete options[key]
        card.rule.options = options
        card.rev++
        card.edited()
    }

    function openJson() {
        jsonField.text = JSON.stringify(card.rule, null, 2)
        card.showJson = true
    }

    function applyJson() {
        const parsed = JSON.parse(jsonField.text)
        for (const key in card.rule)
            delete card.rule[key]
        for (const key in parsed)
            card.rule[key] = parsed[key]
        card.showJson = false
        card.rev++
        card.edited()
    }

    readonly property string jsonProblem: showJson ? Rules.jsonProblem(jsonField.text) : ""

    height: open ? body.implicitHeight + 32 : Math.max(64, body.implicitHeight + 20)
    radius: open ? 16 : 14
    //: Open, the card is an outline on the panel; deleting, it turns into
    //: the question (board 18).
    color: confirming ? Theme.withAlpha(Theme.error, 0.06) : (open ? "transparent" : Theme.surfaceContainer)
    border.width: open || current || needsOptions ? 1 : 0
    border.color: confirming ? Theme.withAlpha(Theme.error, 0.5)
                             : (needsOptions ? Theme.withAlpha(Theme.warning, 0.6) : Theme.primary)
    readonly property bool confirming: open && confirmingDelete
    //: An off action dims its words and says Off; the switch stays clear.

    readonly property bool needsOptions: card.rule.action === "set_option" && optionKeys.length === 0

    // ---- inline pieces of the sentence (board 7) ----------------------------
    //: A word of the sentence.
    component Word: StyledText {
        height: 30
        verticalAlignment: Text.AlignVCenter
        font.pixelSize: Theme.fontSizeMedium + 1
        color: Theme.surfaceText
    }

    //: A choice inside the sentence: the word and a ▾, opening a menu.
    component TokenMenu: Rectangle {
        id: tokenMenu

        property string text: ""
        property var options: []

        signal picked(int index)

        width: tokenRow.implicitWidth + 12
        height: 30
        radius: 7
        color: tokenArea.containsMouse ? Qt.lighter(Theme.surfaceContainerHighest, 1.15) : Theme.surfaceContainerHighest

        Row {
            id: tokenRow

            anchors.centerIn: parent
            spacing: 2

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: tokenMenu.text
                font.pixelSize: Theme.fontSizeSmall + 1
                font.weight: Font.DemiBold
                color: Theme.surfaceText
            }

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "arrow_drop_down"
                size: 16
                color: Theme.surfaceVariantText
            }
        }

        MouseArea {
            id: tokenArea

            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: tokenPopup.toggle()
        }

        MenuPopup {
            id: tokenPopup

            menuWidth: 220
            entries: tokenMenu.options.map(o => ({
                                                     "text": o,
                                                     "checked": o === tokenMenu.text
                                                 }))
            onTriggered: index => tokenMenu.picked(index)
        }
    }

    //: A number inside the sentence, typed in place, with its unit after it.
    component TokenInput: Rectangle {
        id: tokenInput

        property string text: ""
        property string suffix: ""
        property string placeholder: "0"

        signal committed(string text)

        width: tokenField.width + (suffix ? tokenSuffix.implicitWidth + 3 : 0) + 16
        height: 30
        radius: 7
        color: Theme.surfaceContainerHighest
        border.width: tokenField.activeFocus ? 1 : 0
        border.color: Theme.primary

        TextInput {
            id: tokenField

            anchors.left: parent.left
            anchors.leftMargin: 8
            anchors.verticalCenter: parent.verticalCenter
            width: Math.max(8, contentWidth + 1)
            text: tokenInput.text
            color: Theme.primary
            selectByMouse: true
            font.pixelSize: Theme.fontSizeSmall + 1
            font.weight: Font.DemiBold
            font.family: Theme.fontFamily
            onEditingFinished: tokenInput.committed(text)

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: tokenField.text.length === 0
                text: tokenInput.placeholder
                font.pixelSize: Theme.fontSizeSmall + 1
                color: Theme.outline
            }
        }

        StyledText {
            id: tokenSuffix

            anchors.left: tokenField.right
            anchors.leftMargin: 3
            anchors.verticalCenter: parent.verticalCenter
            visible: tokenInput.suffix !== ""
            text: tokenInput.suffix
            font.pixelSize: Theme.fontSizeSmall + 1
            font.weight: Font.DemiBold
            color: Theme.primary
        }
    }

    Column {
        id: body

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        anchors.leftMargin: card.open ? 16 : 14
        anchors.rightMargin: card.open ? 16 : 12
        anchors.topMargin: card.open ? 16 : Math.max(10, (Math.max(64, body.implicitHeight + 20) - body.implicitHeight) / 2)
        spacing: 14

        // ---- folded: the switch, the name, what it does (board 1) ---------
        Item {
            id: folded

            width: parent.width
            height: Math.max(40, foldedText.implicitHeight)
            visible: !card.open

            //: Click opens it, right-click offers the rest; the switch and
            //: the chevron sit above this and take their own clicks.
            MouseArea {
                id: foldedArea

                anchors.fill: parent
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor
                onClicked: mouse => {
                    if (mouse.button === Qt.RightButton) {
                        const at = foldedArea.mapToItem(rowMenu.parent, mouse.x, mouse.y)
                        rowMenu.openAt(at.x, at.y)
                    } else {
                        card.toggleOpen()
                    }
                }
            }

            BoolSwitch {
                id: rowSwitch

                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                width: 52
                height: 32
                checked: card.on
                onToggled: value => card.enabledToggled(value)
            }

            Column {
                id: foldedText

                anchors.left: rowSwitch.right
                anchors.leftMargin: 14
                anchors.right: foldedChevron.left
                anchors.rightMargin: 8
                anchors.verticalCenter: parent.verticalCenter
                spacing: 3

                Row {
                    width: parent.width
                    spacing: 8

                    StyledText {
                        id: foldedName

                        width: Math.min(implicitWidth, parent.width - (offTag.visible ? offTag.width + 8 : 0))
                        anchors.verticalCenter: parent.verticalCenter
                        text: card.rule.name || "Unnamed action"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.DemiBold
                        color: card.on ? Theme.surfaceText : Theme.outline
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }

                    //: Said in words as well as by the dimming.
                    Rectangle {
                        id: offTag

                        anchors.verticalCenter: parent.verticalCenter
                        visible: !card.on
                        width: offText.implicitWidth + 16
                        height: 20
                        radius: 10
                        color: Theme.surfaceContainerHighest

                        StyledText {
                            id: offText

                            anchors.centerIn: parent
                            text: "Off"
                            font.pixelSize: Theme.fontSizeSmall - 1
                            font.weight: Font.DemiBold
                            color: Theme.surfaceVariantText
                        }
                    }
                }

                StyledText {
                    width: parent.width
                    text: card.summary
                    font.pixelSize: Theme.fontSizeSmall
                    color: card.on ? Theme.surfaceVariantText : Theme.withAlpha(Theme.surfaceVariantText, 0.55)
                    wrapMode: Text.NoWrap
                    elide: Text.ElideRight
                }
            }

            DankIcon {
                id: foldedChevron

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                name: "chevron_right"
                size: 22
                color: Theme.outline
            }

            MenuPopup {
                id: rowMenu

                parent: foldedChevron
                menuWidth: 180
                entries: [{
                        "icon": "edit",
                        "text": "Edit"
                    }, {
                        "icon": "content_copy",
                        "text": "Duplicate"
                    }, {
                        "separator": true
                    }, {
                        "icon": "delete",
                        "text": "Delete",
                        "danger": true
                    }]
                onTriggered: index => {
                    if (index === 0)
                        card.toggleOpen()
                    else if (index === 1)
                        card.duplicated()
                    else if (index === 3)
                        card.removed()
                }
            }
        }

        // ---- open: the heading ----------------------------------------------
        Item {
            width: parent.width
            height: 30
            visible: card.open && !card.confirming

            //: The name reads as a title and is edited in place.
            TextInput {
                id: nameInput

                anchors.left: parent.left
                anchors.right: headEnd.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                text: card.rule.name || ""
                color: Theme.surfaceText
                selectByMouse: true
                clip: true
                font.pixelSize: Theme.fontSizeMedium
                font.weight: Font.Bold
                font.family: Theme.fontFamily
                onEditingFinished: card.set("name", text.trim())

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: nameInput.text.length === 0
                    text: "Name this action"
                    font.pixelSize: Theme.fontSizeMedium
                    color: Theme.outline
                }

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.top: parent.bottom
                    anchors.topMargin: 2
                    height: 1
                    visible: nameInput.activeFocus
                    color: Theme.primary
                }
            }

            Row {
                id: headEnd

                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 4

                StyledText {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: card.showJson
                    text: "JSON"
                    font.pixelSize: Theme.fontSizeSmall - 1
                    color: Theme.surfaceVariantText
                    rightPadding: 4
                }

                BoolSwitch {
                    anchors.verticalCenter: parent.verticalCenter
                    visible: !card.showJson
                    checked: card.on
                    onToggled: value => card.enabledToggled(value)
                }

                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 30
                    iconSize: 18
                    iconName: card.showJson ? "edit_note" : "data_object"
                    iconColor: Theme.surfaceText
                    tooltipText: card.showJson ? "Back to the form" : "Edit as JSON"
                    onClicked: card.showJson ? (card.showJson = false) : card.openJson()
                }

                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 30
                    iconSize: 18
                    visible: !card.showJson
                    iconName: "delete"
                    iconColor: Theme.error
                    tooltipText: "Delete action"
                    onClicked: card.confirmingDelete = true
                }

                DankActionButton {
                    anchors.verticalCenter: parent.verticalCenter
                    buttonSize: 30
                    iconSize: 20
                    iconName: "expand_less"
                    iconColor: Theme.surfaceVariantText
                    tooltipText: "Fold"
                    onClicked: card.toggleOpen()
                }
            }
        }

        // ---- deleting: says what goes, takes effect on save (board 18) ------
        Rectangle {
            width: parent.width
            visible: card.confirming
            height: visible ? deleteColumn.implicitHeight : 0
            color: "transparent"

            Column {
                id: deleteColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                spacing: 6

                StyledText {
                    text: "Delete “" + (card.rule.name || "this action") + "”?"
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
                            card.confirmingDelete = false
                            card.removed()
                        }
                    }

                    PillButton {
                        size: 32
                        kind: "text"
                        text: "Keep"
                        onClicked: card.confirmingDelete = false
                    }
                }
            }
        }

        // ---- the sentence ---------------------------------------------------
        Flow {
            width: parent.width
            visible: card.open && !card.confirming && !card.showJson
            spacing: 6

            Word {
                text: /^[aeiou]/.test(card.statusWord) ? "When an" : "When a"
            }

            TokenMenu {
                text: card.statusWord
                options: card.statusWords
                onPicked: index => {
                    const preset = card.statusPresets.find(p => p[0] === card.statusWords[index])
                    if (preset && preset[0] !== card.statusWord)
                        card.set("when.statuses", preset[1].slice())
                }
            }

            TokenMenu {
                text: card.kindWord
                options: ["download", "torrent", "normal download"]
                onPicked: index => {
                    const word = ["download", "torrent", "normal download"][index]
                    if (word === card.kindWord)
                        return
                    Fmt.setPath(card.rule, "when.torrent_only", word === "torrent" ? true : "")
                    card.set("when.http_only", word === "normal download" ? true : "")
                }
            }

            Word {
                text: card.mode === "connections" ? "has fewer than" : "stays"
            }

            TokenMenu {
                visible: card.mode !== "connections"
                text: card.mode
                options: card.modeWords
                onPicked: index => {
                    if (card.modeWords[index] !== card.mode)
                        card.setMode(card.modeWords[index])
                }
            }

            //: The speed as a number and a unit, typed in place.
            Rectangle {
                id: speedToken

                readonly property string path: card.mode === "above" ? "when.speed_above" : "when.speed_below"
                readonly property var parts: {
                    card.rev
                    return Units.split(String(card.value(speedToken.path)), "speed")
                }
                property int unit: parts.unit

                visible: card.mode !== "connections"
                width: speedField.width + unitLabel.implicitWidth + 19
                height: 30
                radius: 7
                color: Theme.surfaceContainerHighest
                border.width: speedField.activeFocus ? 1 : 0
                border.color: Theme.primary

                TextInput {
                    id: speedField

                    anchors.left: parent.left
                    anchors.leftMargin: 8
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.max(8, contentWidth + 1)
                    text: speedToken.parts.amount
                    color: Theme.primary
                    selectByMouse: true
                    font.pixelSize: Theme.fontSizeSmall + 1
                    font.weight: Font.DemiBold
                    font.family: Theme.fontFamily
                    onEditingFinished: {
                        const bytes = Units.join(text, speedToken.unit, "speed", "")
                        const number = Number(bytes)
                        card.set(speedToken.path, bytes === "" || !isFinite(number) ? bytes : number)
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        visible: speedField.text.length === 0
                        text: "0"
                        font.pixelSize: Theme.fontSizeSmall + 1
                        color: Theme.outline
                    }
                }

                StyledText {
                    id: unitLabel

                    anchors.left: speedField.right
                    anchors.leftMargin: 3
                    anchors.verticalCenter: parent.verticalCenter
                    text: Units.labels("speed")[speedToken.unit]
                    font.pixelSize: Theme.fontSizeSmall + 1
                    font.weight: Font.DemiBold
                    color: Theme.primary

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: unitMenu.toggle()
                    }

                    MenuPopup {
                        id: unitMenu

                        gap: 8
                        menuWidth: 120
                        entries: Units.labels("speed").map((l, i) => ({
                                                                        "text": l,
                                                                        "checked": i === speedToken.unit
                                                                    }))
                        onTriggered: index => {
                            speedToken.unit = index
                            const bytes = Units.join(speedField.text, index, "speed", "")
                            const number = Number(bytes)
                            card.set(speedToken.path, bytes === "" || !isFinite(number) ? bytes : number)
                        }
                    }
                }
            }

            TokenInput {
                visible: card.mode === "connections"
                text: String(card.value("when.connections_below"))
                suffix: "connections"
                onCommitted: text => card.setNumber("when.connections_below", text)
            }

            Word {
                text: "for"
            }

            Row {
                TokenInput {
                    text: String(card.value("when.for_seconds"))
                    suffix: "s"
                    onCommitted: text => card.setNumber("when.for_seconds", text)
                }

                Word {
                    leftPadding: 2
                    text: ","
                }
            }

            Row {
                TokenMenu {
                    text: Rules.ACTION_WORDS[card.rule.action || "pause_resume"] || String(card.rule.action)
                    options: card.actionWords
                    onPicked: index => {
                        if (card.actionValues[index] !== card.rule.action)
                            card.set("action", card.actionValues[index])
                    }
                }

                Word {
                    visible: !card.resumes
                    leftPadding: 2
                    text: "."
                }
            }

            Word {
                visible: card.resumes
                text: "it after"
            }

            Row {
                visible: card.resumes

                TokenInput {
                    text: String(card.value("resume_after_seconds"))
                    suffix: "s"
                    placeholder: "1.5"
                    onCommitted: text => card.setNumber("resume_after_seconds", text)
                }

                Word {
                    leftPadding: 2
                    text: "."
                }
            }
        }

        // ---- optional conditions, as removable chips ------------------------
        Flow {
            width: parent.width
            visible: card.open && !card.confirming && !card.showJson
            spacing: 6

            Repeater {
                model: card.setConditions

                Rectangle {
                    id: condChip

                    required property var modelData

                    width: condRow.implicitWidth + 18
                    height: 28
                    radius: 14
                    color: Theme.surfaceContainerHighest

                    Row {
                        id: condRow

                        anchors.centerIn: parent
                        spacing: 3

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            text: condChip.modelData.pre
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                        }

                        TextInput {
                            anchors.verticalCenter: parent.verticalCenter
                            width: Math.max(8, contentWidth + 1)
                            text: String(card.value(condChip.modelData.path))
                            color: Theme.surfaceText
                            selectByMouse: true
                            font.pixelSize: Theme.fontSizeSmall
                            font.family: Theme.fontFamily
                            onEditingFinished: condChip.modelData.text ? card.set(condChip.modelData.path, text.trim())
                                                                       : card.setNumber(condChip.modelData.path, text)
                        }

                        StyledText {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: condChip.modelData.unit !== ""
                            text: condChip.modelData.unit
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.surfaceText
                        }

                        DankIcon {
                            anchors.verticalCenter: parent.verticalCenter
                            name: "close"
                            size: 14
                            color: Theme.surfaceVariantText

                            MouseArea {
                                anchors.fill: parent
                                anchors.margins: -4
                                cursorShape: Qt.PointingHandCursor
                                onClicked: card.set(condChip.modelData.path, "")
                            }
                        }
                    }
                }
            }

            //: Adds one of the conditions not yet in force.
            Item {
                id: addCondition

                visible: card.unsetConditions.length > 0
                width: addRow.implicitWidth + 22
                height: 28

                Canvas {
                    anchors.fill: parent

                    property color tint: Theme.outlineVariant

                    onTintChanged: requestPaint()
                    onWidthChanged: requestPaint()

                    onPaint: {
                        const ctx = getContext("2d")
                        ctx.reset()
                        const r = (height - 1) / 2
                        ctx.strokeStyle = tint
                        ctx.lineWidth = 1
                        ctx.setLineDash([3, 3])
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

                    anchors.centerIn: parent
                    spacing: 4

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "add"
                        size: 14
                        color: Theme.surfaceText
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Condition"
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceText
                    }
                }

                MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: conditionMenu.toggle()
                }

                MenuPopup {
                    id: conditionMenu

                    menuWidth: 220
                    entries: card.unsetConditions.map(c => ({
                                                                "text": c.pre + (c.unit && c.unit !== "connections" ? " (" + c.unit + ")" : (c.unit ? " " + c.unit : ""))
                                                            }))
                    onTriggered: index => {
                        const picked = card.unsetConditions[index]
                        if (picked)
                            card.set(picked.path, picked.start)
                    }
                }
            }
        }

        // ---- "Change its options": which options (board 18) -----------------
        Rectangle {
            width: parent.width
            visible: card.open && !card.confirming && !card.showJson && card.rule.action === "set_option"
            height: visible ? optionColumn.implicitHeight + (card.optionKeys.length ? 28 : 0) : 0
            radius: 12
            color: card.optionKeys.length ? Theme.surfaceContainer : "transparent"
            border.width: 0

            Column {
                id: optionColumn

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: card.optionKeys.length ? 14 : 0
                spacing: 8

                Row {
                    visible: card.optionKeys.length === 0
                    spacing: 8

                    DankIcon {
                        anchors.verticalCenter: parent.verticalCenter
                        name: "warning"
                        size: 18
                        color: Theme.warning
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        //: The card's heading already names the action.
                        text: "Can't run yet"
                        font.pixelSize: Theme.fontSizeMedium
                        font.weight: Font.Bold
                        color: Theme.surfaceText
                    }
                }

                StyledText {
                    width: parent.width
                    visible: card.optionKeys.length === 0
                    wrapMode: Text.WordWrap
                    text: "“Change its options” needs to know which options. Add at least one:"
                    font.pixelSize: Theme.fontSizeSmall
                    color: Theme.surfaceVariantText
                }

                Flow {
                    width: parent.width
                    visible: card.optionKeys.length > 0
                    spacing: 6

                    Repeater {
                        model: card.optionKeys

                        Rectangle {
                            id: optChip

                            required property string modelData

                            width: optRow.implicitWidth + 18
                            height: 28
                            radius: 14
                            color: Theme.surfaceContainerHighest

                            Row {
                                id: optRow

                                anchors.centerIn: parent
                                spacing: 4

                                StyledText {
                                    anchors.verticalCenter: parent.verticalCenter
                                    text: optChip.modelData
                                    font.pixelSize: Theme.fontSizeSmall
                                    color: Theme.surfaceText
                                }

                                TextInput {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: Math.max(14, contentWidth + 2)
                                    text: String((card.rule.options || {})[optChip.modelData] || "")
                                    color: Theme.primary
                                    selectByMouse: true
                                    font.pixelSize: Theme.fontSizeSmall
                                    font.weight: Font.DemiBold
                                    font.family: Theme.fontFamily
                                    onEditingFinished: card.addOption(optChip.modelData, text.trim())
                                }

                                DankIcon {
                                    anchors.verticalCenter: parent.verticalCenter
                                    name: "close"
                                    size: 14
                                    color: Theme.surfaceVariantText

                                    MouseArea {
                                        anchors.fill: parent
                                        anchors.margins: -4
                                        cursorShape: Qt.PointingHandCursor
                                        onClicked: card.removeOption(optChip.modelData)
                                    }
                                }
                            }
                        }
                    }
                }

                Row {
                    spacing: 6

                    PillButton {
                        visible: card.optionKeys.indexOf("max-download-limit") === -1
                        size: 32
                        kind: "outlined"
                        icon: "add"
                        text: "Download limit"
                        onClicked: card.addOption("max-download-limit", "2M")
                    }

                    PillButton {
                        visible: card.optionKeys.indexOf("max-connection-per-server") === -1
                        size: 32
                        kind: "outlined"
                        icon: "add"
                        text: "Connections"
                        onClicked: card.addOption("max-connection-per-server", "4")
                    }

                    PillButton {
                        size: 32
                        kind: "text"
                        text: "Other…"
                        onClicked: card.openJson()
                    }
                }
            }
        }

        FillField {
            width: parent.width
            visible: card.open && !card.confirming && !card.showJson
            placeholderText: "Note — what this action is for (optional)"
            text: card.rule.description || ""
            onEditingFinished: card.set("description", text)
        }

        // ---- raw JSON, behind { } (board 18) --------------------------------
        Rectangle {
            width: parent.width
            visible: card.open && !card.confirming && card.showJson
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
            visible: card.open && !card.confirming && card.showJson && card.jsonProblem !== ""
            spacing: 6

            DankIcon {
                anchors.verticalCenter: parent.verticalCenter
                name: "error"
                size: 16
                color: Theme.error
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                text: card.jsonProblem
                font.pixelSize: Theme.fontSizeSmall
                color: Theme.error
            }
        }

        Row {
            anchors.right: parent.right
            visible: card.open && !card.confirming && card.showJson
            spacing: 6

            PillButton {
                size: 36
                kind: "text"
                text: "Discard"
                onClicked: card.showJson = false
            }

            PillButton {
                size: 36
                kind: "filled"
                text: "Apply JSON"
                enabled: card.jsonProblem === ""
                onClicked: card.applyJson()
            }
        }
    }
}
