import QtQuick
import qs.Common

//: A field of the Add form: the boards' filled box whose label stays in front
//: of the value once something is typed ("Referer: debian.org", "8
//: connections"), with the label as the placeholder while it is empty.
FillField {
    id: field

    property string iconName: ""

    icon: iconName
    placeholderText: label
}
