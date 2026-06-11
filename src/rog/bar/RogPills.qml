import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ============================================================
// RogPills — the classic TopBar's system pills, restyled with
// Brain_Shell Theme tokens. Self-polling, no external state:
//   AI   — ai-mode (LLM/GEN/GAME) → opens the dashboard AI tab
//   GPU  — game/vision toggle (gpu-mode)
//   TEMP — hottest R9700 (red ≥85°)
//   CPU  — usage % → btop
// ============================================================
Row {
    id: root
    spacing: 6
    anchors.verticalCenter: parent.verticalCenter

    property string aiMode: "unknown"
    property int maxTemp: 0
    property int maxUtil: 0
    property bool gameMode: false
    property int cpu: 0

    // canonical mode hues carried over from the classic bar
    readonly property color cSapphire: "#74c7ec"
    readonly property color cMauve:    "#cba6f7"
    readonly property color cPeach:    "#fab387"
    readonly property color cRed:      "#f38ba8"

    function aiColor() {
        if (aiMode === "inference" || aiMode === "default") return cSapphire;
        if (aiMode.indexOf("generate") === 0 || aiMode === "generation") return cMauve;
        if (aiMode === "game" || aiMode === "gaming") return cPeach;
        return Theme.subtext;
    }
    function aiLabel() {
        if (aiMode === "inference" || aiMode === "default") return "LLM";
        if (aiMode.indexOf("generate") === 0 || aiMode === "generation") return "GEN";
        if (aiMode === "game" || aiMode === "gaming") return "GAME";
        return "AI";
    }

    Process {
        id: statePoller; running: false
        command: ["bash", "-c", "/home/luis/ai/hermes-brains/bin/ai-state"]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = JSON.parse(this.text);
                    root.aiMode = d.mode || "unknown";
                    let t = 0, u = 0;
                    (d.gpus || []).forEach(g => {
                        if (g && g.temp > t) t = g.temp;
                        if (g && g.util > u) u = g.util;
                    });
                    root.maxTemp = t; root.maxUtil = u;
                } catch (e) {}
            }
        }
    }
    Process {
        id: gpuPoller; running: false
        command: ["bash", "-c", "/home/luis/ai/hermes-brains/bin/gpu-mode status 2>/dev/null"]
        stdout: StdioCollector { onStreamFinished: root.gameMode = (this.text || "").trim() === "game" }
    }
    Process {
        id: cpuPoller; running: false
        command: ["bash", "-c", "vmstat 1 2 | tail -1 | awk '{print 100-$15}'"]
        stdout: StdioCollector {
            onStreamFinished: { const v = parseInt((this.text || "").trim()); if (!isNaN(v)) root.cpu = v; }
        }
    }
    Timer {
        interval: 5000; repeat: true; running: root.visible; triggeredOnStart: true
        onTriggered: {
            statePoller.running = false; statePoller.running = true;
            gpuPoller.running = false;  gpuPoller.running = true;
            cpuPoller.running = false;  cpuPoller.running = true;
        }
    }

    // ── AI mode pill → dashboard AI tab ─────────────────────
    Rectangle {
        height: 24; radius: 12
        width: aiRow.implicitWidth + 20
        anchors.verticalCenter: parent.verticalCenter
        color: aiMa.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.05)
        Behavior on color { ColorAnimation { duration: 150 } }
        Row {
            id: aiRow; anchors.centerIn: parent; spacing: 5
            Text { text: "󰚩"; font.family: "Iosevka Nerd Font"; font.pixelSize: 13
                   color: root.aiColor(); anchors.verticalCenter: parent.verticalCenter
                   Behavior on color { ColorAnimation { duration: 300 } } }
            Text { text: root.aiLabel(); font.family: "JetBrains Mono"; font.pixelSize: 10
                   font.weight: Font.Black; color: Theme.text
                   anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea {
            id: aiMa; anchors.fill: parent; hoverEnabled: true
            onClicked: {
                var open = Popups.dashboardOpen && Popups.dashboardPage === "ai";
                Popups.closeAll();
                if (!open) { Popups.dashboardOpen = true; Popups.dashboardPage = "ai"; }
            }
        }
    }

    // ── GPU game/vision toggle pill ─────────────────────────
    Rectangle {
        height: 24; radius: 12; width: 30
        anchors.verticalCenter: parent.verticalCenter
        color: root.gameMode ? Qt.rgba(root.cPeach.r, root.cPeach.g, root.cPeach.b, 0.85)
                             : (gpuMa.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.05))
        Behavior on color { ColorAnimation { duration: 250 } }
        Text { anchors.centerIn: parent; text: root.gameMode ? "󰊴" : "󰍹"
               font.family: "Iosevka Nerd Font"; font.pixelSize: 13
               color: root.gameMode ? "#11111b" : Theme.subtext }
        MouseArea {
            id: gpuMa; anchors.fill: parent; hoverEnabled: true
            onClicked: {
                Quickshell.execDetached(["bash", "-c", "/home/luis/ai/hermes-brains/bin/gpu-mode toggle"]);
                gpuPoller.running = false; gpuPoller.running = true;
            }
        }
    }

    // ── GPU temp pill ───────────────────────────────────────
    Rectangle {
        height: 24; radius: 12
        width: tempRow.implicitWidth + 20
        anchors.verticalCenter: parent.verticalCenter
        color: root.maxTemp >= 85 ? Qt.rgba(root.cRed.r, root.cRed.g, root.cRed.b, 0.85)
             : (tempMa.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.05))
        Behavior on color { ColorAnimation { duration: 250 } }
        Row {
            id: tempRow; anchors.centerIn: parent; spacing: 4
            Text { text: "󰔏"; font.family: "Iosevka Nerd Font"; font.pixelSize: 12
                   color: root.maxTemp >= 85 ? "#11111b" : (root.maxTemp >= 70 ? root.cPeach : Theme.subtext)
                   anchors.verticalCenter: parent.verticalCenter }
            Text { text: root.maxTemp + "°"; font.family: "JetBrains Mono"; font.pixelSize: 10
                   font.weight: Font.Black
                   color: root.maxTemp >= 85 ? "#11111b" : Theme.text
                   anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { id: tempMa; anchors.fill: parent; hoverEnabled: true
                    onClicked: Quickshell.execDetached(["bash", "-c", "kitty -e btop"]) }
    }

    // ── CPU pill ────────────────────────────────────────────
    Rectangle {
        height: 24; radius: 12
        width: cpuRow.implicitWidth + 20
        anchors.verticalCenter: parent.verticalCenter
        color: cpuMa.containsMouse ? Qt.rgba(1,1,1,0.12) : Qt.rgba(1,1,1,0.05)
        Behavior on color { ColorAnimation { duration: 150 } }
        Row {
            id: cpuRow; anchors.centerIn: parent; spacing: 4
            Text { text: "󰘚"; font.family: "Iosevka Nerd Font"; font.pixelSize: 12
                   color: root.cpu >= 80 ? root.cRed : (root.cpu >= 50 ? root.cPeach : Theme.subtext)
                   anchors.verticalCenter: parent.verticalCenter }
            Text { text: root.cpu + "%"; font.family: "JetBrains Mono"; font.pixelSize: 10
                   font.weight: Font.Black; color: Theme.text
                   anchors.verticalCenter: parent.verticalCenter }
        }
        MouseArea { id: cpuMa; anchors.fill: parent; hoverEnabled: true
                    onClicked: Quickshell.execDetached(["bash", "-c", "kitty -e btop"]) }
    }
}
