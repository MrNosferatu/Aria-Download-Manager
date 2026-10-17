import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets

//: The boards' menu: a raised surface of 34 px rows, each an icon, a label
//: and an optional detail on the right; separators and small headings
//: between groups. Opened beside whatever asked for it — below it, unless
//: that runs past the bottom of the surface, then above.
Popup {
    id: menu

    //: [{icon, text, detail, checked, danger, enabled, separator, heading}]
    property var entries: []
    property int menuWidth: 240

    //: Space between the opener and the menu, below it or above it.
    property int gap: 4
    //: Line the menu's right edge up with the opener's, rather than its left.
    property bool alignEnd: false

    //: Set by openAt(): where the pointer was, in the opener's coordinates.
    property point _at: Qt.point(NaN, NaN)
    //: The popout this menu sits in, while it is open.
    property var _host: null
    //: The list the opener scrolls in, while the menu is open.
    property var _flick: null
    //: Where that list was when the menu opened; a live update may nudge it
    //: a pixel without anyone scrolling.
    property point _scrolledTo: Qt.point(0, 0)

    signal triggered(int index)

    //: Open at a point (a right click), in the opener's coordinates.
    function openAt(px, py) {
        menu._at = Qt.point(px, py)
        menu.open()
    }

    //: For the opener's click: open, or close it if it is open.
    function toggle() {
        if (menu.opened)
            menu.close()
        else
            menu.open()
    }

    onClosed: {
        menu._at = Qt.point(NaN, NaN)
        menu._flick = null
    }

    //: The nearest list the opener scrolls in.
    function _scroller() {
        for (let item = menu.parent; item; item = item.parent) {
            if (item.contentY !== undefined && item.flicking !== undefined)
                return item
        }
        return null
    }

    //: Scrolling carries the opener away; a menu left behind would hang over
    //: other rows or past the panel's edge, so it closes instead.
    Connections {
        target: menu._flick
        ignoreUnknownSignals: true

        function onContentYChanged() {
            if (Math.abs(menu._flick.contentY - menu._scrolledTo.y) > 2)
                menu.close()
        }

        function onContentXChanged() {
            if (Math.abs(menu._flick.contentX - menu._scrolledTo.x) > 2)
                menu.close()
        }
    }

    //: The popout is closing: the menu goes first, at once, so it is neither
    //: left over the closing panel nor still open when the panel comes back.
    Connections {
        target: menu._host
        ignoreUnknownSignals: true

        function onShowingChanged() {
            if (menu._host && !menu._host.showing)
                menu.close()
        }
    }

    //: Where the menu has to fit: the popout's body, which clips whatever is
    //: drawn past it, or else the whole window.
    function _bounds() {
        let item = menu.parent
        let last = null
        while (item) {
            if (item.objectName === "aria2MenuBounds")
                return item
            last = item
            item = item.parent
        }
        return last
    }

    onAboutToShow: {
        const opener = menu.parent
        if (!opener)
            return
        const atPointer = !isNaN(menu._at.x)
        const below = atPointer ? menu._at.y : opener.height + menu.gap
        menu.x = atPointer ? menu._at.x : (menu.alignEnd ? opener.width - menu.width : 0)
        menu.y = below
        menu._flick = menu._scroller()
        if (menu._flick)
            menu._scrolledTo = Qt.point(menu._flick.contentX, menu._flick.contentY)
        const bounds = menu._bounds()
        menu._host = bounds && bounds.objectName === "aria2MenuBounds" ? bounds : null
        if (!bounds || bounds === opener)
            return
        const edge = 8
        if (atPointer && opener.mapToItem(bounds, menu.x + menu.width, 0).x > bounds.width - edge)
            menu.x -= menu.width
        const height = menu.implicitHeight
        const top = opener.mapToItem(bounds, 0, below).y
        if (top + height <= bounds.height - edge)
            return
        const above = atPointer ? menu._at.y - height : -height - menu.gap
        if (opener.mapToItem(bounds, 0, above).y >= edge)
            menu.y = above
        else
            menu.y = below - (top + height - (bounds.height - edge))
    }

    width: menuWidth
    padding: 6
    modal: false
    focus: true
    // Not on a press on the opener itself: that press would close the menu
    // and its click open it again. The opener toggles it instead.
    closePolicy: Popup.CloseOnEscape | Popup.CloseOnPressOutsideParent

    background: Rectangle {
        radius: 14
        color: Theme.surfaceContainerHigh
        border.width: 1
        border.color: Theme.withAlpha(Theme.outline, 0.18)
    }

    contentItem: Column {
        spacing: 0

        Repeater {
            model: menu.entries

            Item {
                id: entry

                required property var modelData
                required property int index

                readonly property bool usable: !modelData.separator && !modelData.heading && modelData.enabled !== false

                width: menu.width - menu.padding * 2
                height: modelData.separator ? 9 : (modelData.heading ? 26 : 34)

                Rectangle {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.leftMargin: 6
                    anchors.rightMargin: 6
                    anchors.verticalCenter: parent.verticalCenter
                    height: 1
                    visible: !!entry.modelData.separator
                    color: Theme.outlineVariant
                }

                StyledText {
                    anchors.left: parent.left
                    anchors.leftMargin: 10
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: 4
                    visible: !!entry.modelData.heading
                    text: String(entry.modelData.heading || "").toUpperCase()
                    font.pixelSize: Theme.fontSizeSmall - 1
                    font.weight: Font.DemiBold
                    font.letterSpacing: 0.6
                    color: Theme.outline
                }

                Rectangle {
                    anchors.fill: parent
                    visible: !entry.modelData.separator && !entry.modelData.heading
                    radius: 9
                    color: area.containsMouse && entry.usable ? (entry.modelData.danger ? Theme.withAlpha(Theme.error, 0.12) : Theme.withAlpha(Theme.surfaceText, 0.08)) : "transparent"
                    opacity: entry.usable ? 1 : 0.4

                    DankIcon {
                        id: entryIcon

                        anchors.left: parent.left
                        anchors.leftMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        visible: !!entry.modelData.icon
                        name: entry.modelData.icon || ""
                        size: 18
                        color: entry.modelData.danger ? Theme.error : Theme.surfaceVariantText
                    }

                    StyledText {
                        anchors.left: entryIcon.visible ? entryIcon.right : parent.left
                        anchors.leftMargin: 10
                        anchors.right: entryDetail.left
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        text: entry.modelData.text || ""
                        font.pixelSize: Theme.fontSizeSmall + 1
                        color: entry.modelData.danger ? Theme.error : Theme.surfaceText
                        wrapMode: Text.NoWrap
                        elide: Text.ElideRight
                    }

                    StyledText {
                        id: entryDetail

                        anchors.right: entryCheck.visible ? entryCheck.left : parent.right
                        anchors.rightMargin: 10
                        anchors.verticalCenter: parent.verticalCenter
                        text: entry.modelData.detail || ""
                        font.pixelSize: Theme.fontSizeSmall
                        color: Theme.surfaceVariantText
                    }

                    DankIcon {
                        id: entryCheck

                        anchors.right: parent.right
                        anchors.rightMargin: 8
                        anchors.verticalCenter: parent.verticalCenter
                        visible: entry.modelData.checked === true
                        name: "check"
                        size: 18
                        color: Theme.primary
                    }

                    MouseArea {
                        id: area

                        anchors.fill: parent
                        hoverEnabled: true
                        enabled: entry.usable
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                            menu.close()
                            menu.triggered(entry.index)
                        }
                    }
                }
            }
        }
    }
}
