import QtQuick
import QtQuick.Effects
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "../"

// =============================================================================
//  VoiceOrb — Apple-Intelligence / Siri-style voice indicator for Hermes.
// -----------------------------------------------------------------------------
//  Reads the voice-loop contract written atomically by:
//      ~/ai/hermes-brains/bin/voice-state <state> [level] [text]
//  to ~/.hermes/voice/state.json :
//      {"state":"idle|listening|thinking|speaking|error","level":0..1,"text":""}
//
//  A click-through Wayland OVERLAY (one per screen) that fades in when the
//  state is non-idle and renders a glowing, morphing gradient orb whose palette
//  + motion encode the state, and whose pulse / spectrum-ring react live to
//  `level` (mic RMS while listening, TTS RMS while speaking).
//
//  PERFORMANCE: a single shared poller lives in this Scope; the heavy Canvas
//  animation is gated on (window.visible && root.active) so it does ZERO work
//  while idle (see MEMORY: quickshell iGPU repaint — gate infinite anims on
//  visibility, never leave them running hidden).
// =============================================================================
Scope {
    id: root

    // ----- shared theme + scaling (one instance, shared by every screen) -----
    MatugenColors { id: theme }
    Scaler { id: scaler; currentWidth: Screen.width; currentHeight: Screen.height }
    function s(v) { return scaler.s(v); }

    // ----- live voice state ---------------------------------------------------
    property string vState: "idle"
    property string vText:  ""
    property real   vLevel: 0          // smoothed RMS amplitude (0..1)
    property real   vProgress: -1      // 0..1 fraction of TTS played (-1 = N/A)
    property bool   vPaused: false     // playback paused by the user (orb click)
    Behavior on vLevel { NumberAnimation { duration: 110; easing.type: Easing.OutCubic } }

    readonly property bool active: vState !== "idle"

    // ----- teleprompter model (read-along highlight while speaking) -----------
    //  Split the reply into words; `teleSpoken` is how many have been voiced so
    //  far (changes only at word boundaries, so the rich-text rebuild is cheap —
    //  the continuous scroll uses vProgress directly). useTeleprompter gates the
    //  scrolling/highlighted view vs the plain caption (transcripts/status).
    readonly property bool useTeleprompter: vState === "speaking" && vProgress >= 0
    property var teleWords: vText ? vText.split(/\s+/).filter(function (w) { return w.length > 0; }) : []
    readonly property int  teleSpoken: useTeleprompter ? Math.round(vProgress * teleWords.length) : -1

    function _rgbaStr(c, a) {
        return "rgba(" + Math.round(c.r * 255) + "," + Math.round(c.g * 255) +
               "," + Math.round(c.b * 255) + "," + a + ")";
    }
    // build the highlighted reply: already-spoken bright, current word accented,
    // upcoming dim. Depends on teleWords + teleSpoken only (NOT vProgress) so it
    // re-renders a few times/sec, not every animation frame.
    function teleHtml() {
        var ws = teleWords, n = ws.length;
        if (!n) return "";
        var spoken = teleSpoken;
        var bright = _rgbaStr(theme.text, 1.0);
        var dim    = _rgbaStr(theme.text, 0.32);
        var cur    = _rgbaStr(pri, 1.0);
        var out = "";
        for (var i = 0; i < n; i++) {
            var col = (i < spoken - 1) ? bright : (i === spoken - 1) ? cur : dim;
            var weight = (i === spoken - 1) ? "700" : "400";
            var w = ws[i].replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
            out += "<span style='color:" + col + "; font-weight:" + weight + ";'>" + w + "</span> ";
        }
        return out;
    }

    // ----- control channel back to the voice loop (pause/resume/cancel) -------
    Process { id: ctlProc; running: false }
    function ctl(cmd) {
        ctlProc.running = false;
        ctlProc.command = ["bash", "-lc", "exec ~/ai/hermes-brains/bin/voice-ctl " + cmd];
        ctlProc.running = true;
    }
    // a single click means different things per state: while LISTENING it ends
    // capture and processes ("done"); while SPEAKING it pauses/resumes ("toggle").
    function singleClick() { ctl(vState === "listening" ? "done" : "toggle"); }

    // appear drives the fade/scale in-out; window stays mapped until it settles
    property real appear: 0
    Behavior on appear { NumberAnimation { duration: 300; easing.type: Easing.OutCubic } }
    onActiveChanged: appear = active ? 1 : 0

    // ----- per-state palette (animated transitions between states) -----------
    //  The cool-vs-warm hue IS the signal ("am I listening to you" vs "I'm
    //  talking to you"), so the orb accents use FIXED canonical Catppuccin hues
    //  rather than the live wallpaper-derived Matugen palette (which on some
    //  themes collapses every accent to one warm tone and would erase the
    //  distinction). Chrome (caption pill / text) still follows the live theme.
    readonly property color cBlue:     "#89b4fa"
    readonly property color cSapphire: "#74c7ec"
    readonly property color cTeal:     "#94e2d5"
    readonly property color cPeach:    "#fab387"
    readonly property color cPink:     "#f5c2e7"
    readonly property color cMauve:    "#cba6f7"
    readonly property color cRed:      "#f38ba8"
    readonly property color cMaroon:   "#eba0ac"
    readonly property color cYellow:   "#f9e2af"

    function priFor(st) {
        switch (st) {
            case "listening": return cSapphire;
            case "speaking":  return cPeach;
            case "thinking":  return cMauve;
            case "error":     return cRed;
            default:          return cBlue;
        }
    }
    function secFor(st) {
        switch (st) {
            case "listening": return cBlue;
            case "speaking":  return cPink;
            case "thinking":  return cSapphire;
            case "error":     return cMaroon;
            default:          return cSapphire;
        }
    }
    function accFor(st) {
        switch (st) {
            case "listening": return cTeal;
            case "speaking":  return cYellow;
            case "thinking":  return cTeal;
            case "error":     return cPeach;
            default:          return cTeal;
        }
    }
    property color pri: priFor(vState)
    property color sec: secFor(vState)
    property color acc: accFor(vState)
    Behavior on pri { ColorAnimation { duration: 450 } }
    Behavior on sec { ColorAnimation { duration: 450 } }
    Behavior on acc { ColorAnimation { duration: 450 } }

    function label(st) {
        switch (st) {
            case "listening": return "Listening";
            case "speaking":  return "Speaking";
            case "thinking":  return "Thinking";
            case "error":     return "Error";
            default:          return "";
        }
    }

    // ----- SINGLE shared poller ----------------------------------------------
    //  cat is cheap; poll fast (≈70ms) while active so `level` animates
    //  smoothly, and slowly (≈350ms) while idle just to notice activation.
    Process {
        id: reader
        running: false
        command: ["bash", "-lc", "cat ~/.hermes/voice/state.json 2>/dev/null"]
        stdout: StdioCollector {
            onStreamFinished: {
                let txt = this.text ? this.text.trim() : "";
                if (!txt) return;
                try {
                    let d = JSON.parse(txt);
                    let st = d.state || "idle";
                    // Staleness guard: if the writer dies (SIGKILL/logout) the orb must
                    // not hang. listening/speaking stream level updates ~15Hz, so a 5s
                    // gap = dead writer. thinking can be quiet for a whole LLM turn, so
                    // give it a generous ceiling (an answer won't exceed ~3min).
                    let now = Date.now() / 1000;
                    let maxAge = (st === "thinking") ? 180.0 : 5.0;
                    if (st !== "idle" && typeof d.ts === "number" && (now - d.ts) > maxAge)
                        st = "idle";
                    root.vState = st;
                    root.vText  = (st === "idle") ? "" :
                                  ((d.text !== undefined && d.text !== null) ? String(d.text) : "");
                    let lv = (typeof d.level === "number") ? d.level : 0;
                    root.vLevel = Math.max(0, Math.min(1, lv));
                    root.vProgress = (typeof d.progress === "number") ? d.progress : -1;
                    root.vPaused = (st === "speaking") && (d.paused === true);
                } catch (e) { /* keep last good state */ }
            }
        }
    }
    Timer {
        interval: root.active ? 70 : 350
        repeat: true; running: true; triggeredOnStart: true
        onTriggered: { reader.running = false; reader.running = true; }
    }

    // =========================================================================
    //  One overlay window per screen
    // =========================================================================
    Variants {
        model: Quickshell.screens

        delegate: Component {
            PanelWindow {
                id: win
                required property var modelData
                screen: modelData

                WlrLayershell.namespace: "qs-voice-orb"
                WlrLayershell.layer: WlrLayer.Overlay
                exclusionMode: ExclusionMode.Ignore
                focusable: false
                color: "transparent"

                // bottom-centre, floating above the dock area
                anchors { bottom: true }
                margins.bottom: root.s(70)
                implicitWidth:  root.s(360)
                // grow upward to make room for the teleprompter window while
                // speaking (anchored to the bottom, so it expands away from the dock)
                implicitHeight: root.useTeleprompter ? root.s(450) : root.s(300)

                // keep mapped through the fade-out, do nothing while idle
                visible: root.active || root.appear > 0.01

                // Input region = JUST the orb, so a click there reaches the
                // MouseArea (pause/cancel) while the label + teleprompter card
                // stay fully click-through. Never grabs keyboard focus.
                mask: Region { item: orbHit }

                // -------------------------------------------------- content
                Item {
                    id: content
                    anchors.fill: parent
                    opacity: root.appear
                    scale: 0.82 + 0.18 * root.appear
                    transformOrigin: Item.Center

                    Column {
                        anchors.centerIn: parent
                        spacing: root.s(4)

                        // state label — wears a soft, state-matched glow halo
                        Text {
                            anchors.horizontalCenter: parent.horizontalCenter
                            text: root.vPaused ? "PAUSED" : root.label(root.vState).toUpperCase()
                            font.family: "JetBrains Mono"; font.weight: Font.Bold
                            font.pixelSize: root.s(11); font.letterSpacing: root.s(3)
                            color: root.pri
                            opacity: 0.9
                            Behavior on color { ColorAnimation { duration: 450 } }
                            layer.enabled: true
                            layer.effect: MultiEffect {
                                shadowEnabled: true
                                shadowColor: Qt.rgba(root.pri.r, root.pri.g, root.pri.b, 0.55)
                                shadowBlur: 0.85
                                shadowVerticalOffset: 0
                                blurMax: 18
                            }
                        }

                        // the orb — "Aurora glass": a GPU fragment shader renders a
                        // 3D glass sphere (analytic normals) holding a domain-warped
                        // nebula core, a fresnel/iridescent rim, dual speculars and a
                        // reactive waveform halo ring. All motion + palette uniforms
                        // crossfade per state; audio level lights the core live.
                        // (Canvas 2D orb retired 2026-06-09 — see orb.frag / orb.frag.qsb, v2 tonemapped.)
                        Item {
                            id: orb
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: root.s(264); height: root.s(264)

                            // master clock — real seconds, FROZEN while paused so the
                            // orb visibly holds still. Gated on visibility so it does
                            // ZERO work while idle (see MEMORY: gate infinite anims).
                            FrameAnimation {
                                running: win.visible && root.active && !root.vPaused
                                onTriggered: shader.uTime = elapsedTime
                            }

                            ShaderEffect {
                                id: shader
                                anchors.fill: parent
                                visible: status !== ShaderEffect.Error
                                fragmentShader: Qt.resolvedUrl("orb.frag.qsb")

                                property real uTime: 0
                                property real uLevel: root.vLevel
                                // per-state motion grammar (same language the Canvas spoke:
                                // thinking spins fast, speaking breathes big, error strobes)
                                property real uEnv: root.vState === "thinking" ? 0.45
                                                  : root.vState === "error"    ? 0.75
                                                  : 0.12 + 0.88 * root.vLevel
                                property real uSpin:   root.vState === "thinking"  ? 2.1
                                                     : root.vState === "speaking"  ? 1.25
                                                     : root.vState === "listening" ? 0.7 : 0.55
                                property real uBreath: root.vState === "speaking"  ? 0.040
                                                     : root.vState === "listening" ? 0.030
                                                     : root.vState === "error"     ? 0.0 : 0.025
                                property real uGlow:   root.vState === "speaking"  ? 1.0
                                                     : root.vState === "error"     ? 1.1 : 0.8
                                property real uThink: root.vState === "thinking" ? 1 : 0
                                property real uErr:   root.vState === "error"    ? 1 : 0
                                property real uSpeak: root.vState === "speaking" ? 1 : 0
                                property color uPri: root.pri
                                property color uSec: root.sec
                                property color uAcc: root.acc
                                // states crossfade rather than snap
                                Behavior on uEnv    { NumberAnimation { duration: 300 } }
                                Behavior on uSpin   { NumberAnimation { duration: 600 } }
                                Behavior on uBreath { NumberAnimation { duration: 600 } }
                                Behavior on uGlow   { NumberAnimation { duration: 450 } }
                                Behavior on uThink  { NumberAnimation { duration: 450 } }
                                Behavior on uSpeak  { NumberAnimation { duration: 450 } }
                                Behavior on uErr    { NumberAnimation { duration: 250 } }
                            }

                            // fallback if the shader ever fails to load — a simple
                            // gradient disc so the orb is never invisible
                            Rectangle {
                                visible: shader.status === ShaderEffect.Error
                                anchors.centerIn: parent
                                width: parent.width * 0.56; height: width; radius: width / 2
                                gradient: Gradient {
                                    GradientStop { position: 0.0; color: root.pri }
                                    GradientStop { position: 1.0; color: root.sec }
                                }
                                opacity: 0.9
                            }

                            // PAUSED: dim veil + ❚❚ glyph (the shader clock is frozen)
                            Rectangle {
                                visible: root.vPaused
                                anchors.centerIn: parent
                                width: parent.width * 0.56; height: width; radius: width / 2
                                color: Qt.rgba(0, 0, 0, 0.30)
                                Row {
                                    anchors.centerIn: parent
                                    spacing: root.s(10)
                                    Repeater {
                                        model: 2
                                        Rectangle {
                                            width: root.s(11); height: root.s(36)
                                            radius: root.s(3)
                                            color: Qt.rgba(1, 1, 1, 0.94)
                                        }
                                    }
                                }
                            }

                            // ----- click target: single = pause/resume (speaking) or
                            //       done (listening); hold or double-click = cancel ----
                            MouseArea {
                                id: orbHit
                                anchors.fill: parent
                                hoverEnabled: true
                                cursorShape: Qt.PointingHandCursor
                                acceptedButtons: Qt.LeftButton
                                onClicked:      clickGap.restart()
                                onDoubleClicked: { clickGap.stop(); root.ctl("cancel"); }
                                onPressAndHold:  { clickGap.stop(); root.ctl("cancel"); }
                            }
                            // a lone click only fires once we know it wasn't the
                            // first half of a double-click (listening=done, speaking=pause)
                            Timer { id: clickGap; interval: 250; onTriggered: root.singleClick(); }
                        }

                        // caption / teleprompter card. For transcripts + status it's
                        // a compact centred pill; while SPEAKING it becomes a fixed
                        // teleprompter window — the full reply scrolls past in sync
                        // with the voice, already-spoken words bright, the current
                        // word accented, upcoming words dimmed, with a progress rail.
                        Item {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: capPill.width; height: capPill.height
                            opacity: root.vText !== "" ? 1.0 : 0.0
                            Behavior on opacity { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }

                            Rectangle {
                                id: capPill
                                // teleprompter is a wide fixed window; caption hugs its text
                                width: root.useTeleprompter
                                       ? root.s(348)
                                       : Math.min(root.s(340), capText.implicitWidth + root.s(30))
                                height: tpCol.implicitHeight + root.s(16)
                                radius: root.s(15)
                                color: Qt.rgba(theme.crust.r, theme.crust.g, theme.crust.b, 0.82)
                                border.width: 1
                                border.color: Qt.rgba(root.pri.r, root.pri.g, root.pri.b,
                                                      0.35 + 0.40 * root.vLevel)
                                Behavior on width  { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                                Behavior on height { NumberAnimation { duration: 240; easing.type: Easing.OutCubic } }
                                Behavior on border.color { ColorAnimation { duration: 200 } }
                                layer.enabled: true
                                layer.effect: MultiEffect {
                                    shadowEnabled: true
                                    shadowColor: Qt.rgba(0, 0, 0, 0.45)
                                    shadowBlur: 0.6
                                    shadowVerticalOffset: root.s(3)
                                    blurMax: 24
                                }

                                Column {
                                    id: tpCol
                                    anchors.centerIn: parent
                                    width: parent.width - root.s(20)
                                    spacing: root.s(7)

                                    // ---- compact caption (transcript / status) ----
                                    Text {
                                        id: capText
                                        visible: !root.useTeleprompter
                                        width: parent.width
                                        horizontalAlignment: Text.AlignHCenter
                                        wrapMode: Text.Wrap
                                        elide: Text.ElideRight
                                        maximumLineCount: 2
                                        lineHeight: 1.12
                                        text: root.vText
                                        font.family: "JetBrains Mono"; font.pixelSize: root.s(12)
                                        font.weight: Font.Medium; font.letterSpacing: root.s(0.2)
                                        color: theme.text
                                    }

                                    // ---- teleprompter viewport (clipped, scrolls) --
                                    Item {
                                        id: tpBox
                                        visible: root.useTeleprompter
                                        width: parent.width
                                        // up to ~4 lines tall; shrink to fit short replies
                                        height: root.useTeleprompter
                                                ? Math.min(root.s(104), tpText.paintedHeight + root.s(2))
                                                : 0
                                        clip: true
                                        Behavior on height { NumberAnimation { duration: 200; easing.type: Easing.OutCubic } }

                                        Text {
                                            id: tpText
                                            width: parent.width
                                            textFormat: Text.RichText
                                            wrapMode: Text.Wrap
                                            lineHeight: 1.3
                                            text: root.useTeleprompter ? root.teleHtml() : ""
                                            font.family: "JetBrains Mono"; font.pixelSize: root.s(13)
                                            font.weight: Font.Medium
                                            color: theme.text
                                            // proportional scroll keeps the spoken edge in view
                                            y: root.useTeleprompter
                                               ? -Math.max(0, Math.max(0, Math.min(1, root.vProgress)) *
                                                            Math.max(0, paintedHeight - tpBox.height))
                                               : 0
                                            Behavior on y { NumberAnimation { duration: 180; easing.type: Easing.OutCubic } }
                                        }
                                    }

                                    // ---- progress rail (speaking only) ------------
                                    Rectangle {
                                        visible: root.useTeleprompter
                                        width: parent.width; height: root.s(3); radius: height / 2
                                        color: Qt.rgba(root.pri.r, root.pri.g, root.pri.b, 0.18)
                                        Rectangle {
                                            width: parent.width * Math.max(0, Math.min(1, root.vProgress))
                                            height: parent.height; radius: height / 2
                                            color: root.pri
                                            Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
