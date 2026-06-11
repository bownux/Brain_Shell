import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ============================================================
// RogLayout — fills "Layout & Behavior Coming Soon!" with live
// Hyprland layout control: dwindle / master / scrolling (the
// 0.55 native niri-style tape), scrolling column width, and a
// keybind cheat-sheet for the overview + tape.
// Runtime changes via hyprctl keyword; persist in hyprland.conf.
// ============================================================
Item {
    id: root

    property string current: "?"

    Process {
        id: getLayout; running: false
        command: ["bash", "-c", "hyprctl getoption general:layout -j | sed -n 's/.*\"str\": \"\\([a-z]*\\)\".*/\\1/p'"]
        stdout: StdioCollector { onStreamFinished: { var t = (this.text||"").trim(); if (t) root.current = t } }
    }
    Timer { interval: 4000; repeat: true; running: root.visible; triggeredOnStart: true
            onTriggered: { getLayout.running = false; getLayout.running = true } }

    function setLayout(name) {
        Quickshell.execDetached(["bash", "-c", "hyprctl keyword general:layout " + name])
        current = name
    }

    Column {
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 16 }
        spacing: 14

        Text { text: "TILING LAYOUT  (runtime — persist in hyprland.conf)"; font.pixelSize: 10
               font.weight: Font.Bold; font.letterSpacing: 1.5; color: Qt.rgba(1,1,1,0.4) }

        Row {
            spacing: 10
            Repeater {
                model: [
                    { key: "scrolling", label: "Scrolling", sub: "niri tape" },
                    { key: "dwindle",   label: "Dwindle",   sub: "bsp tree" },
                    { key: "master",    label: "Master",    sub: "stack" },
                ]
                delegate: Rectangle {
                    required property var modelData
                    width: 130; height: 44; radius: 10
                    color: ma.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.06)
                    border.width: root.current === modelData.key ? 1.5 : 1
                    border.color: root.current === modelData.key ? Theme.active : Theme.border
                    Behavior on color { ColorAnimation { duration: 150 } }
                    Column {
                        anchors.centerIn: parent
                        Text { text: modelData.label; font.pixelSize: 12; color: Theme.text
                               anchors.horizontalCenter: parent.horizontalCenter }
                        Text { text: root.current === modelData.key ? "active" : modelData.sub
                               font.pixelSize: 8; color: Theme.subtext
                               anchors.horizontalCenter: parent.horizontalCenter }
                    }
                    MouseArea { id: ma; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: root.setLayout(modelData.key) }
                }
            }
        }

        Text { text: "SCROLLING COLUMN WIDTH"; font.pixelSize: 10; font.weight: Font.Bold
               font.letterSpacing: 1.5; color: Qt.rgba(1,1,1,0.4) }
        Row {
            spacing: 10
            Repeater {
                model: [ { l: "−10%", a: "colresize -0.1" }, { l: "+10%", a: "colresize +0.1" },
                         { l: "½ screen", a: "colresize exact 0.5" }, { l: "⅔ screen", a: "colresize exact 0.667" } ]
                delegate: Rectangle {
                    required property var modelData
                    width: 86; height: 32; radius: 8
                    color: cma.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.06)
                    border.width: 1; border.color: Theme.border
                    Text { anchors.centerIn: parent; text: modelData.l; font.pixelSize: 11; color: Theme.text }
                    MouseArea { id: cma; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                onClicked: Quickshell.execDetached(["bash", "-c",
                                    "hyprctl dispatch layoutmsg '" + modelData.a + "'"]) }
                }
            }
        }

        Text { text: "CHEAT SHEET"; font.pixelSize: 10; font.weight: Font.Bold
               font.letterSpacing: 1.5; color: Qt.rgba(1,1,1,0.4) }
        Text {
            width: parent.width; wrapMode: Text.Wrap; lineHeight: 1.4
            font.family: "JetBrains Mono"; font.pixelSize: 11; color: Theme.subtext
            text: "SUPER+G / SUPER+TAB   workspace overview (scroll ↑↓ between workspaces)\n" +
                  "SUPER+←→ / SUPER+H,L  glide along the scrolling tape\n" +
                  "SUPER+SHIFT+←→        carry window along the tape\n" +
                  "SUPER+[  /  SUPER+]   shrink / widen column\n" +
                  "SUPER+SHIFT+P         promote window to its own column\n" +
                  "SUPER+W               wallpaper picker (also: hover bottom edge)\n" +
                  "SUPER+I               AI Workload tab"
        }
    }
}
