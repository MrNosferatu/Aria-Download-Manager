import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "ariaDownloadManager"

    StyledText {
        width: parent.width
        text: "This widget is a front-end for the Aria Download Manager running on this machine. It does not download anything on its own: start the manager first (run.sh, or the systemd user unit), then point the widget at it."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "socketPath"
        label: "Manager socket"
        description: "The Unix socket the manager listens on (server.socket in config.yaml). Blank uses the default, $XDG_RUNTIME_DIR/aria-download-manager.sock."
        placeholder: "$XDG_RUNTIME_DIR/aria-download-manager.sock"
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "pillMode"
        label: "Bar label"
        description: "What sits next to the icon on the bar."
        options: [
            {
                "label": "Download speed",
                "value": "speed"
            },
            {
                "label": "Download count",
                "value": "count"
            },
            {
                "label": "Icon only",
                "value": "none"
            }
        ]
        defaultValue: "speed"
    }

    SelectionSetting {
        settingKey: "clickOpens"
        label: "Clicking the bar icon opens"
        description: "The popout hangs off the bar and closes on the next click elsewhere. The window is an ordinary movable, resizable window. Right-click gives quick actions either way."
        options: [
            {
                "label": "Bar popout",
                "value": "popout"
            },
            {
                "label": "Standalone window",
                "value": "window"
            }
        ]
        defaultValue: "popout"
    }

    StringSetting {
        settingKey: "popoutWidth"
        label: "Popout width"
        description: "Width of the bar popout, in pixels."
        placeholder: "640"
        defaultValue: "640"
    }

    StringSetting {
        settingKey: "popoutHeight"
        label: "Popout content height"
        description: "Height of the popout's tab area, in pixels. The window is sized by dragging it."
        placeholder: "540"
        defaultValue: "540"
    }

    StringSetting {
        settingKey: "idlePollSeconds"
        label: "Bar refresh interval"
        description: "Seconds between bar updates while the panel is closed. The live stream only runs while the panel is open; turn on Always stream for an instant bar."
        placeholder: "3"
        defaultValue: "3"
    }

    ToggleSetting {
        settingKey: "alwaysStream"
        label: "Always stream"
        description: "Keep the event stream open with the panel closed, so the bar tracks every download in real time."
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notify"
        label: "Notify on events"
        description: "Show a toast when a download finishes or the manager logs an error."
        defaultValue: false
    }
}
