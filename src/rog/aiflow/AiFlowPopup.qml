import QtQuick
import QtQuick.Layouts
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import "../"

// =============================================================================
//  AI Workload — Quickshell GPU/AI dashboard + control panel
// -----------------------------------------------------------------------------
//  ONE single-file popup (Quickshell loads popups as bare URLs; sibling
//  component types do NOT resolve — everything is inlined here).
//
//  Merges two formerly-separate tools into one tall unified view:
//    • WORKLOAD  — reallocate the GPUs between inference / generation / gaming /
//                  vision via `ai-mode` (starts/stops service groups).
//    • Hardware  — live per-GPU VRAM ring + util + temp + resident model.
//    • ROUTING   — Hermes router privacy mode (Auto/Local/Private) + the Grok
//                  difficulty-escalation toggle, via `ai-route`.
//    • MODELS    — start/stop any individual backend any time.
//
//  Single data source: `ai-state` (JSON, polled ~every 1.5s) now also carries
//  the router policy + per-service state, so there is just one poller.
// =============================================================================
Item {
    id: window
    focus: true

    Scaler { id: scaler; currentWidth: Screen.width }
    function s(val) { return scaler.s(val); }

    MatugenColors { id: _theme }
    readonly property color base:     _theme.base
    readonly property color mantle:   _theme.mantle
    readonly property color crust:    _theme.crust
    readonly property color text:     _theme.text
    readonly property color subtext0: _theme.subtext0
    readonly property color subtext1: _theme.subtext1
    readonly property color surface0: _theme.surface0
    readonly property color surface1: _theme.surface1
    readonly property color surface2: _theme.surface2
    readonly property color overlay0: _theme.overlay0
    readonly property color overlay1: _theme.overlay1
    readonly property color blue:     _theme.blue
    readonly property color sapphire: _theme.sapphire
    readonly property color teal:     _theme.teal
    readonly property color mauve:    _theme.mauve
    readonly property color pink:     _theme.pink
    readonly property color peach:    _theme.peach
    readonly property color green:    _theme.green
    readonly property color red:      _theme.red
    readonly property color yellow:   _theme.yellow

    // --- live state (from ai-state) ---------------------------------------
    property string mode: "unknown"
    property var gpus: []
    property var services: ({})
    property var router: ({})
    property int awareness: 0          // 0 Off · 1 Notify · 2 Occasional · 3 Active · 4 Chatty
    property bool hermesUp: false
    readonly property bool comfyUp: services && (services.comfy0 === true || services.comfy1 === true)
    // native voice loop is "live" when BOTH halves of the on-demand stack are up:
    // whisper STT (:8094) ingests the mic, Kokoro TTS (:8095) speaks the reply.
    readonly property bool voiceUp: services && services.whisper === true && services.kokoro === true
    property bool everPolled: false

    property string armedMode: ""   // workload mode showing inline confirm
    property bool busy: false       // a route/toggle action is in flight

    readonly property string binDir: "/home/luis/ai/hermes-brains/bin"

    function roleColor(role) {
        switch (role) {
            case "inference":  return window.blue;
            case "generation": return window.mauve;
            case "vision":     return window.teal;
            case "contended":  return window.red;
            default:           return window.overlay0;
        }
    }
    function modeColor(m) {
        switch (m) {
            case "default": case "inference":  return window.blue;
            case "generate-light": case "generate-heavy": case "generation": return window.mauve;
            case "game": case "gaming":        return window.peach;
            default:           return window.overlay0;
        }
    }
    // brand identity for the GPU cards (AMD red / NVIDIA green — recognizable
    // vendor colors, used only as a small badge + top accent strip so the 3×
    // R9700 cluster reads as one family and the lone 3080 Ti stands apart).
    function brandColor(kind) { return kind === "nvidia" ? window.green : window.red; }
    function brandName(kind)  { return kind === "nvidia" ? "NVIDIA" : "AMD"; }
    function tempColor(t)     { return t == null ? window.subtext0
                                     : t >= 78 ? window.red : t >= 62 ? window.peach : window.subtext0; }

    // --- derived telemetry that drives the live "Hermes flow" visual ---------
    // avg GPU utilisation (0..1) → particle speed + density + glow intensity
    readonly property real flowActivity: {
        var gs = window.gpus || []; var sum = 0, c = 0;
        for (var i = 0; i < gs.length; i++) {
            var g = gs[i];
            if (g && g.util != null) { sum += g.util; c++; }
        }
        return c > 0 ? Math.max(0, Math.min(1, (sum / c) / 100)) : 0;
    }
    // is any inference / vision / aux backend actually resident & serving?
    readonly property bool flowActive: window.services && (
        window.services.coder === true || window.services.think === true ||
        window.services.vl    === true || window.services.aux   === true)
    // routing-privacy "warmth": local=green, private=blue, auto=mauve
    readonly property color flowColor: {
        var p = (window.router && window.router.privacy) ? window.router.privacy : "open";
        return p === "local" ? window.green : p === "duckai" ? window.blue : window.mauve;
    }

    // =========================================================================
    //  POLLING — single source: ai-state (now includes router + services)
    // =========================================================================
    Process {
        id: stateProc
        running: false
        command: ["bash", "-lc", window.binDir + "/ai-state"]
        stdout: StdioCollector {
            onStreamFinished: {
                let txt = this.text ? this.text.trim() : "";
                if (!txt) return;
                try {
                    let d = JSON.parse(txt);
                    window.mode = d.mode || "unknown";
                    window.gpus = d.gpus || [];
                    window.services = d.services || ({});
                    window.router = d.router || ({});
                    window.awareness = (typeof d.awareness_level === "number") ? d.awareness_level : 0;
                    window.hermesUp = d.hermes ? !!d.hermes.up : false;
                    window.everPolled = true;
                } catch (e) { /* keep last good state */ }
            }
        }
    }
    Timer {
        interval: 1500; repeat: true; running: window.visible; triggeredOnStart: true
        onTriggered: { stateProc.running = false; stateProc.running = true; }
    }
    onVisibleChanged: if (visible) { stateProc.running = false; stateProc.running = true; }

    // --- usage history (ai-history → DuckDB system_ts + shim metrics) ------
    property int rangeH: 24
    property string metric: "util"     // util | tokens | reqs (chart primary series)
    property var hist: ({ buckets: [] })
    Process {
        id: histProc
        running: false
        command: ["bash", "-lc", window.binDir + "/ai-history " + window.rangeH]
        stdout: StdioCollector { onStreamFinished: {
            let t = this.text ? this.text.trim() : "";
            if (t) { try { window.hist = JSON.parse(t); } catch (e) {} }
        } }
    }
    Timer {
        interval: 30000; repeat: true; running: window.visible; triggeredOnStart: true
        onTriggered: { histProc.running = false; histProc.running = true; }
    }
    onRangeHChanged: { histProc.running = false; histProc.running = true; }

    // After an action, give systemd a beat then force a fresh poll.
    Timer { id: settle; interval: 1300; repeat: false
            onTriggered: { window.busy = false; stateProc.running = false; stateProc.running = true; } }

    function runAction(argv) {
        window.busy = true;
        Quickshell.execDetached(argv);
        settle.restart();
    }

    // workload mode (ai-mode) — destructive ones (generation/gaming) confirm
    function fireMode(key) {
        var arg = key;
        if (arg === "vision-on")
            arg = (window.services && window.services.vl === true) ? "vision-off" : "vision-on";
        runAction(["bash", "-lc", window.binDir + "/ai-mode " + arg]);
    }
    // router privacy / escalation (ai-route)
    function fireRoute(value)   { if (!window.busy) runAction(["bash", "-lc", window.binDir + "/ai-route " + value]); }
    function toggleEscalate()   { if (!window.busy) runAction(["bash", "-lc", window.binDir + "/ai-route escalate toggle"]); }
    // proactiveness dial (ai-awareness) — how much the orb nudges/guides on its own
    function fireAwareness(lvl) { if (!window.busy) { window.awareness = lvl; runAction(["bash", "-lc", window.binDir + "/ai-awareness " + lvl]); } }
    // per-model start/stop (vl/aux go through ai-mode for VRAM-conflict handling)
    function toggleModel(m) {
        if (window.busy) return;
        var on = window.services && window.services[m.svc] === true;
        if (m.action === "vision")    runAction(["bash", "-lc", window.binDir + "/ai-mode " + (on ? "vision-off" : "vision-on")]);
        else if (m.action === "aux")  runAction(["bash", "-lc", window.binDir + "/ai-mode " + (on ? "aux-off" : "aux-on")]);
        else                          runAction(["systemctl", "--user", (on ? "stop" : "start"), m.unit]);
    }
    // voice stack toggle — whisper + Kokoro start/stop together via `ai-mode`
    // (on-demand, like ComfyUI). voice-on if the loop isn't fully live yet.
    function toggleVoice() {
        if (window.busy) return;
        runAction(["bash", "-lc", window.binDir + "/ai-mode " + (window.voiceUp ? "voice-off" : "voice-on")]);
    }

    // =========================================================================
    //  ambient + intro (gated on visibility — see MEMORY: quickshell iGPU repaint)
    // =========================================================================
    property real ambient: 0.0
    SequentialAnimation on ambient {
        loops: Animation.Infinite; running: window.visible
        NumberAnimation { to: 1.0; duration: 16000; easing.type: Easing.InOutSine }
        NumberAnimation { to: 0.0; duration: 16000; easing.type: Easing.InOutSine }
    }
    property real introMain: 0.0
    property real introHeader: 0.0
    property real introCards: 0.0
    ParallelAnimation {
        running: true
        NumberAnimation { target: window; property: "introMain";   from: 0; to: 1; duration: 700; easing.type: Easing.OutExpo }
        SequentialAnimation {
            PauseAnimation { duration: 90 }
            NumberAnimation { target: window; property: "introHeader"; from: 0; to: 1; duration: 650; easing.type: Easing.OutBack; easing.overshoot: 1.1 }
        }
        SequentialAnimation {
            PauseAnimation { duration: 200 }
            NumberAnimation { target: window; property: "introCards"; from: 0; to: 1; duration: 750; easing.type: Easing.OutExpo }
        }
    }

    // (Escape handling: Brain_Shell's PopupDismiss closes the dashboard —
    // the classic shell's qs_manager Escape handler was removed here.)

    // =========================================================================
    //  SHELL
    // =========================================================================
    Item {
        anchors.fill: parent
        scale: 0.96 + 0.04 * window.introMain
        opacity: window.introMain
        transform: Translate { y: window.s(18) * (1 - window.introMain) }

        Rectangle {
            anchors.fill: parent
            radius: window.s(22)
            color: window.base
            border.color: Qt.rgba(window.sapphire.r, window.sapphire.g, window.sapphire.b, 0.35)
            border.width: 1
            clip: true

            // faint ambient orb
            Rectangle {
                width: parent.width * 0.7; height: width; radius: width / 2
                x: parent.width - width * 0.55; y: -height * 0.3
                opacity: 0.06 + 0.03 * window.ambient; color: window.mauve
            }

            ColumnLayout {
                anchors.fill: parent
                anchors.margins: window.s(24)
                spacing: window.s(16)

                // ---------------------------------------------------------- header
                RowLayout {
                    Layout.fillWidth: true
                    spacing: window.s(14)
                    opacity: window.introHeader
                    transform: Translate { y: window.s(16) * (1 - window.introHeader) }

                    // breathing orb accent
                    Item {
                        Layout.preferredWidth: window.s(40); Layout.preferredHeight: window.s(40)
                        Rectangle {
                            anchors.fill: parent; radius: width / 2; color: "transparent"
                            border.width: window.s(2)
                            border.color: Qt.rgba(window.mauve.r, window.mauve.g, window.mauve.b, 0.5)
                        }
                        Rectangle {
                            anchors.centerIn: parent
                            width: parent.width * (0.46 + 0.06 * window.ambient); height: width
                            radius: width / 2
                            color: Qt.tint(window.mauve, Qt.rgba(window.blue.r, window.blue.g, window.blue.b, window.ambient))
                            layer.enabled: true
                            layer.effect: MultiEffect { blurEnabled: true; blur: 0.6; blurMax: 16 }
                        }
                    }
                    ColumnLayout {
                        spacing: 0; Layout.fillWidth: true
                        Text {
                            text: "AI Workload"
                            font.family: "JetBrains Mono"; font.weight: Font.Black
                            font.pixelSize: window.s(22); color: window.text
                        }
                        Text {
                            text: "Hermes router · " + (window.hermesUp ? "online" : "offline")
                            font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                            color: window.hermesUp ? window.subtext0 : window.red
                        }
                    }
                    Item { Layout.fillWidth: true }
                    // workload mode chip
                    Rectangle {
                        radius: window.s(11); height: window.s(30)
                        width: modeLbl.implicitWidth + window.s(26)
                        property color mc: window.modeColor(window.mode)
                        color: Qt.rgba(mc.r, mc.g, mc.b, 0.18)
                        border.width: 1; border.color: Qt.rgba(mc.r, mc.g, mc.b, 0.5)
                        Behavior on color { ColorAnimation { duration: 400 } }
                        Behavior on border.color { ColorAnimation { duration: 400 } }
                        Text {
                            id: modeLbl; anchors.centerIn: parent
                            text: window.mode.toUpperCase()
                            font.family: "JetBrains Mono"; font.weight: Font.Bold
                            font.pixelSize: window.s(12); color: parent.mc
                            Behavior on color { ColorAnimation { duration: 400 } }
                        }
                    }
                }

                // ------------------------------------------------- workload selector
                SectionLabel { text: "WORKLOAD" }
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(10)
                    opacity: window.introHeader
                    Repeater {
                        model: [
                            { key: "default",        label: "Default",   icon: "󰧑" },
                            { key: "generate-light", label: "Gen·Light", icon: "󰟽" },
                            { key: "generate-heavy", label: "Gen·Heavy", icon: "󰟽" },
                            { key: "game",           label: "Game",      icon: "󰊴" },
                            { key: "vision-on",      label: "Vision",    icon: "󰋩" }
                        ]
                        delegate: Rectangle {
                            id: modeBtn
                            required property var modelData
                            Layout.fillWidth: true
                            height: window.s(44); radius: window.s(13)
                            // Inference/Generation are the R9700 workload (radio on window.mode).
                            // Vision is a 3080 Ti toggle. Gaming = the 3080 Ti is FREE (no vl/aux)
                            // and is orthogonal — it can be active alongside inference or generation.
                            property bool isActive: {
                                if (modelData.key === "vision-on")
                                    return window.services && window.services.vl === true;
                                if (modelData.key === "game")
                                    return window.services && window.services.vl !== true
                                                            && window.services.aux !== true;
                                return window.mode === modelData.key;
                            }
                            property bool hovered: ma.containsMouse
                            // generate-heavy tears down the resident gpt-oss → confirm first.
                            // game just frees the 3080 Ti, so it fires immediately.
                            property bool destructive: modelData.key === "generate-heavy"
                            readonly property bool confirming: window.armedMode === modelData.key
                            Timer { id: confirmTimer; interval: 3000
                                    onTriggered: if (window.armedMode === modelData.key) window.armedMode = "" }

                            color: confirming ? Qt.rgba(window.red.r, window.red.g, window.red.b, 0.28)
                                  : isActive  ? Qt.rgba(window.sapphire.r, window.sapphire.g, window.sapphire.b, 0.22)
                                  : hovered   ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6)
                                              : Qt.rgba(window.surface0.r, window.surface0.g, window.surface0.b, 0.45)
                            border.width: (isActive || confirming) ? 1 : 0
                            border.color: confirming ? window.red : window.sapphire
                            Behavior on color { ColorAnimation { duration: 200 } }
                            scale: hovered ? 1.04 : 1.0
                            Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutExpo } }

                            ColumnLayout {
                                anchors.centerIn: parent; spacing: window.s(2)
                                Text {
                                    Layout.alignment: Qt.AlignHCenter; text: modelData.icon
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(17)
                                    color: modeBtn.confirming ? window.red : modeBtn.isActive ? window.sapphire : window.subtext0
                                }
                                Text {
                                    Layout.alignment: Qt.AlignHCenter
                                    text: modeBtn.confirming ? "Confirm?" : modelData.label
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(11)
                                    font.weight: modeBtn.confirming ? Font.Bold : Font.Normal
                                    color: modeBtn.confirming ? window.red : modeBtn.isActive ? window.text : window.subtext0
                                }
                            }
                            MouseArea {
                                id: ma; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; enabled: !window.busy
                                onClicked: {
                                    if (modeBtn.destructive && window.armedMode !== modelData.key) {
                                        window.armedMode = modelData.key; confirmTimer.restart(); return;
                                    }
                                    window.armedMode = ""; confirmTimer.stop();
                                    window.fireMode(modelData.key);
                                }
                            }
                        }
                    }
                }

                // ---------------------------------------------------- GPU cards row
                //  3× R9700 (AMD) + 1× 3080 Ti (NVIDIA) in one row. A coloured
                //  brand strip + badge groups the AMD cluster and sets the lone
                //  NVIDIA card apart; the ring/dot/model pill stay role-coloured.
                RowLayout {
                    Layout.fillWidth: true
                    Layout.fillHeight: false                // nested RowLayout defaults to fill — disable
                    Layout.preferredHeight: window.s(250)   // fixed compact height (don't stretch)
                    spacing: window.s(12)
                    opacity: window.introCards
                    transform: Translate { y: window.s(20) * (1 - window.introCards) }
                    Repeater {
                        // STABLE slot count so live polling updates each card's bindings
                        // in place instead of destroying+recreating the delegates every
                        // 1.5s (which resets the ring animation). 4 = 3× R9700 + 3080 Ti.
                        model: 4
                        delegate: Rectangle {
                            id: card
                            required property int index
                            readonly property var gpu: (window.gpus && window.gpus.length > index) ? window.gpus[index] : null
                            readonly property var theme: window
                            Layout.fillWidth: true
                            Layout.fillHeight: true
                            radius: theme.s(16)
                            clip: true
                            readonly property bool isNv: gpu && gpu.kind === "nvidia"
                            readonly property bool busy: gpu && gpu.model
                            readonly property color brandCol: theme.brandColor(gpu ? gpu.kind : "amd")
                            // active cards lift toward their role colour; idle stay neutral
                            color: busy ? Qt.rgba(roleCol.r, roleCol.g, roleCol.b, 0.07)
                                        : Qt.rgba(theme.surface0.r, theme.surface0.g, theme.surface0.b, 0.40)
                            Behavior on color { ColorAnimation { duration: 400 } }
                            border.width: 1
                            border.color: busy ? Qt.rgba(roleCol.r, roleCol.g, roleCol.b, 0.55)
                                               : Qt.rgba(theme.surface2.r, theme.surface2.g, theme.surface2.b, 0.5)
                            Behavior on border.color { ColorAnimation { duration: 400 } }

                            // subtle hover lift (HoverHandler — doesn't block inner content)
                            HoverHandler { id: cardHover }
                            scale: cardHover.hovered ? 1.015 : 1.0
                            Behavior on scale { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

                            readonly property color roleCol: theme.roleColor(gpu && gpu.role ? gpu.role : "idle")
                            readonly property real vramFrac: (gpu && gpu.vram_total > 0)
                                ? Math.max(0, Math.min(1, gpu.vram_used / gpu.vram_total)) : 0
                            property real animFrac: 0
                            Behavior on animFrac { NumberAnimation { duration: 700; easing.type: Easing.OutCubic } }
                            onVramFracChanged: animFrac = vramFrac
                            Component.onCompleted: animFrac = vramFrac

                            // brand accent strip across the top edge
                            Rectangle {
                                anchors { top: parent.top; left: parent.left; right: parent.right }
                                height: theme.s(3)
                                color: Qt.rgba(card.brandCol.r, card.brandCol.g, card.brandCol.b, card.gpu ? 0.85 : 0.25)
                            }

                            ColumnLayout {
                                anchors.fill: parent
                                anchors.margins: theme.s(13)
                                anchors.topMargin: theme.s(15)
                                spacing: theme.s(7)

                                // header: brand badge · label · role dot
                                RowLayout {
                                    Layout.fillWidth: true
                                    spacing: theme.s(6)
                                    Rectangle {
                                        Layout.preferredHeight: theme.s(16)
                                        Layout.preferredWidth: brandTxt.implicitWidth + theme.s(12)
                                        radius: theme.s(5)
                                        color: Qt.rgba(card.brandCol.r, card.brandCol.g, card.brandCol.b, 0.18)
                                        Text {
                                            id: brandTxt; anchors.centerIn: parent
                                            text: theme.brandName(card.gpu ? card.gpu.kind : "amd")
                                            font.family: "JetBrains Mono"; font.weight: Font.Black
                                            font.pixelSize: theme.s(8); font.letterSpacing: theme.s(0.5)
                                            color: card.brandCol
                                        }
                                    }
                                    Text {
                                        text: gpu ? (card.isNv ? "3080 Ti" : gpu.label.replace("R9700 ", "R9700·"))
                                                  : "—"
                                        font.family: "JetBrains Mono"; font.weight: Font.Bold
                                        font.pixelSize: theme.s(12); color: theme.text
                                        elide: Text.ElideRight; Layout.fillWidth: true
                                    }
                                    Rectangle {
                                        width: theme.s(9); height: width; radius: width/2
                                        color: card.busy ? card.roleCol : theme.overlay0
                                        Behavior on color { ColorAnimation { duration: 300 } }
                                    }
                                }

                                Item { Layout.fillHeight: true }

                                Item {
                                    Layout.alignment: Qt.AlignHCenter
                                    Layout.preferredHeight: theme.s(116)
                                    Layout.preferredWidth: theme.s(116)
                                    Canvas {
                                        id: ring
                                        anchors.centerIn: parent
                                        width: theme.s(112); height: width
                                        property real frac: card.animFrac
                                        property color arcColor: card.roleCol
                                        property color trackColor: Qt.rgba(theme.surface2.r, theme.surface2.g, theme.surface2.b, 0.45)
                                        onFracChanged: requestPaint()
                                        onArcColorChanged: requestPaint()
                                        onPaint: {
                                            function rgba(c,a){ return "rgba("+Math.round(c.r*255)+","+Math.round(c.g*255)+","+Math.round(c.b*255)+","+a+")"; }
                                            let ctx = getContext("2d"); ctx.reset();
                                            let cx = width/2, cy = height/2;
                                            let r = width/2 - theme.s(9);
                                            let lw = theme.s(9);
                                            let start = -Math.PI/2;
                                            ctx.lineCap = "round";
                                            // track
                                            ctx.beginPath(); ctx.arc(cx, cy, r, 0, Math.PI*2);
                                            ctx.lineWidth = lw; ctx.strokeStyle = trackColor; ctx.stroke();
                                            if (frac > 0.001) {
                                                // soft glow under the arc
                                                ctx.beginPath();
                                                ctx.arc(cx, cy, r, start, start + Math.PI*2*frac);
                                                ctx.lineWidth = lw + theme.s(4);
                                                ctx.strokeStyle = rgba(arcColor, 0.18); ctx.stroke();
                                                // arc
                                                ctx.beginPath();
                                                ctx.arc(cx, cy, r, start, start + Math.PI*2*frac);
                                                ctx.lineWidth = lw; ctx.strokeStyle = arcColor; ctx.stroke();
                                            }
                                        }
                                    }
                                    ColumnLayout {
                                        anchors.centerIn: parent; spacing: 0
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: Math.round(card.vramFrac * 100) + "%"
                                            font.family: "JetBrains Mono"; font.weight: Font.Black
                                            font.pixelSize: theme.s(22); color: theme.text
                                        }
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            text: "VRAM"
                                            font.family: "JetBrains Mono"; font.weight: Font.Bold
                                            font.pixelSize: theme.s(8); font.letterSpacing: theme.s(1.5)
                                            color: theme.overlay1
                                        }
                                        Text {
                                            Layout.alignment: Qt.AlignHCenter
                                            Layout.topMargin: theme.s(2)
                                            text: (gpu && gpu.vram_used != null)
                                                ? (gpu.vram_used/1024).toFixed(1) + " / " + (gpu.vram_total/1024).toFixed(0) + "G" : "—"
                                            font.family: "JetBrains Mono"; font.pixelSize: theme.s(10); color: theme.subtext0
                                        }
                                    }
                                }

                                Rectangle {
                                    Layout.fillWidth: true
                                    height: theme.s(26); radius: theme.s(8)
                                    color: card.busy ? Qt.rgba(card.roleCol.r, card.roleCol.g, card.roleCol.b, 0.16) : "transparent"
                                    border.width: card.busy ? 0 : 1
                                    border.color: Qt.rgba(theme.surface2.r, theme.surface2.g, theme.surface2.b, 0.4)
                                    Behavior on color { ColorAnimation { duration: 300 } }
                                    Text {
                                        anchors.centerIn: parent
                                        width: parent.width - theme.s(14); horizontalAlignment: Text.AlignHCenter; elide: Text.ElideRight
                                        text: card.busy ? gpu.model : "idle"
                                        font.family: "JetBrains Mono"; font.pixelSize: theme.s(11)
                                        font.weight: card.busy ? Font.Medium : Font.Normal
                                        color: card.busy ? theme.text : theme.overlay0
                                    }
                                }

                                // util mini-bar
                                Rectangle {
                                    Layout.fillWidth: true
                                    height: theme.s(5); radius: height / 2
                                    color: Qt.rgba(theme.surface2.r, theme.surface2.g, theme.surface2.b, 0.5)
                                    Rectangle {
                                        height: parent.height; radius: height / 2
                                        width: parent.width * Math.max(0, Math.min(1, (gpu && gpu.util != null ? gpu.util : 0) / 100))
                                        color: (gpu && gpu.util > 50) ? theme.peach : card.roleCol
                                        Behavior on width { NumberAnimation { duration: 500; easing.type: Easing.OutCubic } }
                                        Behavior on color { ColorAnimation { duration: 300 } }
                                    }
                                }

                                RowLayout {
                                    Layout.fillWidth: true
                                    Text {
                                        text: "󰔏 " + (gpu && gpu.temp != null ? gpu.temp : "—") + "°"
                                        font.family: "Iosevka Nerd Font"; font.pixelSize: theme.s(11)
                                        color: theme.tempColor(gpu ? gpu.temp : null)
                                    }
                                    Item { Layout.fillWidth: true }
                                    Text {
                                        text: "util " + (gpu && gpu.util != null ? gpu.util : "—") + "%"
                                        font.family: "JetBrains Mono"; font.pixelSize: theme.s(11)
                                        color: (gpu && gpu.util > 50) ? theme.peach : theme.subtext0
                                    }
                                }

                                Item { Layout.fillHeight: true }
                            }
                        }
                    }
                }

                // ------------------------------------------- Hermes flow (animated)
                //  Colorful comet particles stream from each active GPU into a
                //  pulsing Hermes core; idle GPUs show a faint static edge. Gated
                //  on window.visible (see MEMORY: quickshell iGPU repaint).
                Canvas {
                    id: flow
                    Layout.fillWidth: true
                    Layout.preferredHeight: window.s(88)
                    opacity: window.introCards
                    property real phase: 0
                    // SPEED tracks reality: a slow ambient drift when the cluster is
                    // idle, accelerating toward a tight, energetic loop as the average
                    // GPU utilisation climbs. (binding updates take effect each loop.)
                    readonly property int flowDur: window.flowActive
                        ? Math.round(2400 - 1500 * window.flowActivity)   // 2400ms warm → 900ms maxed
                        : 5200                                            // idle: gentle drift
                    NumberAnimation on phase {
                        running: window.visible; loops: Animation.Infinite
                        from: 0; to: 1; duration: flow.flowDur
                    }
                    onPhaseChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    Connections { target: window
                        function onServicesChanged() { flow.requestPaint() }
                        function onGpusChanged()     { flow.requestPaint() }
                        function onRouterChanged()   { flow.requestPaint() } }

                    onPaint: {
                        var ctx = getContext("2d"); ctx.reset();
                        var gpus = window.gpus || []; var n = gpus.length;
                        if (n === 0) return;

                        function cubic(a,b,c,d,t){ var u=1-t; return u*u*u*a + 3*u*u*t*b + 3*u*t*t*c + t*t*t*d; }
                        function rgba(c,a){ return "rgba(" + Math.round(c.r*255) + "," + Math.round(c.g*255) + "," + Math.round(c.b*255) + "," + a + ")"; }
                        function mix(a,b,t){ return { r:a.r+(b.r-a.r)*t, g:a.g+(b.g-a.g)*t, b:a.b+(b.b-a.b)*t }; }

                        var sp = window.s(14);
                        var cardW = (width - sp*(n-1)) / n;
                        var hubX = width/2, hubY = height*0.58, topY = window.s(3);
                        var svc = window.services || ({});
                        var warm = window.flowColor;     // routing-privacy warmth tints the stream

                        // cubic control points for edge i (port under card i → hub)
                        function ctrl(i){ var gx = i*(cardW+sp)+cardW/2;
                            return { ax:gx, bx:gx, cx2:hubX, dx:hubX, ay:topY, by:hubY, cy:topY, dy:hubY }; }
                        function px(p,t){ return cubic(p.ax,p.bx,p.cx2,p.dx,t); }
                        function py(p,t){ return cubic(p.ay,p.by,p.cy,p.dy,t); }

                        ctx.lineCap = "round";
                        for (var i=0;i<n;i++){
                            var g = gpus[i];
                            var active = (g && g.kind==="nvidia") ? (svc.vl===true||svc.aux===true) : (svc.coder===true||svc.think===true);
                            // THIS card's own utilisation drives its comet density + brightness
                            var util = (g && g.util != null) ? Math.max(0, Math.min(1, g.util/100)) : 0;
                            var role = window.roleColor(g && g.role ? g.role : "idle");
                            // stream colour = per-GPU role tinted toward the routing warmth
                            var stream = active ? mix(role, warm, 0.42) : window.overlay0;
                            var p = ctrl(i);

                            // base edge — brightens with this card's utilisation
                            ctx.beginPath(); ctx.moveTo(p.ax,p.ay); ctx.bezierCurveTo(p.bx,p.by,p.cx2,p.cy,p.dx,p.dy);
                            ctx.strokeStyle = rgba(stream, active ? (0.15 + 0.22*util) : 0.10);
                            ctx.lineWidth = window.s(1.5); ctx.stroke();

                            // source port (aligned under each GPU card) — swells when busy
                            var portR = window.s(2.7) + window.s(1.5)*util;
                            ctx.beginPath(); ctx.arc(p.ax,p.ay, portR, 0, Math.PI*2);
                            ctx.fillStyle = rgba(stream, active ? 0.95 : 0.42); ctx.fill();

                            if (!active) continue;

                            // DENSITY + tail length scale with utilisation, so a hot GPU
                            // reads as a thick, fast comet train and a near-idle one as a
                            // single faint blip. A per-card offset de-syncs the streams.
                            var PARTS = 1 + Math.round(util*3);   // 1 → 4
                            var TAIL  = 4 + Math.round(util*5);   // 4 → 9
                            var off   = i*0.13;
                            for (var k=0;k<PARTS;k++){
                                var head = (flow.phase + off + k/PARTS) % 1.0;
                                for (var j=0;j<TAIL;j++){
                                    var t = head - j*0.020;
                                    if (t < 0 || t > 1) continue;
                                    var x = px(p,t), y = py(p,t);
                                    var fade = 1 - j/TAIL;
                                    if (j===0) {
                                        var rad = window.s(3.0) + window.s(1.5)*util;
                                        var grd = ctx.createRadialGradient(x,y,0, x,y, rad*2.6);
                                        grd.addColorStop(0, rgba(stream, 0.92));
                                        grd.addColorStop(1, rgba(stream, 0));
                                        ctx.fillStyle = grd; ctx.beginPath(); ctx.arc(x,y, rad*2.6, 0, Math.PI*2); ctx.fill();
                                        ctx.fillStyle = rgba({r:1,g:1,b:1}, 0.95);
                                        ctx.beginPath(); ctx.arc(x,y, window.s(1.6), 0, Math.PI*2); ctx.fill();
                                    } else {
                                        ctx.fillStyle = rgba(stream, 0.85*fade);
                                        ctx.beginPath(); ctx.arc(x,y, Math.max(0.6, window.s(2.4)*fade), 0, Math.PI*2); ctx.fill();
                                    }
                                }
                            }
                        }

                        // pulsing Hermes core — size + glow track overall activity, and
                        // its colour takes the routing-privacy warmth (sapphire when idle).
                        var act = window.flowActivity;
                        var anyActive = window.flowActive;
                        var pulse = 0.5 + 0.5*Math.sin(flow.phase*Math.PI*2);
                        var core = anyActive ? warm : window.sapphire;
                        var hubR = window.s(6) + window.s(3)*pulse + window.s(4)*act;
                        var hg = ctx.createRadialGradient(hubX,hubY,0, hubX,hubY, hubR*3.0);
                        hg.addColorStop(0, rgba(core, anyActive ? (0.68 + 0.27*act) : 0.40));
                        hg.addColorStop(1, rgba(core, 0));
                        ctx.fillStyle = hg; ctx.beginPath(); ctx.arc(hubX,hubY, hubR*3.0, 0, Math.PI*2); ctx.fill();
                        ctx.fillStyle = rgba(core, 0.95);
                        ctx.beginPath(); ctx.arc(hubX,hubY, window.s(5), 0, Math.PI*2); ctx.fill();
                        ctx.fillStyle = rgba({r:1,g:1,b:1}, 0.7);
                        ctx.beginPath(); ctx.arc(hubX,hubY, window.s(2), 0, Math.PI*2); ctx.fill();
                    }

                    // convergence node — the streams meet here (drawn ABOVE the canvas glow)
                    Rectangle {
                        id: hubNode
                        x: flow.width/2 - width/2
                        y: flow.height*0.58 - height/2
                        width: hubLbl.implicitWidth + window.s(22)
                        height: window.s(25)
                        radius: height/2
                        color: Qt.rgba(window.base.r, window.base.g, window.base.b, 0.82)
                        border.width: 1
                        property color edgeCol: window.flowActive ? window.flowColor : window.sapphire
                        border.color: Qt.rgba(edgeCol.r, edgeCol.g, edgeCol.b, 0.55)
                        Behavior on border.color { ColorAnimation { duration: 500 } }
                        Text {
                            id: hubLbl; anchors.centerIn: parent
                            text: "Luis' AI"
                            font.family: "JetBrains Mono"; font.weight: Font.Bold
                            font.pixelSize: window.s(12.5); color: window.text
                        }
                    }
                }

                // ------------------------------------------------------ ROUTING row
                SectionLabel { text: "ROUTING" }
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(10)
                    // privacy segmented control
                    Repeater {
                        model: [
                            { value: "open",   label: "Auto",    icon: "󰓀", accent: window.mauve },
                            { value: "local",  label: "Local",   icon: "󰒓", accent: window.green },
                            { value: "duckai", label: "Private", icon: "󰗹", accent: window.blue }
                        ]
                        delegate: Rectangle {
                            id: routeBtn
                            required property var modelData
                            Layout.fillWidth: true
                            height: window.s(40); radius: window.s(12)
                            readonly property bool isActive: (window.router && window.router.privacy ? window.router.privacy : "open") === modelData.value
                            property bool hovered: rma.containsMouse
                            color: isActive ? Qt.rgba(modelData.accent.r, modelData.accent.g, modelData.accent.b, 0.20)
                                  : hovered  ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6)
                                             : Qt.rgba(window.surface0.r, window.surface0.g, window.surface0.b, 0.45)
                            border.width: isActive ? 1 : 0
                            border.color: modelData.accent
                            opacity: window.busy ? 0.6 : 1.0
                            Behavior on color { ColorAnimation { duration: 160 } }
                            RowLayout {
                                anchors.centerIn: parent; spacing: window.s(7)
                                Text {
                                    text: modelData.icon
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(15)
                                    color: routeBtn.isActive ? modelData.accent : window.subtext0
                                }
                                Text {
                                    text: modelData.label
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                    font.weight: routeBtn.isActive ? Font.Bold : Font.Normal
                                    color: routeBtn.isActive ? window.text : window.subtext0
                                }
                            }
                            MouseArea {
                                id: rma; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; enabled: !window.busy
                                onClicked: window.fireRoute(modelData.value)
                            }
                        }
                    }
                    // Grok escalation toggle
                    Rectangle {
                        Layout.preferredWidth: window.s(150)
                        height: window.s(40); radius: window.s(12)
                        color: Qt.rgba(window.surface0.r, window.surface0.g, window.surface0.b, 0.45)
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: window.s(12); anchors.rightMargin: window.s(8)
                            spacing: window.s(8)
                            Text {
                                text: "󱓞 Grok"
                                font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(12)
                                color: window.subtext0; Layout.fillWidth: true; elide: Text.ElideRight
                            }
                            Rectangle {
                                property bool on: window.router && window.router.escalate === true
                                Layout.preferredWidth: window.s(42); Layout.preferredHeight: window.s(22)
                                radius: height / 2
                                color: on ? Qt.rgba(window.green.r, window.green.g, window.green.b, 0.35) : window.surface2
                                Behavior on color { ColorAnimation { duration: 160 } }
                                Rectangle {
                                    width: window.s(16); height: width; radius: width / 2
                                    color: parent.on ? window.green : window.subtext1
                                    y: (parent.height - height) / 2
                                    x: parent.on ? parent.width - width - window.s(3) : window.s(3)
                                    Behavior on x { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                }
                                MouseArea {
                                    anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                    enabled: !window.busy; onClicked: window.toggleEscalate()
                                }
                            }
                        }
                    }
                }

                // ----------------------------------------------------- AWARENESS dial
                SectionLabel { text: "AWARENESS" }
                ColumnLayout {
                    id: awBox
                    Layout.fillWidth: true; spacing: window.s(9)
                    readonly property var awModel: [
                        { lvl: 0, label: "Off",        accent: window.overlay0 },
                        { lvl: 1, label: "Notify",     accent: window.blue },
                        { lvl: 2, label: "Occasional", accent: window.sapphire },
                        { lvl: 3, label: "Active",     accent: window.mauve },
                        { lvl: 4, label: "Chatty",     accent: window.pink }
                    ]
                    readonly property color awAccent: awModel[window.awareness]
                        ? awModel[window.awareness].accent : window.mauve

                    // ---- gradient segmented slider: cool (Off) → warm (Chatty) ----
                    Item {
                        id: awSlider
                        Layout.fillWidth: true
                        Layout.preferredHeight: window.s(30)
                        readonly property int seg: 5
                        readonly property real colW: width / seg
                        readonly property real knobX: (window.awareness + 0.5) * colW
                        opacity: window.busy ? 0.55 : 1.0
                        Behavior on opacity { NumberAnimation { duration: 160 } }

                        // dim rail (full cool→warm gradient)
                        Rectangle {
                            id: awRail
                            anchors.verticalCenter: parent.verticalCenter
                            width: parent.width; height: window.s(10); radius: height/2
                            opacity: 0.28
                            gradient: Gradient {
                                orientation: Gradient.Horizontal
                                GradientStop { position: 0.00; color: window.overlay0 }
                                GradientStop { position: 0.25; color: window.blue }
                                GradientStop { position: 0.50; color: window.sapphire }
                                GradientStop { position: 0.75; color: window.mauve }
                                GradientStop { position: 1.00; color: window.pink }
                            }
                        }
                        // bright fill up to the current level (clipped slice of the rail)
                        Item {
                            anchors.left: awRail.left; anchors.verticalCenter: parent.verticalCenter
                            width: awSlider.knobX; height: window.s(10); clip: true
                            Behavior on width { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                            Rectangle {
                                width: awSlider.width; height: parent.height; radius: height/2
                                gradient: Gradient {
                                    orientation: Gradient.Horizontal
                                    GradientStop { position: 0.00; color: window.overlay0 }
                                    GradientStop { position: 0.25; color: window.blue }
                                    GradientStop { position: 0.50; color: window.sapphire }
                                    GradientStop { position: 0.75; color: window.mauve }
                                    GradientStop { position: 1.00; color: window.pink }
                                }
                            }
                        }
                        // segment tick marks (hidden under the active knob)
                        Repeater {
                            model: awBox.awModel
                            delegate: Rectangle {
                                required property var modelData
                                readonly property bool passed: window.awareness >= modelData.lvl
                                width: window.s(3); height: width; radius: width/2
                                anchors.verticalCenter: parent.verticalCenter
                                x: (modelData.lvl + 0.5) * awSlider.colW - width/2
                                visible: modelData.lvl !== window.awareness
                                color: passed ? Qt.rgba(window.crust.r, window.crust.g, window.crust.b, 0.85)
                                              : Qt.rgba(window.text.r, window.text.g, window.text.b, 0.22)
                            }
                        }
                        // sliding knob — a LIVE mini aurora orb (the voice orb's own
                        // shader): nearly still and dim at Off, swirling and warm at
                        // Chatty. The dial literally previews the orb's personality.
                        Item {
                            id: awKnob
                            width: window.s(30); height: width
                            anchors.verticalCenter: parent.verticalCenter
                            x: awSlider.knobX - width/2
                            Behavior on x { NumberAnimation { duration: 320; easing.type: Easing.OutBack; easing.overshoot: 1.2 } }

                            FrameAnimation {
                                running: awKnob.visible && (awKnob.Window.window?.visible ?? true)
                                onTriggered: knobOrb.uTime = elapsedTime
                            }
                            ShaderEffect {
                                id: knobOrb
                                anchors.fill: parent
                                visible: status !== ShaderEffect.Error
                                fragmentShader: Qt.resolvedUrl("../voice/orb.frag.qsb")
                                property real uTime: 0
                                property real uLevel: 0
                                property real uEnv:    0.06 + 0.14 * window.awareness
                                property real uSpin:   0.30 + 0.45 * window.awareness
                                property real uBreath: 0.02 + 0.006 * window.awareness
                                property real uGlow:   window.awareness === 0 ? 0.35 : 0.8
                                property real uThink:  0
                                property real uErr:    0
                                property real uSpeak:  window.awareness >= 3 ? 1 : 0
                                property color uPri: awBox.awAccent
                                property color uSec: window.awareness === 0 ? window.surface2 : window.blue
                                property color uAcc: window.teal
                                Behavior on uEnv  { NumberAnimation { duration: 300 } }
                                Behavior on uSpin { NumberAnimation { duration: 300 } }
                                Behavior on uPri  { ColorAnimation { duration: 240 } }
                                Behavior on uSec  { ColorAnimation { duration: 240 } }
                            }
                            // fallback (shader missing): the old accent-dot knob
                            Rectangle {
                                visible: knobOrb.status === ShaderEffect.Error
                                anchors.centerIn: parent
                                width: window.s(22); height: width; radius: width/2
                                color: window.base
                                border.width: window.s(2.5); border.color: awBox.awAccent
                                Rectangle {
                                    anchors.centerIn: parent
                                    width: parent.width * 0.42; height: width; radius: width/2
                                    color: awBox.awAccent
                                }
                            }
                            layer.enabled: true
                            layer.effect: MultiEffect {
                                shadowEnabled: true; shadowColor: awBox.awAccent
                                shadowBlur: 0.9; shadowVerticalOffset: 0; shadowHorizontalOffset: 0
                            }
                        }
                        // click zones — one transparent cell per segment
                        Row {
                            anchors.fill: parent
                            Repeater {
                                model: awBox.awModel
                                delegate: MouseArea {
                                    required property var modelData
                                    width: awSlider.colW; height: awSlider.height
                                    hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    enabled: !window.busy
                                    onClicked: window.fireAwareness(modelData.lvl)
                                }
                            }
                        }
                    }
                    // labels under the track, aligned to each segment
                    RowLayout {
                        Layout.fillWidth: true; spacing: 0
                        Repeater {
                            model: awBox.awModel
                            delegate: Text {
                                required property var modelData
                                readonly property bool isActive: window.awareness === modelData.lvl
                                Layout.fillWidth: true
                                horizontalAlignment: Text.AlignHCenter
                                text: modelData.label
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                                font.weight: isActive ? Font.Bold : Font.Normal
                                color: isActive ? window.text : window.subtext0
                                opacity: isActive ? 1.0 : 0.65
                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                        }
                    }
                    // description for the active level
                    Text {
                        Layout.fillWidth: true
                        text: [ "Pull-only — Hermes speaks only when you ask.",
                                "Silent desktop notifications on notable events.",
                                "Rare brief spoken nudges at key moments only.",
                                "Check-ins that read the room — glances at your screen, knows work from chill.",
                                "Conversational — checks in often, asks and listens. A real back-and-forth." ][window.awareness] || ""
                        font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                        color: window.subtext0; opacity: 0.85; wrapMode: Text.Wrap
                    }
                }

                // ------------------------------------------------------- MODELS row
                SectionLabel { text: "MODELS" }
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(8)
                    Repeater {
                        model: [
                            { key: "gptoss", label: "gpt-oss", svc: "coder",  action: "svc",    unit: "llama-gpt-oss.service",   accent: window.mauve },
                            { key: "think",  label: "Think",   svc: "think",  action: "svc",    unit: "llama-think.service",     accent: window.blue },
                            { key: "vl",     label: "Vision",  svc: "vl",     action: "vision", unit: "",                        accent: window.teal },
                            { key: "embed",  label: "Embed",   svc: "embed",  action: "svc",    unit: "llama-embed.service",     accent: window.peach },
                            { key: "rerank", label: "Rerank",  svc: "rerank", action: "svc",    unit: "llama-reranker.service",  accent: window.sapphire },
                            { key: "aux",    label: "Aux",     svc: "aux",    action: "aux",    unit: "",                        accent: window.green }
                        ]
                        delegate: Rectangle {
                            id: mdl
                            required property var modelData
                            Layout.fillWidth: true
                            height: window.s(38); radius: window.s(11)
                            readonly property bool on: window.services && window.services[modelData.svc] === true
                            property bool hovered: mma.containsMouse
                            color: on ? Qt.rgba(modelData.accent.r, modelData.accent.g, modelData.accent.b, 0.18)
                                 : hovered ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6)
                                           : Qt.rgba(window.surface0.r, window.surface0.g, window.surface0.b, 0.45)
                            border.width: on ? 1 : 0
                            border.color: Qt.rgba(modelData.accent.r, modelData.accent.g, modelData.accent.b, 0.6)
                            opacity: window.busy ? 0.6 : 1.0
                            Behavior on color { ColorAnimation { duration: 160 } }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: window.s(10); anchors.rightMargin: window.s(10)
                                spacing: window.s(7)
                                Rectangle {
                                    width: window.s(8); height: width; radius: width / 2
                                    color: mdl.on ? modelData.accent : window.overlay0
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                Text {
                                    text: modelData.label; Layout.fillWidth: true
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                    font.weight: mdl.on ? Font.Bold : Font.Normal
                                    color: mdl.on ? window.text : window.subtext0
                                }
                                Text {
                                    text: mdl.on ? "on" : "off"
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                                    color: mdl.on ? modelData.accent : window.overlay0
                                }
                            }
                            MouseArea {
                                id: mma; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; enabled: !window.busy
                                onClicked: window.toggleModel(modelData)
                            }
                        }
                    }
                }

                // --------------------------------------------------------- VOICE row
                //  On-demand voice stack: whisper STT (:8094) + Kokoro TTS (:8095).
                //  The left "Voice Mode" chip reflects whether the native voice loop
                //  is live (both servers up) and breathes when active; the two pills
                //  mirror the MODELS-pill style. All three toggle the WHOLE stack via
                //  `ai-mode voice-on/off` (whisper + Kokoro come up/down together).
                SectionLabel { text: "VOICE" }
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(8)

                    // native voice-mode indicator + master toggle
                    Rectangle {
                        id: voiceChip
                        Layout.preferredWidth: window.s(180)
                        height: window.s(38); radius: window.s(11)
                        readonly property bool on: window.voiceUp
                        property bool hovered: vma.containsMouse
                        color: on ? Qt.rgba(window.teal.r, window.teal.g, window.teal.b, 0.18)
                             : hovered ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6)
                                       : Qt.rgba(window.surface0.r, window.surface0.g, window.surface0.b, 0.45)
                        border.width: on ? 1 : 0
                        border.color: Qt.rgba(window.teal.r, window.teal.g, window.teal.b, 0.6)
                        opacity: window.busy ? 0.6 : 1.0
                        Behavior on color { ColorAnimation { duration: 160 } }
                        RowLayout {
                            anchors.fill: parent; anchors.leftMargin: window.s(12); anchors.rightMargin: window.s(12)
                            spacing: window.s(8)
                            // mic glyph; the live dot beside it breathes with the ambient clock
                            Rectangle {
                                Layout.preferredWidth: window.s(8); Layout.preferredHeight: window.s(8)
                                radius: width / 2
                                color: voiceChip.on ? window.teal : window.overlay0
                                opacity: voiceChip.on ? (0.55 + 0.45 * window.ambient) : 1.0
                                Behavior on color { ColorAnimation { duration: 200 } }
                            }
                            Text {
                                text: "󰍬"
                                font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(14)
                                color: voiceChip.on ? window.teal : window.subtext0
                            }
                            Text {
                                text: "Voice Mode"; Layout.fillWidth: true
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                font.weight: voiceChip.on ? Font.Bold : Font.Normal
                                color: voiceChip.on ? window.text : window.subtext0
                                elide: Text.ElideRight
                            }
                            Text {
                                text: voiceChip.on ? "live" : "off"
                                font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                                color: voiceChip.on ? window.teal : window.overlay0
                            }
                        }
                        MouseArea {
                            id: vma; anchors.fill: parent; hoverEnabled: true
                            cursorShape: Qt.PointingHandCursor; enabled: !window.busy
                            onClicked: window.toggleVoice()
                        }
                    }

                    // whisper STT + Kokoro TTS pills (MODELS-pill style)
                    Repeater {
                        model: [
                            { key: "whisper", label: "Whisper STT", port: ":8094", svc: "whisper", icon: "󰍬", accent: window.sapphire },
                            { key: "kokoro",  label: "Kokoro TTS",  port: ":8095", svc: "kokoro",  icon: "󰓃", accent: window.pink }
                        ]
                        delegate: Rectangle {
                            id: vpill
                            required property var modelData
                            Layout.fillWidth: true
                            height: window.s(38); radius: window.s(11)
                            readonly property bool on: window.services && window.services[modelData.svc] === true
                            property bool hovered: vpma.containsMouse
                            color: on ? Qt.rgba(modelData.accent.r, modelData.accent.g, modelData.accent.b, 0.18)
                                 : hovered ? Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6)
                                           : Qt.rgba(window.surface0.r, window.surface0.g, window.surface0.b, 0.45)
                            border.width: on ? 1 : 0
                            border.color: Qt.rgba(modelData.accent.r, modelData.accent.g, modelData.accent.b, 0.6)
                            opacity: window.busy ? 0.6 : 1.0
                            Behavior on color { ColorAnimation { duration: 160 } }
                            RowLayout {
                                anchors.fill: parent; anchors.leftMargin: window.s(10); anchors.rightMargin: window.s(10)
                                spacing: window.s(7)
                                Rectangle {
                                    width: window.s(8); height: width; radius: width / 2
                                    color: vpill.on ? modelData.accent : window.overlay0
                                    Behavior on color { ColorAnimation { duration: 200 } }
                                }
                                Text {
                                    text: modelData.icon
                                    font.family: "Iosevka Nerd Font"; font.pixelSize: window.s(13)
                                    color: vpill.on ? modelData.accent : window.subtext0
                                }
                                Text {
                                    text: modelData.label; Layout.fillWidth: true
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(12)
                                    font.weight: vpill.on ? Font.Bold : Font.Normal
                                    color: vpill.on ? window.text : window.subtext0
                                    elide: Text.ElideRight
                                }
                                Text {
                                    text: modelData.port
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(10)
                                    color: vpill.on ? modelData.accent : window.overlay0
                                }
                            }
                            MouseArea {
                                id: vpma; anchors.fill: parent; hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor; enabled: !window.busy
                                onClicked: window.toggleVoice()
                            }
                        }
                    }
                }

                // -------------------------------------- ComfyUI quick row (when up)
                Rectangle {
                    Layout.fillWidth: true
                    property real rowH: window.comfyUp ? window.s(40) : 0
                    Behavior on rowH { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
                    Layout.preferredHeight: rowH
                    visible: rowH > 0.5
                    radius: window.s(12); clip: true
                    color: Qt.rgba(window.mauve.r, window.mauve.g, window.mauve.b, 0.12)
                    RowLayout {
                        anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(8)
                        Text {
                            text: "󰟽  ComfyUI"
                            font.family: "JetBrains Mono"; font.weight: Font.Bold
                            font.pixelSize: window.s(12); color: window.text
                        }
                        Item { Layout.fillWidth: true }
                        Repeater {
                            model: [ { port: 8188, label: "R9700 #0 · :8188" },
                                     { port: 8189, label: "R9700 #1 · :8189" } ]
                            delegate: Rectangle {
                                required property var modelData
                                Layout.preferredHeight: window.s(26)
                                Layout.preferredWidth: lbl.implicitWidth + window.s(20)
                                radius: window.s(9)
                                property bool hov: lma.containsMouse
                                color: hov ? Qt.rgba(window.mauve.r, window.mauve.g, window.mauve.b, 0.40)
                                           : Qt.rgba(window.surface1.r, window.surface1.g, window.surface1.b, 0.6)
                                Behavior on color { ColorAnimation { duration: 150 } }
                                Text {
                                    id: lbl; anchors.centerIn: parent
                                    text: "󰖟  " + modelData.label
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.text
                                }
                                MouseArea {
                                    id: lma; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.PointingHandCursor
                                    onClicked: Quickshell.execDetached(["xdg-open", "http://localhost:" + modelData.port])
                                }
                            }
                        }
                    }
                }

                // ------------------------------------------------ ACTIVITY (history)
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(8)
                    Text {
                        text: "ACTIVITY"
                        color: window.subtext1
                        font.family: "JetBrains Mono"; font.weight: Font.Bold
                        font.pixelSize: window.s(10); font.letterSpacing: window.s(2)
                    }
                    Item { Layout.preferredWidth: window.s(10) }
                    // metric selector — which series the chart plots
                    Repeater {
                        model: [ {k:"util",l:"Util"}, {k:"tokens",l:"Tokens"}, {k:"reqs",l:"Reqs"} ]
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool sel: window.metric === modelData.k
                            Layout.preferredHeight: window.s(22)
                            Layout.preferredWidth: ml.implicitWidth + window.s(16)
                            radius: window.s(8)
                            color: sel ? Qt.rgba(window.peach.r,window.peach.g,window.peach.b,0.22)
                                       : Qt.rgba(window.surface0.r,window.surface0.g,window.surface0.b,0.5)
                            border.width: sel ? 1 : 0; border.color: window.peach
                            Text { id: ml; anchors.centerIn: parent; text: modelData.l
                                   font.family:"JetBrains Mono"; font.pixelSize: window.s(10)
                                   color: sel ? window.text : window.subtext0 }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: window.metric = modelData.k }
                        }
                    }
                    Item { Layout.fillWidth: true }
                    Repeater {
                        model: [ {h:1,l:"1h"}, {h:6,l:"6h"}, {h:12,l:"12h"}, {h:24,l:"24h"}, {h:720,l:"30d"} ]
                        delegate: Rectangle {
                            required property var modelData
                            readonly property bool sel: window.rangeH === modelData.h
                            Layout.preferredWidth: window.s(38); Layout.preferredHeight: window.s(22)
                            radius: window.s(8)
                            color: sel ? Qt.rgba(window.sapphire.r,window.sapphire.g,window.sapphire.b,0.25)
                                       : Qt.rgba(window.surface0.r,window.surface0.g,window.surface0.b,0.5)
                            border.width: sel ? 1 : 0; border.color: window.sapphire
                            Text { anchors.centerIn: parent; text: modelData.l
                                   font.family:"JetBrains Mono"; font.pixelSize: window.s(10)
                                   color: sel ? window.text : window.subtext0 }
                            MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                                        onClicked: window.rangeH = modelData.h }
                        }
                    }
                }
                Canvas {
                    id: chart
                    Layout.fillWidth: true
                    Layout.preferredHeight: window.s(74)
                    property var histData: window.hist  // NOT 'data' — that shadows Item.data and children clobber the binding
                    property string m: window.metric
                    property int hoverIdx: -1            // bucket under the cursor (-1 = none)
                    onHistDataChanged: requestPaint()
                    onMChanged: requestPaint()
                    onWidthChanged: requestPaint()
                    onHoverIdxChanged: requestPaint()
                    onPaint: {
                        function rgba(c,a){ return "rgba("+Math.round(c.r*255)+","+Math.round(c.g*255)+","+Math.round(c.b*255)+","+a+")"; }
                        var ctx=getContext("2d"); ctx.reset();
                        var b=(window.hist&&window.hist.buckets)?window.hist.buckets:[];
                        var n=b.length; if(n<2) return;
                        var w=width, h=height, pad=window.s(2), gw=w/(n-1);
                        ctx.strokeStyle=rgba(window.surface2,0.5); ctx.lineWidth=1;
                        ctx.beginPath(); ctx.moveTo(0,h-pad); ctx.lineTo(w,h-pad); ctx.stroke();
                        // primary series = the selected metric.  For "tokens" the
                        // HONEST series is OUTPUT (completion) tokens — real generation.
                        // INPUT (re-fed context) is drawn faded on its own scale behind,
                        // since it's ~100x larger and would otherwise flatten the signal.
                        var key = window.metric;
                        var isTok = key==="tokens";
                        var col = isTok ? window.yellow : key==="reqs" ? window.green : window.peach;
                        function pv(bk){ return isTok ? (bk.tok_out||0) : (bk[key]||0); }
                        var mx = 1;
                        if (key==="util") mx = 100;                 // util is a fixed 0-100%
                        else { for (var i=0;i<n;i++) mx=Math.max(mx, pv(b[i])); }
                        // faded INPUT backdrop (own scale) when viewing tokens
                        if (isTok) {
                            var mi=1; for (var ii=0;ii<n;ii++) mi=Math.max(mi, b[ii].tok_in||0);
                            ctx.beginPath(); ctx.moveTo(0,h-pad);
                            for (var ji=0;ji<n;ji++){ var vi=b[ji].tok_in||0;
                                ctx.lineTo(ji*gw, h-pad-(h-2*pad)*Math.max(0,Math.min(1,vi/mi))); }
                            ctx.lineTo(w,h-pad); ctx.closePath();
                            ctx.fillStyle=rgba(window.overlay0,0.16); ctx.fill();
                        }
                        // area
                        ctx.beginPath(); ctx.moveTo(0,h-pad);
                        for (var j=0;j<n;j++){ var v=pv(b[j]);
                            ctx.lineTo(j*gw, h-pad-(h-2*pad)*Math.max(0,Math.min(1,v/mx))); }
                        ctx.lineTo(w,h-pad); ctx.closePath();
                        ctx.fillStyle=rgba(col,0.16); ctx.fill();
                        // line
                        ctx.beginPath();
                        for (var j2=0;j2<n;j2++){ var v2=pv(b[j2]);
                            var y2=h-pad-(h-2*pad)*Math.max(0,Math.min(1,v2/mx));
                            if(j2===0)ctx.moveTo(0,y2); else ctx.lineTo(j2*gw,y2); }
                        ctx.strokeStyle=rgba(col,0.9); ctx.lineWidth=window.s(1.5); ctx.stroke();
                        // VRAM context line (sapphire dashed, 0-32GB) — always shown
                        ctx.beginPath();
                        for (var k=0;k<n;k++){ var vv=Math.max(0,Math.min(32,b[k].vram||0));
                            var yv=h-pad-(h-2*pad)*(vv/32); if(k===0)ctx.moveTo(0,yv); else ctx.lineTo(k*gw,yv); }
                        ctx.strokeStyle=rgba(window.sapphire,0.55); ctx.lineWidth=1;
                        ctx.setLineDash([window.s(3),window.s(3)]); ctx.stroke(); ctx.setLineDash([]);
                        // --- hover crosshair + marker dot on the primary series ---
                        if (chart.hoverIdx >= 0 && chart.hoverIdx < n) {
                            var hx = chart.hoverIdx*gw;
                            ctx.strokeStyle = rgba(window.text, 0.30); ctx.lineWidth = 1;
                            ctx.beginPath(); ctx.moveTo(hx, 0); ctx.lineTo(hx, h-pad); ctx.stroke();
                            var hv = pv(b[chart.hoverIdx]);
                            var hy = h-pad-(h-2*pad)*Math.max(0,Math.min(1,hv/mx));
                            ctx.beginPath(); ctx.arc(hx, hy, window.s(3.2), 0, 2*Math.PI);
                            ctx.fillStyle = rgba(col,1.0); ctx.fill();
                            ctx.lineWidth = window.s(1.5); ctx.strokeStyle = rgba(window.crust,1.0); ctx.stroke();
                        }
                    }
                    // hover tracking (NoButton so clicks still pass through)
                    MouseArea {
                        anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton
                        onPositionChanged: {
                            var bb=(window.hist&&window.hist.buckets)?window.hist.buckets:[];
                            var nn=bb.length; if(nn<2){ chart.hoverIdx=-1; return; }
                            chart.hoverIdx = Math.max(0, Math.min(nn-1, Math.round(mouseX/(chart.width/(nn-1)))));
                        }
                        onExited: chart.hoverIdx = -1
                    }
                    // tooltip: exact time + value at the hovered bucket
                    Rectangle {
                        id: tip
                        readonly property int nn: (window.hist.buckets)?window.hist.buckets.length:0
                        readonly property var bkt: (chart.hoverIdx>=0 && nn>chart.hoverIdx)?window.hist.buckets[chart.hoverIdx]:null
                        visible: bkt !== null
                        readonly property real cx: (nn>1)?chart.hoverIdx*(chart.width/(nn-1)):0
                        width: tipCol.implicitWidth + window.s(16); height: tipCol.implicitHeight + window.s(10)
                        radius: window.s(8)
                        color: Qt.rgba(window.crust.r,window.crust.g,window.crust.b,0.97)
                        border.width: 1; border.color: Qt.rgba(window.peach.r,window.peach.g,window.peach.b,0.45)
                        x: Math.max(0, Math.min(chart.width-width, cx-width/2)); y: window.s(2)
                        Column {
                            id: tipCol; anchors.centerIn: parent; spacing: window.s(1)
                            Text { text: tip.bkt?tip.bkt.t:""; color: window.text
                                   font.family:"JetBrains Mono"; font.pixelSize: window.s(11); font.weight: Font.Bold }
                            Text { text: tip.bkt?(window.metric==="util"?((tip.bkt.util||0)+"% util")
                                                 :window.metric==="tokens"?((tip.bkt.tok_out||0)+" out · "+(tip.bkt.tok_in||0)+" in")
                                                 :((tip.bkt.reqs||0)+" req")):""
                                   color: window.metric==="tokens"?window.yellow:window.metric==="reqs"?window.green:window.peach
                                   font.family:"JetBrains Mono"; font.pixelSize: window.s(10) }
                            Text { text: tip.bkt?((tip.bkt.vram||0)+"GB vram"):""; color: window.sapphire
                                   font.family:"JetBrains Mono"; font.pixelSize: window.s(9) }
                        }
                    }
                }
                // chart legend (out / in-context / vram) + bucket granularity
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(6)
                    Rectangle{ width:window.s(11); height:window.s(2); radius:1; color:window.yellow }
                    Text { text:"out"; color:window.subtext1; font.family:"JetBrains Mono"; font.pixelSize:window.s(9) }
                    Rectangle{ width:window.s(11); height:window.s(2); radius:1; color:window.overlay0 }
                    Text { text:"in·ctx"; color:window.subtext1; font.family:"JetBrains Mono"; font.pixelSize:window.s(9) }
                    Rectangle{ width:window.s(11); height:window.s(2); radius:1; color:window.sapphire }
                    Text { text:"vram"; color:window.subtext1; font.family:"JetBrains Mono"; font.pixelSize:window.s(9) }
                    Item { Layout.fillWidth: true }
                    Text { text: (window.hist&&window.hist.bucket_min)?(window.hist.bucket_min+"m buckets"):""
                           color: window.subtext1; font.family:"JetBrains Mono"; font.pixelSize:window.s(9) }
                }

                // Grafana-style stat strip — honest utilization + cost basis.
                // OUT = real generation (completion). IN = re-fed context (what a
                // cloud API bills as input every agentic turn). CLOUD EQUIV = all
                // tokens priced at the counterfactual rate in `ai-history`; SAVED =
                // that minus what we actually paid (local backends are $0).
                Flow {
                    Layout.fillWidth: true; spacing: window.s(6)
                    Repeater {
                        model: {
                            var hh = window.hist || ({});
                            function ft(t){ t=t||0; return t>=1e6?(t/1e6).toFixed(2)+"M":t>=1000?(t/1000).toFixed(t>=1e4?0:1)+"k":(""+Math.round(t)); }
                            function usd(v){ v=v||0; return v>=1?"$"+v.toFixed(2):"$"+v.toFixed(3); }
                            return [
                                {l:"REQUESTS",    v:""+(hh.reqs||0),        c:window.text},
                                {l:"LOCAL",       v:(hh.local_share?(hh.local_share.pct||0).toFixed(1)+"%":"—"),
                                                  c:(hh.local_share&&hh.local_share.pct<80)?window.peach:window.teal},
                                {l:"TOKENS OUT",  v:ft(hh.tok_out),         c:window.yellow},
                                {l:"TOKENS IN",   v:ft(hh.tok_in),          c:window.overlay1},
                                {l:"TOK/S",       v:""+(hh.tok_per_sec||0),  c:window.peach},
                                {l:"AVG LAT",     v:(hh.avg_latency_ms?(hh.avg_latency_ms/1000).toFixed(1)+"s":"—"), c:window.subtext0},
                                {l:"CLOUD EQUIV", v:usd(hh.cost_cloud_usd),  c:window.red},
                                {l:"SAVED",       v:usd(hh.saved_usd),       c:window.green},
                            ];
                        }
                        delegate: Rectangle {
                            required property var modelData
                            implicitWidth: Math.max(window.s(62), scol.implicitWidth + window.s(16))
                            implicitHeight: scol.implicitHeight + window.s(12)
                            radius: window.s(10)
                            color: Qt.rgba(window.surface0.r,window.surface0.g,window.surface0.b,0.55)
                            Column {
                                id: scol; anchors.centerIn: parent; spacing: window.s(1)
                                Text { anchors.horizontalCenter: parent.horizontalCenter
                                       text: modelData.v; color: modelData.c
                                       font.family:"JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(15) }
                                Text { anchors.horizontalCenter: parent.horizontalCenter
                                       text: modelData.l; color: window.subtext1
                                       font.family:"JetBrains Mono"; font.pixelSize: window.s(8); font.letterSpacing: window.s(0.5) }
                            }
                        }
                    }
                }

                // ── LOCAL VS CLOUD — how much the local models actually carry,
                // and exactly where the misses went (escalations / hard-panel
                // losses / waterfall fallbacks). Data: ai-history .local_share.
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(6)
                    Text { text: "LOCAL VS CLOUD"; color: window.subtext1
                           font.family:"JetBrains Mono"; font.weight: Font.Bold
                           font.pixelSize: window.s(9); font.letterSpacing: window.s(1.5) }
                    Item { Layout.fillWidth: true }
                    Text {
                        property var ls: (window.hist && window.hist.local_share) ? window.hist.local_share : null
                        text: ls ? (ls.local + " local · " + ls.cloud + " cloud") : ""
                        color: window.overlay1; font.family:"JetBrains Mono"; font.pixelSize: window.s(8)
                    }
                }
                Rectangle {
                    Layout.fillWidth: true
                    implicitHeight: localCol.implicitHeight + window.s(16)
                    radius: window.s(10)
                    color: Qt.rgba(window.surface0.r,window.surface0.g,window.surface0.b,0.55)
                    ColumnLayout {
                        id: localCol
                        anchors.fill: parent; anchors.margins: window.s(8); spacing: window.s(5)
                        property var ls: (window.hist && window.hist.local_share) ? window.hist.local_share
                                         : ({local:0,cloud:0,pct:100,escalated:0,hard_cloud:0,requested:0,fallback:0,panels:({n:0,local:0,cloud:0,revised:0})})
                        RowLayout {
                            Layout.fillWidth: true; spacing: window.s(10)
                            Text { text: (localCol.ls.pct||0).toFixed(1)+"%"
                                   color: (localCol.ls.pct>=95)?window.green:(localCol.ls.pct>=80?window.yellow:window.peach)
                                   font.family:"JetBrains Mono"; font.weight:Font.Bold; font.pixelSize: window.s(17) }
                            Rectangle {                         // share bar: teal local / red cloud remainder
                                Layout.fillWidth: true; height: window.s(8); radius: height/2
                                color: Qt.rgba(window.red.r,window.red.g,window.red.b,0.30)
                                Rectangle {
                                    width: parent.width * Math.max(0, Math.min(1,(localCol.ls.pct||0)/100))
                                    height: parent.height; radius: height/2
                                    gradient: Gradient {
                                        orientation: Gradient.Horizontal
                                        GradientStop { position: 0.0; color: window.teal }
                                        GradientStop { position: 1.0; color: window.green }
                                    }
                                    Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                                }
                            }
                            Text { text: "on-box"; color: window.subtext1
                                   font.family:"JetBrains Mono"; font.pixelSize: window.s(9) }
                        }
                        Text {
                            Layout.fillWidth: true
                            text: {
                                var ls = localCol.ls;
                                var parts = ["misses: " + (ls.escalated||0) + " escalated · "
                                             + (ls.hard_cloud||0) + " hard-panel · "
                                             + (ls.fallback||0) + " fallback · "
                                             + (ls.requested||0) + " requested"];
                                var p = ls.panels || ({});
                                if (p.n) parts.push("panels: " + (p.local||0) + " local vs "
                                                    + (p.cloud||0) + " cloud · " + (p.revised||0) + " revised");
                                return parts.join("     ");
                            }
                            color: window.subtext0; font.family:"JetBrains Mono"; font.pixelSize: window.s(9)
                            elide: Text.ElideRight
                        }
                    }
                }

                // ── SUBSCRIPTION comparison — this window's API-equivalent cost
                // projected to 30 days, vs a flat $200/mo Claude Max 20× plan.
                // Most meaningful on the 30d view (real monthly rate); shorter
                // windows extrapolate the current pace × 30.
                RowLayout {
                    Layout.fillWidth: true; spacing: window.s(6)
                    Text { text: "SUBSCRIPTION"; color: window.subtext1
                           font.family:"JetBrains Mono"; font.weight: Font.Bold
                           font.pixelSize: window.s(9); font.letterSpacing: window.s(1.5) }
                    Item { Layout.fillWidth: true }
                    Text { text: (window.rangeH===720 ? "actual 30d" : "projected from "+window.rangeH+"h pace")
                           color: window.overlay1; font.family:"JetBrains Mono"; font.pixelSize: window.s(8) }
                }
                Flow {
                    Layout.fillWidth: true; spacing: window.s(6)
                    Repeater {
                        model: {
                            var hh = window.hist || ({});
                            function mo(v){ v=v||0; return v>=1000?"$"+(v/1000).toFixed(1)+"k":v>=10?"$"+v.toFixed(0):"$"+v.toFixed(2); }
                            var pct = hh.max20_token_pct||0;
                            var pctv = pct>=100 ? (pct/100).toFixed(1)+"×" : pct<10 ? pct.toFixed(1)+"%" : pct.toFixed(0)+"%";
                            return [
                                {l:"30D · SONNET", v:mo(hh.proj_30d_sonnet_usd), c:window.red},
                                {l:"30D · OPUS",   v:mo(hh.proj_30d_opus_usd),   c:window.mauve},
                                {l:"OF MAX 20× ·tok", v:pctv, c: pct>=100?window.red:window.green},
                            ];
                        }
                        delegate: Rectangle {
                            required property var modelData
                            implicitWidth: Math.max(window.s(62), subcol.implicitWidth + window.s(16))
                            implicitHeight: subcol.implicitHeight + window.s(12)
                            radius: window.s(10)
                            color: Qt.rgba(window.surface0.r,window.surface0.g,window.surface0.b,0.55)
                            Column {
                                id: subcol; anchors.centerIn: parent; spacing: window.s(1)
                                Text { anchors.horizontalCenter: parent.horizontalCenter
                                       text: modelData.v; color: modelData.c
                                       font.family:"JetBrains Mono"; font.weight: Font.Bold; font.pixelSize: window.s(15) }
                                Text { anchors.horizontalCenter: parent.horizontalCenter
                                       text: modelData.l; color: window.subtext1
                                       font.family:"JetBrains Mono"; font.pixelSize: window.s(8); font.letterSpacing: window.s(0.5) }
                            }
                        }
                    }
                }

                // per-backend split (local vs cloud) — drives the cost basis above
                Text {
                    Layout.fillWidth: true
                    visible: text.length > 0
                    text: {
                        var hh = window.hist || ({}); var bb = hh.by_backend || ({});
                        var keys = Object.keys(bb); if (!keys.length) return "";
                        function ft(t){ t=t||0; return t>=1e6?(t/1e6).toFixed(1)+"M":t>=1000?(t/1000).toFixed(0)+"k":(""+Math.round(t)); }
                        function obj(v){ return (typeof v==="number")?{reqs:v,tok_in:0,tok_out:0}:v; }
                        keys.sort(function(a,c){ return (obj(bb[c]).tok_in+obj(bb[c]).tok_out)-(obj(bb[a]).tok_in+obj(bb[a]).tok_out); });
                        var parts=[]; for (var i=0;i<keys.length;i++){ var k=keys[i]; var v=obj(bb[k]);
                            parts.push(k+" "+(v.reqs||0)+"r·"+ft(v.tok_out)+"o/"+ft(v.tok_in)+"i"); }
                        return "by backend:   " + parts.join("    ");
                    }
                    color: window.subtext0; font.family:"JetBrains Mono"; font.pixelSize: window.s(9)
                    elide: Text.ElideRight
                }

                // --------------------------------------------- Hermes hub + tiers
                Rectangle {
                    Layout.fillWidth: true
                    height: window.s(50); radius: window.s(14)
                    opacity: window.introCards
                    color: Qt.rgba(window.surface0.r, window.surface0.g, window.surface0.b, 0.5)
                    RowLayout {
                        anchors.fill: parent; anchors.margins: window.s(14); spacing: window.s(12)
                        Rectangle {
                            width: window.s(12); height: width; radius: width/2
                            color: window.hermesUp ? window.green : window.red
                            SequentialAnimation on opacity {
                                running: window.visible && window.hermesUp; loops: Animation.Infinite
                                NumberAnimation { from: 1.0; to: 0.4; duration: 1100; easing.type: Easing.InOutSine }
                                NumberAnimation { from: 0.4; to: 1.0; duration: 1100; easing.type: Easing.InOutSine }
                            }
                        }
                        Text {
                            text: "Hermes router"
                            font.family: "JetBrains Mono"; font.weight: Font.Bold
                            font.pixelSize: window.s(13); color: window.text
                        }
                        Text {
                            text: ":8788"
                            font.family: "JetBrains Mono"; font.pixelSize: window.s(11); color: window.subtext0
                        }
                        Item { Layout.fillWidth: true }
                        // cloud-tier reachability dots
                        Repeater {
                            model: [ { k: "local", l: "local" }, { k: "github", l: "github" }, { k: "duckai", l: "duck.ai" } ]
                            delegate: RowLayout {
                                required property var modelData
                                spacing: window.s(4)
                                Rectangle {
                                    width: window.s(8); height: width; radius: width / 2
                                    property var be: window.router ? window.router.backends : null
                                    color: (be && be[modelData.k] === true) ? window.green
                                           : (window.hermesUp ? window.red : window.subtext1)
                                }
                                Text {
                                    text: modelData.l
                                    font.family: "JetBrains Mono"; font.pixelSize: window.s(10); color: window.subtext0
                                }
                            }
                        }
                        Item { Layout.preferredWidth: window.s(4) }
                        Text {
                            text: window.hermesUp ? "ONLINE" : "OFFLINE"
                            font.family: "JetBrains Mono"; font.weight: Font.Bold
                            font.pixelSize: window.s(11); color: window.hermesUp ? window.green : window.red
                        }
                    }
                }

                // absorbs leftover height so the GPU cards keep their fixed size
                Item { Layout.fillHeight: true }
            }
        }
    }

    // section heading helper (inlined component — single-file popup)
    component SectionLabel : Text {
        Layout.fillWidth: true
        color: window.subtext1
        font.family: "JetBrains Mono"; font.weight: Font.Bold
        font.pixelSize: window.s(10); font.letterSpacing: window.s(2)
    }
}
