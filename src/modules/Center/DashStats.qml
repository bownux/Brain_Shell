import QtQuick
import Quickshell
import Quickshell.Io
import "../../"
import "../../components"
import "../../services/"

Item {
    id: root

    CpuService         { id: cpu;     active: root.visible }
    MemService         { id: mem;     active: root.visible }
    NetService         { id: net;     active: root.visible }
    ThermalService     { id: thermal; active: root.visible }
    FanControl         { id: fan }
    DiskService        { id: disk;    active: root.visible }

    // Rog GPU aggregate (ai-state): R9700 trio max-util + pooled VRAM, 3080 Ti
    Item {
        id: rogGpus
        property int amdUtil: 0
        property string amdVram: "—"
        property int nvUtil: 0
        property string nvVram: "—"
        Process {
            id: rogGpuProc; running: false
            command: ["bash", "-c", "/home/luis/ai/hermes-brains/bin/ai-state"]
            stdout: StdioCollector {
                onStreamFinished: {
                    try {
                        const gs = (JSON.parse(this.text).gpus || []);
                        let au = 0, aU = 0, aT = 0, nu = 0, nU = 0, nT = 0;
                        gs.forEach(g => {
                            if (!g) return;
                            if (g.kind === "nvidia") { nu = g.util || 0; nU = g.vram_used || 0; nT = g.vram_total || 0; }
                            else { au = Math.max(au, g.util || 0); aU += g.vram_used || 0; aT += g.vram_total || 0; }
                        });
                        rogGpus.amdUtil = au; rogGpus.nvUtil = nu;
                        rogGpus.amdVram = (aU/1024).toFixed(0) + " / " + (aT/1024).toFixed(0) + " GB";
                        rogGpus.nvVram  = (nU/1024).toFixed(1) + " / " + (nT/1024).toFixed(0) + " GB";
                    } catch (e) {}
                }
            }
        }
        Timer { interval: 4000; repeat: true; running: root.visible; triggeredOnStart: true
                onTriggered: { rogGpuProc.running = false; rogGpuProc.running = true } }
    }
    EnvyControlService { id: envy }
    CpuFreqService     { id: cpuFreq }
    GpuService {
        id:       gpu
        active:   root.visible
        envyMode: envy.currentMode
    }

    Column {
        anchors {
            fill:          parent
            bottomMargin:  8
            topMargin:     8
        }
        spacing: 8

        // Speedometers
        Row {
            id:      speedoRow
            width:   parent.width
            anchors.topMargin: 4
            height:  160
            spacing: 8

            StatCard {
                width:  (parent.width - parent.spacing * 3) / 4
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label:       "CPU"
                    percent:     cpu.usagePercent
                    centerText:  cpu.usagePercent + "%"
                    bottomText:  cpuFreq.curFreqStr
                    active:      true
                    accentColor: Theme.active
                }
            }

            StatCard {
                width:  (parent.width - parent.spacing * 3) / 4
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label:       "RAM"
                    percent:     mem.usagePercent
                    centerText:  mem.usagePercent + "%"
                    bottomText:  mem.usedStr + " / " + mem.totalStr
                    active:      true
                    accentColor: "#cba6f7"
                }
            }

            // iGPU/dGPU rings replaced — no iGPU on the Threadripper; this rig
            // runs 3x R9700 (AI) + a 3080 Ti (display/vision). Data: ai-state.
            StatCard {
                width:  (parent.width - parent.spacing * 3) / 4
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label:       "R9700 ×3"
                    percent:     rogGpus.amdUtil
                    centerText:  rogGpus.amdUtil + "%"
                    bottomText:  rogGpus.amdVram
                    active:      true
                    accentColor: "#89dceb"
                }
            }

            StatCard {
                width:  (parent.width - parent.spacing * 3) / 4
                height: parent.height
                Speedometer {
                    anchors.centerIn: parent
                    label:       "3080 Ti"
                    percent:     rogGpus.nvUtil
                    centerText:  rogGpus.nvUtil + "%"
                    bottomText:  rogGpus.nvVram
                    active:      true
                    accentColor: "#a6e3a1"
                }
            }
        }
        
        Row{
            width:   parent.width
            height:  100
            spacing: 8
            // Thermal strip
            StatCard {
                width:   (parent.width-parent.spacing)/2
                height:  parent.height
                padding: 6
    
                TempPanel {
                    anchors.fill: parent
                    service:      thermal
                    dgpuActive:   gpu.dgpu.active
                }
            }
            
            // Fan control strip
            StatCard {
                width:   (parent.width-parent.spacing)/2
                height:  parent.height
                padding: 6
                
                FanPanel {
                    anchors.fill: parent
                    service:      fan
                }
            }
        }
        // Net | Disk | Power
        Row {
            width:   parent.width
            height:  parent.height - speedoRow.height - 100 - parent.spacing 
            spacing: 8

            // Network — narrow, only 3 rows
            StatCard {
                width:  Math.round(parent.width * 0.20)
                height: parent.height
                NetStatsPanel {
                    anchors.fill: parent
                    service:      net
                }
            }

            // Disks — moderate, horizontal bars stack vertically
            StatCard {
                width:  Math.round(parent.width * 0.35)
                height: parent.height
                DiskPanel {
                    anchors.fill: parent
                    service:      disk
                }
            }

            // Power — widest, two button rows need space
            StatCard {
                width:  parent.width - Math.round(parent.width * 0.20) - Math.round(parent.width * 0.35) - parent.spacing * 2
                height: parent.height
                // PowerPanel (laptop power-profiles/envycontrol) replaced —
                // this tower is pinned to EPP=performance at the OS level.
                RogGpuPanel {
                    anchors.fill:   parent
                }
            }
        }
    }
}
