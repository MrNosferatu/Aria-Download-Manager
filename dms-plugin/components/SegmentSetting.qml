import QtQuick
import qs.Common
import qs.Widgets

//: A plugin setting picked from two to four short choices, shown side by side
//: rather than hidden in a dropdown. Saves through the enclosing
//: PluginSettings the same way DMS's own SelectionSetting does.
Item {
    id: root

    required property string settingKey
    required property string label
    property string description: ""
    //: [{label, value}]
    property var options: []
    property string defaultValue: ""
    property string value: defaultValue

    property bool isInitialized: false

    width: parent ? parent.width : 0
    height: Math.max(texts.implicitHeight, group.height)

    function findSettings() {
        let item = root.parent
        while (item) {
            if (item.saveValue !== undefined && item.loadValue !== undefined)
                return item
            item = item.parent
        }
        return null
    }

    function loadValue() {
        const settings = findSettings()
        if (settings && settings.pluginService) {
            root.value = settings.loadValue(root.settingKey, root.defaultValue)
            root.isInitialized = true
        }
    }

    Component.onCompleted: Qt.callLater(loadValue)

    onValueChanged: {
        if (!root.isInitialized)
            return
        const settings = findSettings()
        if (settings)
            settings.saveValue(root.settingKey, root.value)
    }

    Column {
        id: texts

        anchors.left: parent.left
        anchors.right: group.left
        anchors.rightMargin: Theme.spacingM
        anchors.verticalCenter: parent.verticalCenter
        spacing: Theme.spacingXS

        StyledText {
            width: parent.width
            text: root.label
            font.pixelSize: Theme.fontSizeLarge
            font.weight: Font.Medium
            color: Theme.surfaceText
        }

        StyledText {
            width: parent.width
            visible: root.description !== ""
            text: root.description
            font.pixelSize: Theme.fontSizeSmall
            color: Theme.surfaceVariantText
            wrapMode: Text.WordWrap
        }
    }

    DankButtonGroup {
        id: group

        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        size: "small"
        model: root.options.map(o => o.label)
        currentIndex: Math.max(0, root.options.findIndex(o => o.value === root.value))
        onSelectionChanged: (index, selected) => {
            if (selected && root.options[index])
                root.value = root.options[index].value
        }
    }
}
