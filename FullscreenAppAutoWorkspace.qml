// Fullscreen App Auto Workspace service: loads gamelayer.lua into Hyprland with `hyprctl eval`,
// re-loads it when Hyprland reloads its config, and removes it again when the
// plugin is disabled. IPC: omarchy-shell fullscreen-app-auto-workspace toggle | reload

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland

Scope {
  id: root

  // Host injection (unused, declared so the shell can set them)
  property var omarchyPath
  property var shell
  property var manifest

  readonly property string luaFile: Qt.resolvedUrl("gamelayer.lua").toString().replace(/^file:\/\//, "")
  property var extraClasses: []
  property var neverFullscreen: []
  property int sweepIntervalMs: 1500

  function luaString(s) {
    return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/[\r\n]/g, " ") + '"'
  }
  function luaList(list) {
    return "{" + (Array.isArray(list) ? list.map(luaString).join(",") : "") + "}"
  }

  function evalLua(code) {
    Quickshell.execDetached(["hyprctl", "eval", code])
  }

  function load() {
    loader.command = ["hyprctl", "eval", "local m = dofile(" + luaString(luaFile) + "); m.start({ extra_classes = "
            + luaList(extraClasses) + ", never_fullscreen = " + luaList(neverFullscreen)
            + ", sweep_interval_ms = " + sweepIntervalMs + " })"]
    loader.running = false
    loader.running = true
  }

  // hyprctl eval exits non-zero on a Lua error; a missing hyprctl or a Hyprland without Lua support ends up here too.
  Process {
    id: loader
    stdout: StdioCollector { id: loaderOut }
    stderr: StdioCollector { id: loaderErr }
    onExited: (code) => {
      if (code !== 0)
        console.warn("fullscreen-app-auto-workspace: could not load gamelayer.lua into Hyprland (exit " + code + "). "
                     + "Needs hyprctl and a Hyprland with Lua config support. " + (loaderErr.text || loaderOut.text).trim())
    }
  }

  // Optional settings: ~/.config/fullscreen-app-auto-workspace/config.json
  //   { "extraClasses": ["^my-game$"], "neverFullscreen": ["^my-launcher\\.exe$"], "sweepIntervalMs": 1500 }
  FileView {
    id: configFile
    path: Quickshell.env("HOME") + "/.config/fullscreen-app-auto-workspace/config.json"
    watchChanges: true
    onFileChanged: reload()
    onLoaded: {
      try {
        const c = JSON.parse(text())
        root.extraClasses = Array.isArray(c.extraClasses) ? c.extraClasses : []
        root.neverFullscreen = Array.isArray(c.neverFullscreen) ? c.neverFullscreen : []
        const ms = Number(c.sweepIntervalMs)
        root.sweepIntervalMs = isFinite(ms) && ms > 0 ? Math.min(10000, Math.max(500, Math.round(ms))) : 1500
      } catch (e) {
        root.extraClasses = []
        root.neverFullscreen = []
        root.sweepIntervalMs = 1500
      }
      root.load()
    }
    onLoadFailed: { root.extraClasses = []; root.neverFullscreen = []; root.sweepIntervalMs = 1500; root.load() }
  }

  IpcHandler {
    target: "fullscreen-app-auto-workspace"
    function toggle(): string {
      root.evalLua("if __game_layer then __game_layer.toggle() end")
      return "ok"
    }
    function reload(): string { configFile.reload(); return "ok" }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") root.load()
    }
  }

  Component.onDestruction: {
    Quickshell.execDetached(["hyprctl", "eval", "if __game_layer then __game_layer.stop(); __game_layer = nil end"])
  }
}
