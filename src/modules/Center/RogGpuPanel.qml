import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ============================================================
// RogGpuPanel — replaces PowerPanel (laptop power-profile +
// envycontrol UI that doesn't apply to this desktop: the box
// is pinned to EPP=performance at the OS level). Shows what
// actually matters on this rig: the 3× R9700 + 3080 Ti — VRAM,
// utilization and temperature, live from `ai-state`.
// ============================================================
Item {
    id: root

    property var gpus: []

    Process {
        id: poller; running: false
        command: ["bash", "-c", "/home/luis/ai/hermes-brains/bin/ai-state"]
        stdout: StdioCollector {
            onStreamFinished: {
                try { root.gpus = (JSON.parse(this.text).gpus || []); } catch (e) {}
            }
        }
    }
    Timer {
        interval: 4000; repeat: true; running: root.visible; triggeredOnStart: true
        onTriggered: { poller.running = false; poller.running = true; }
    }

    Column {
        anchors.fill: parent
        anchors.margins: 12
        spacing: 8

        Text {
            text: "GPUS"
            font.pixelSize: 10; font.weight: Font.Bold; font.letterSpacing: 1.5
            color: Qt.rgba(1, 1, 1, 0.4)
        }

        Repeater {
            model: root.gpus
            delegate: Column {
                required property var modelData
                width: parent.width
                spacing: 3

                Row {
                    width: parent.width
                    Text {
                        text: modelData.label || "GPU"
                        font.pixelSize: 10; font.family: "JetBrains Mono"
                        color: Theme.text; width: parent.width * 0.42
                        elide: Text.ElideRight
                    }
                    Text {
                        text: (modelData.temp != null ? modelData.temp + "°" : "—") + "  " +
                              (modelData.util != null ? modelData.util + "%" : "—")
                        font.pixelSize: 10; font.family: "JetBrains Mono"
                        color: (modelData.temp || 0) >= 85 ? "#f38ba8" : Theme.subtext
                    }
                }
                // VRAM bar
                Rectangle {
                    width: parent.width; height: 5; radius: 2.5
                    color: Qt.rgba(1, 1, 1, 0.07)
                    Rectangle {
                        property real frac: (modelData.vram_total > 0)
                                            ? modelData.vram_used / modelData.vram_total : 0
                        width: parent.width * Math.max(0, Math.min(1, frac))
                        height: parent.height; radius: 2.5
                        color: frac > 0.92 ? "#fab387" : Theme.active
                        Behavior on width { NumberAnimation { duration: 600; easing.type: Easing.OutCubic } }
                    }
                }
            }
        }

        Text {
            visible: root.gpus.length === 0
            text: "ai-state unavailable"
            font.pixelSize: 10; color: Qt.rgba(1, 1, 1, 0.25)
        }
    }
}
