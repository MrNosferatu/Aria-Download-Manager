import QtQuick
import qs.Common
import qs.Widgets
import qs.Modules.Plugins

PluginSettings {
    id: settings

    pluginId: "aria2cManager"

    StyledText {
        width: parent.width
        text: "This widget is a front-end for the aria2c-manager daemon — it does not download anything on its own. Start the daemon first (run.sh, or the systemd user unit), then point the widget at it."
        font.pixelSize: Theme.fontSizeSmall
        color: Theme.surfaceVariantText
        wrapMode: Text.WordWrap
    }

    StringSetting {
        settingKey: "socketPath"
        label: "Manager socket"
        description: "The Unix socket the widget talks to (server.socket in config.yaml). Leave blank for the default, $XDG_RUNTIME_DIR/aria2c-manager.sock"
        placeholder: "$XDG_RUNTIME_DIR/aria2c-manager.sock"
        defaultValue: ""
    }

    SelectionSetting {
        settingKey: "pillMode"
        label: "Bar label"
        description: "What the bar widget shows next to its icon"
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
        label: "Clicking the bar icon"
        description: "The popout is anchored to the bar and closes on the next click elsewhere; the window is an ordinary movable, resizable window. Either way, right-click gives quick actions, and the popout header can detach into the window."
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
        description: "Width of the manager window in pixels"
        placeholder: "640"
        defaultValue: "640"
    }

    StringSetting {
        settingKey: "popoutHeight"
        label: "Popout content height"
        description: "Height of the tab area in pixels"
        placeholder: "540"
        defaultValue: "540"
    }

    StringSetting {
        settingKey: "idlePollSeconds"
        label: "Bar refresh interval"
        description: "Seconds between pill updates while the panel is closed — this is how far behind the bar can lag a download that starts elsewhere. The live stream only runs while the panel is open; turn on Always stream below for an instant pill."
        placeholder: "3"
        defaultValue: "3"
    }

    ToggleSetting {
        settingKey: "alwaysStream"
        label: "Always stream"
        description: "Keep the event stream open even with the panel closed — one long-lived connection, and the pill tracks every download in real time"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notify"
        label: "Toast on events"
        description: "Show a toast when a download finishes or the manager logs an error"
        defaultValue: false
    }
}
