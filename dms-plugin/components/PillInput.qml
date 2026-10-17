import QtQuick

//: Hover and middle click for the bar pill, dropped into the pill's content.
//: The content is only the glyph and label; the pill around it (DMS's
//: BasePill) is the real target, padding included, so the handlers attach to
//: the nearest ancestor that reports `isMouseHovered`. Zero-sized, so the Row
//: or Column it sits in leaves no gap for it.
Item {
    id: input

    //: The pill content this sits in.
    property Item content: null
    //: The Aria2Widget: told about hover, asked to flip, told to hide its card.
    property var widget: null

    width: 0
    height: 0

    readonly property Item pill: {
        let p = content ? content.parent : null
        while (p && p.isMouseHovered === undefined)
            p = p.parent
        return p
    }

    //: The pill's own hover state covers its padding and the stretch toward
    //: the bar edge; the fallback covers a DMS that no longer offers it.
    readonly property bool hovered: pill ? pill.isMouseHovered : fallbackHover.hovered

    onHoveredChanged: {
        if (input.widget)
            input.widget.pillHovered = input.hovered
    }

    HoverHandler {
        id: fallbackHover

        parent: input.content
        enabled: !input.pill
    }

    //: The pill's own mouse area takes left and right only, so a middle press
    //: falls through to this.
    TapHandler {
        parent: input.pill || input.content
        acceptedButtons: Qt.MiddleButton
        onTapped: {
            if (input.widget) {
                input.widget.dismissHover()
                input.widget.flipAll()
            }
        }
    }

    Connections {
        target: input.pill
        ignoreUnknownSignals: true

        function onClicked() {
            input.widget?.dismissHover()
        }

        function onRightClicked() {
            input.widget?.dismissHover()
        }
    }
}
