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
        settingKey: "host"
        label: "Manager host"
        description: "Where aria2c-manager's HTTP API listens"
        placeholder: "127.0.0.1"
        defaultValue: "127.0.0.1"
    }

    StringSetting {
        settingKey: "port"
        label: "Manager port"
        description: "The server.port from config.yaml"
        placeholder: "6810"
        defaultValue: "6810"
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
        description: "Seconds between pill updates while the manager window is closed. The live stream only runs while it is open."
        placeholder: "10"
        defaultValue: "10"
    }

    ToggleSetting {
        settingKey: "alwaysStream"
        label: "Always stream"
        description: "Keep the event stream open even with the window closed — a live pill, at the cost of a request every second"
        defaultValue: false
    }

    ToggleSetting {
        settingKey: "notify"
        label: "Toast on events"
        description: "Show a toast when a download finishes or the manager logs an error"
        defaultValue: false
    }
}
