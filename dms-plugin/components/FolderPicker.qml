import QtQuick
import qs.Common
import qs.Widgets

// "Save to" for the Add panel's review: a menu of the preset folders (the
// download folder and the sorting folders) above a path field with its own
// chooser, for anything else.
Column {
    id: picker

    property alias text: field.text
    //: GET /api/folders: {base, presets: [{label, path}], suggested}
    property var info: ({})
    readonly property var presets: info.presets || []

    function labelOf(p) {
        return p.label + " · " + p.path
    }

    spacing: Theme.spacingXS

    DankDropdown {
        width: parent.width
        height: 40
        compactMode: true
        //: Shows the preset the field holds, if it is one.
        currentValue: {
            const path = field.text.trim() || picker.info.base || ""
            for (const p of picker.presets)
                if (p.path === path)
                    return picker.labelOf(p)
            return "Other folder"
        }
        options: picker.presets.map(p => picker.labelOf(p))
        onValueChanged: label => {
            for (const p of picker.presets)
                if (label === picker.labelOf(p))
                    field.text = p.path === picker.info.base ? "" : p.path
        }
    }

    DirectoryField {
        id: field
        objectName: "review"
        width: parent.width
        placeholderText: "Download folder: " + (picker.info.base || "")
    }
}
