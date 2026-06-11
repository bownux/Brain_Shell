import QtQuick
import Quickshell
import "../../"

// ============================================================
// RogAppearance — fills the "Appearance Coming Soon!" config
// page with the things this box actually switches: the desktop
// look (Brain vs classic shell) and wallpaper-driven re-theme.
// ============================================================
Item {
    id: root

    Column {
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 16 }
        spacing: 14

        Text { text: "DESKTOP LOOK"; font.pixelSize: 10; font.weight: Font.Bold
               font.letterSpacing: 1.5; color: Qt.rgba(1,1,1,0.4) }

        Row {
            spacing: 10
            Rectangle {
                width: 150; height: 38; radius: 10
                color: Qt.rgba(1,1,1,0.06)
                border.width: 1.5; border.color: Theme.active
                Column {
                    anchors.centerIn: parent
                    Text { text: "Brain Shell"; font.pixelSize: 12; color: Theme.text
                           anchors.horizontalCenter: parent.horizontalCenter }
                    Text { text: "current"; font.pixelSize: 8; color: Theme.subtext
                           anchors.horizontalCenter: parent.horizontalCenter }
                }
            }
            Rectangle {
                width: 150; height: 38; radius: 10
                color: classicMa.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.06)
                border.width: 1; border.color: Theme.border
                Behavior on color { ColorAnimation { duration: 150 } }
                Text { anchors.centerIn: parent; text: "Classic shell"; font.pixelSize: 12; color: Theme.text }
                MouseArea {
                    id: classicMa; anchors.fill: parent; hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: Quickshell.execDetached(
                        ["bash", "-c", "$HOME/.config/hypr/scripts/desktop-look classic"])
                }
            }
        }

        Text { text: "THEME"; font.pixelSize: 10; font.weight: Font.Bold
               font.letterSpacing: 1.5; color: Qt.rgba(1,1,1,0.4) }

        Rectangle {
            width: 310; height: 38; radius: 10
            color: rethemeMa.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.06)
            border.width: 1; border.color: Theme.border
            Behavior on color { ColorAnimation { duration: 150 } }
            Text { anchors.centerIn: parent; font.pixelSize: 12; color: Theme.text
                   text: "󰸉  Re-sync colors from current wallpaper" }
            MouseArea {
                id: rethemeMa; anchors.fill: parent; hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: Quickshell.execDetached(["bash", "-c",
                    "W=$(swww query | grep -oE 'image: .*' | head -1 | sed 's/image: //'); " +
                    "[ -n \"$W\" ] && matugen image \"$W\""])
            }
        }

        Text {
            width: parent.width
            wrapMode: Text.Wrap
            font.pixelSize: 10; color: Theme.subtext
            text: "Wallpaper picker: hover the bottom-center edge of the screen — it slides " +
                  "up from the bottom. Picking a wallpaper re-themes Brain Shell, the classic " +
                  "shell, and the orb chrome together (matugen). Overview: SUPER+G / SUPER+TAB."
        }
    }
}
