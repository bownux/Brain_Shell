import QtQuick
import Quickshell
import Quickshell.Io
import "../../"

// ============================================================
// RogStorage — fills "Data & Storage Coming Soon!" with this
// box's actual storage story: btrfs root + home usage, the
// model weights, embedded databases, journal — the things that
// actually grow on RogGentoo.
// ============================================================
Item {
    id: root

    property var fs: []          // [{name, used, total, pct}]
    property string modelsSize: "—"
    property string pgSize: "—"
    property string journalSize: "—"
    property string snapsSize: "—"

    Process {
        id: poller; running: false
        command: ["bash", "-c",
            "df -B1 --output=target,used,size / /home 2>/dev/null | tail -n+2 | sort -u; " +
            "echo '---'; du -sb ~/ai/models 2>/dev/null | cut -f1; " +
            "du -sb ~/.pg0 2>/dev/null | cut -f1; " +
            "journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[GM]'; " +
            "sudo -n btrfs filesystem du -s --raw /.snapshots 2>/dev/null | tail -1 | awk '{print $1}' || echo 0"]
        stdout: StdioCollector {
            onStreamFinished: {
                function human(b) {
                    b = Number(b)
                    if (!b || isNaN(b)) return "—"
                    if (b > 1e12) return (b/1e12).toFixed(2) + " TB"
                    if (b > 1e9)  return (b/1e9).toFixed(1) + " GB"
                    return (b/1e6).toFixed(0) + " MB"
                }
                var parts = (this.text || "").split("---")
                var rows = []
                parts[0].trim().split("\n").forEach(function(l) {
                    var c = l.trim().split(/\s+/)
                    if (c.length >= 3 && Number(c[2]) > 0)
                        rows.push({ name: c[0], used: human(c[1]), total: human(c[2]),
                                    pct: Math.round(Number(c[1]) / Number(c[2]) * 100) })
                })
                root.fs = rows
                var rest = (parts[1] || "").trim().split("\n")
                root.modelsSize  = human(rest[0])
                root.pgSize      = human(rest[1])
                root.journalSize = rest[2] || "—"
            }
        }
    }
    Timer { interval: 30000; repeat: true; running: root.visible; triggeredOnStart: true
            onTriggered: { poller.running = false; poller.running = true } }

    Column {
        anchors { top: parent.top; left: parent.left; right: parent.right; margins: 16 }
        spacing: 12

        Text { text: "FILESYSTEMS (btrfs, zstd)"; font.pixelSize: 10; font.weight: Font.Bold
               font.letterSpacing: 1.5; color: Qt.rgba(1,1,1,0.4) }

        Repeater {
            model: root.fs
            delegate: Column {
                required property var modelData
                width: parent.width; spacing: 4
                Row {
                    width: parent.width
                    Text { text: modelData.name; font.family: "JetBrains Mono"; font.pixelSize: 11
                           color: Theme.text; width: parent.width * 0.3 }
                    Text { text: modelData.used + " / " + modelData.total + "   (" + modelData.pct + "%)"
                           font.family: "JetBrains Mono"; font.pixelSize: 11; color: Theme.subtext }
                }
                Rectangle {
                    width: parent.width; height: 6; radius: 3
                    color: Qt.rgba(1,1,1,0.07)
                    Rectangle {
                        width: parent.width * Math.min(1, modelData.pct / 100)
                        height: parent.height; radius: 3
                        color: modelData.pct > 88 ? "#f38ba8" : (modelData.pct > 70 ? "#fab387" : Theme.active)
                    }
                }
            }
        }

        Text { text: "BIG CONSUMERS"; font.pixelSize: 10; font.weight: Font.Bold
               font.letterSpacing: 1.5; color: Qt.rgba(1,1,1,0.4) }

        Column {
            spacing: 6
            Repeater {
                model: [
                    { k: "󰚩  Model weights (~/ai/models)", v: root.modelsSize },
                    { k: "󰆼  Hindsight pg (~/.pg0)",        v: root.pgSize },
                    { k: "󰌱  systemd journal",              v: root.journalSize },
                ]
                delegate: Row {
                    required property var modelData
                    spacing: 10
                    Text { text: modelData.k; font.family: "JetBrains Mono"; font.pixelSize: 11
                           color: Theme.text; width: 280; elide: Text.ElideRight }
                    Text { text: modelData.v; font.family: "JetBrains Mono"; font.pixelSize: 11
                           font.weight: Font.Bold; color: Theme.active }
                }
            }
        }

        Text {
            width: parent.width; wrapMode: Text.Wrap
            font.pixelSize: 10; color: Theme.subtext
            text: "Models are syncthing-ignored (machine-local). fstrim.timer handles SSD trim weekly."
        }
    }
}
