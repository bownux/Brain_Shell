import QtQuick
import Quickshell
import Quickshell.Wayland
import "../state"
import "./aiflow"

// ============================================================
// AiFlowWindow — hosts Rog's AI Workload dashboard (aiflow)
// inside Brain_Shell. The popup itself is vendored unchanged
// from the classic shell (src/rog/aiflow/AiFlowPopup.qml);
// this window gives it Brain_Shell-native open/close state
// (Popups.aiflowOpen — toggled via IPC target "aiflow", closed
// by PopupDismiss/Escape like every other popup).
// ============================================================
PanelWindow {
    id: root

    // top-right drop-down, mirroring the classic shell's placement
    anchors { top: true; right: true }
    margins.top: 10
    margins.right: 10
    implicitWidth: 540
    implicitHeight: Math.min((screen ? screen.height : 1080) - 120, 1150)

    color: "transparent"
    visible: Popups.aiflowOpen
    exclusionMode: ExclusionMode.Ignore
    WlrLayershell.namespace: "qs-popups"
    WlrLayershell.layer: WlrLayer.Overlay

    AiFlowPopup {
        anchors.fill: parent
    }
}
