// Fullscreen App Auto Workspace service: loads gamelayer.lua into Hyprland with `hyprctl eval`,
// re-loads it when Hyprland reloads its config, and removes it again when the
// plugin is disabled. IPC: omarchy-shell fullscreen-app-auto-workspace toggle | reload

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import Quickshell.Services.Pipewire

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
  // -1 leaves Hyprland's special workspace animation alone; 0 turns it off.
  property int animationInMs: -1
  property int animationOutMs: -1
  property bool muteOnHide: false
  property int muteFadeMs: 300
  property bool keepOthers: false

  property string layer: "fullscreen"
  readonly property string layerWs: "special:" + layer
  property var config: ({})

  function luaString(s) {
    return '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"').replace(/[\r\n]/g, " ") + '"'
  }
  function luaList(list) {
    return "{" + (Array.isArray(list) ? list.map(luaString).join(",") : "") + "}"
  }

  function evalLua(code) {
    Quickshell.execDetached(["hyprctl", "eval", code])
  }

  function clampInt(v, lo, hi, fallback) {
    const n = Number(v)
    return v !== null && v !== undefined && v !== "" && isFinite(n) ? Math.min(hi, Math.max(lo, Math.round(n))) : fallback
  }

  function applyConfig(c) {
    extraClasses = Array.isArray(c.extraClasses) ? c.extraClasses : []
    neverFullscreen = Array.isArray(c.neverFullscreen) ? c.neverFullscreen : []
    sweepIntervalMs = clampInt(c.sweepIntervalMs, 500, 10000, 1500)
    animationInMs = clampInt(c.animationInMs, 0, 5000, -1)
    animationOutMs = clampInt(c.animationOutMs, 0, 5000, -1)
    muteOnHide = c.muteOnHide === true
    muteFadeMs = clampInt(c.muteFadeMs, 0, 5000, 300)
    keepOthers = c.keepOthers === true
    layer = typeof c.layer === "string" && /^[a-z0-9_-]{1,24}$/.test(c.layer) ? c.layer : "fullscreen"
    if (!muteOnHide) restoreAudio(false)
    load()
  }

  // ---- Animation length for showing (In) and hiding (Out) the layer ----
  // Hyprland has no way to unset an animation leaf, so the values it had before are
  // remembered and written back when the setting is removed or the plugin stops.
  property var animOriginals: ({})

  function luaCall(leaf, enabled, speed, bezier, style) {
    return "set_anim(" + luaString(leaf) + "," + (enabled ? "true" : "false") + "," + Number(speed) + ","
           + luaString(bezier) + "," + luaString(style) + ")"
  }

  readonly property string animPrelude: "local function set_anim(leaf, enabled, speed, bezier, style) "
    + "local spec = { leaf = leaf, enabled = enabled, speed = speed, bezier = bezier } "
    + "if style ~= '' then spec.style = style end "
    + "if not pcall(hl.animation, spec) then spec.bezier = 'default'; pcall(hl.animation, spec) end end "

  // First explicitly set value up the chain specialWorkspace > workspaces > global.
  function inherited(byName, key) {
    for (const name of ["specialWorkspace", "workspaces", "global"]) {
      const rec = byName[name]
      if (rec && rec.overridden && rec[key] !== "" && rec[key] !== undefined) return rec[key]
    }
    return undefined
  }

  function applyAnimations(records) {
    // `hyprctl -j animations` returns [animations, beziers].
    const byName = {}
    for (const r of (Array.isArray(records[0]) ? records[0] : records)) byName[r.name] = r
    const bezier = inherited(byName, "bezier") || "default"
    const style = inherited(byName, "style") || ""
    const speed = inherited(byName, "speed") || 1
    const enabled = inherited(byName, "enabled") !== false

    let code = ""
    for (const [leaf, ms] of [["specialWorkspaceIn", animationInMs], ["specialWorkspaceOut", animationOutMs]]) {
      if (ms < 0) continue
      if (!animOriginals[leaf]) {
        const cur = byName[leaf]
        animOriginals[leaf] = cur && cur.overridden
          ? luaCall(leaf, cur.enabled, cur.speed, cur.bezier || bezier, cur.style)
          : luaCall(leaf, enabled, speed, bezier, style)
      }
      code += luaCall(leaf, ms > 0, ms > 0 ? ms / 100 : 1, bezier, style) + "; "
    }
    if (code !== "") evalLua(animPrelude + code)
  }

  function restoreAnimations(onlyUnconfigured) {
    let code = ""
    for (const leaf in animOriginals) {
      const configured = leaf === "specialWorkspaceIn" ? animationInMs >= 0 : animationOutMs >= 0
      if (onlyUnconfigured && configured) continue
      code += animOriginals[leaf] + "; "
      delete animOriginals[leaf]
    }
    if (code !== "") Quickshell.execDetached(["hyprctl", "eval", animPrelude + code])
  }

  Process {
    id: animReader
    command: ["hyprctl", "-j", "animations"]
    stdout: StdioCollector { id: animOut }
    onExited: (code) => {
      if (code !== 0) return
      try { root.applyAnimations(JSON.parse(animOut.text)) } catch (e) {
        console.warn("fullscreen-app-auto-workspace: could not read Hyprland animations: " + e)
      }
    }
  }

  function syncAnimations() {
    restoreAnimations(true)
    if (animationInMs < 0 && animationOutMs < 0) return
    animReader.running = false
    animReader.running = true
  }

  // ---- Mute the game's audio while the layer is hidden ----
  property bool layerHidden: false
  property string layerMonitor: ""
  property var muteEntries: ({})
  property double fadeStartedAt: 0
  property string fadeDirection: "out"

  // App playback streams (isSink is true for them). Properties only fill in once a node is tracked.
  readonly property var audioStreams: !muteOnHide ? [] : Pipewire.nodes.values.filter(n => n.isStream && n.isSink)

  PwObjectTracker { objects: root.audioStreams }

  function entryAudio(entry) {
    try { return entry.node && entry.node.audio ? entry.node.audio : null } catch (e) { return null }
  }

  // Keeps per-channel balance when the channel count matches, else scales the average volume.
  function writeVolume(audio, entry, factor) {
    if (audio.volumes.length === entry.orig.length) {
      audio.volumes = entry.orig.map(v => v * factor)
    } else {
      audio.volume = entry.orig.reduce((a, b) => a + b, 0) / entry.orig.length * factor
    }
  }

  function setFactor(entry, factor) {
    const audio = entryAudio(entry)
    if (!audio) return false
    writeVolume(audio, entry, factor)
    entry.factor = factor
    return true
  }

  function restoreAudio(viaWpctl) {
    fadeTimer.stop()
    recheckTimer.stop()
    for (const id in muteEntries) {
      const entry = muteEntries[id]
      const audio = entryAudio(entry)
      if (!audio) continue
      writeVolume(audio, entry, 1)
      audio.muted = false
      // Property writes are only sent on the next event loop turn, which a shutting-down shell never gets.
      if (viaWpctl) {
        const avg = entry.orig.reduce((a, b) => a + b, 0) / entry.orig.length
        Quickshell.execDetached(["sh", "-c", "wpctl set-volume " + Number(id) + " " + avg + "; wpctl set-mute " + Number(id) + " 0"])
      }
    }
    muteEntries = ({})
  }

  function startFade(direction) {
    fadeDirection = direction
    fadeStartedAt = Date.now()
    for (const id in muteEntries) muteEntries[id].from = muteEntries[id].factor
    if (muteFadeMs <= 0) {
      fadeTick()
    } else {
      fadeTimer.start()
    }
  }

  function fadeTick() {
    const p = muteFadeMs <= 0 ? 1 : Math.min(1, (Date.now() - fadeStartedAt) / muteFadeMs)
    const target = fadeDirection === "out" ? 0 : 1
    for (const id in muteEntries) {
      const entry = muteEntries[id]
      if (!entryAudio(entry)) { delete muteEntries[id]; continue }
      setFactor(entry, entry.from + (target - entry.from) * p)
      if (p < 1) continue
      const audio = entryAudio(entry)
      if (fadeDirection === "out") {
        audio.muted = true
        writeVolume(audio, entry, 1)
        entry.factor = 1
        entry.muted = true
      } else {
        delete muteEntries[id]
      }
    }
    if (p >= 1) fadeTimer.stop()
  }

  Timer {
    id: fadeTimer
    interval: 30
    repeat: true
    onTriggered: root.fadeTick()
  }

  // Streams that start while the layer is hidden are muted straight away.
  Timer {
    id: recheckTimer
    interval: 1500
    repeat: true
    onTriggered: root.collectLayerStreams(false)
  }

  Process {
    id: pidReader
    command: ["sh", "-c", "hyprctl -j clients; echo '###'; ps -eo pid=,ppid="]
    stdout: StdioCollector { id: pidOut }
    onExited: (code) => { if (code === 0) root.onLayerSnapshot(pidOut.text) }
  }

  property bool fadeNext: true
  property var hiddenSeen: ({})

  function collectLayerStreams(fade) {
    fadeNext = fade
    if (pidReader.running) return
    pidReader.running = true
  }

  function layerPids(text) {
    const parts = text.split("###")
    let clients = []
    try { clients = JSON.parse(parts[0]) } catch (e) { return [] }
    const roots = clients.filter(c => c.workspace && c.workspace.name === layerWs && c.pid > 0).map(c => c.pid)
    const children = {}
    for (const line of (parts[1] || "").split("\n")) {
      const f = line.trim().split(/\s+/)
      if (f.length < 2) continue
      ;(children[f[1]] = children[f[1]] || []).push(Number(f[0]))
    }
    const all = {}
    const queue = roots.slice()
    while (queue.length > 0) {
      const pid = queue.pop()
      if (all[pid]) continue
      all[pid] = true
      for (const child of children[pid] || []) queue.push(child)
    }
    return all
  }

  function onLayerSnapshot(text) {
    if (!muteOnHide || !layerHidden) return
    const pids = layerPids(text)
    let added = false
    for (const node of audioStreams) {
      const props = node.properties || {}
      const pid = props["application.process.id"] || props["pipewire.sec.pid"]
      if (!pid || !pids[pid] || muteEntries[node.id] || !node.audio) continue
      // Already muted before the hide: the user's choice. Muted since: PulseAudio restored our mute onto a new stream.
      const mutedBefore = node.audio.muted && hiddenSeen[node.id]
      if (mutedBefore) continue
      const vols = Array.from(node.audio.volumes)
      if (vols.length === 0 || vols.length !== node.audio.channels.length) continue
      const entry = { node: node, orig: vols, factor: 1, from: 1, muted: false }
      muteEntries[node.id] = entry
      added = true
      if (!fadeNext || node.audio.muted) {
        node.audio.muted = true
        entry.muted = true
      }
    }
    if (added && fadeNext) startFade("out")
  }

  function onLayerHidden() {
    if (!muteOnHide || layerHidden) return
    layerHidden = true
    const seen = {}
    for (const node of audioStreams) seen[node.id] = true
    hiddenSeen = seen
    collectLayerStreams(true)
    recheckTimer.start()
  }

  function onLayerShown() {
    if (!layerHidden) return
    layerHidden = false
    recheckTimer.stop()
    for (const id in muteEntries) {
      const entry = muteEntries[id]
      const audio = entryAudio(entry)
      if (!audio) { delete muteEntries[id]; continue }
      if (entry.muted) {
        if (muteFadeMs > 0) writeVolume(audio, entry, 0)
        audio.muted = false
        entry.muted = false
        entry.factor = muteFadeMs > 0 ? 0 : 1
      }
    }
    startFade("in")
  }

  // The layer may already be open when the plugin starts.
  Process {
    id: monitorReader
    command: ["hyprctl", "-j", "monitors"]
    stdout: StdioCollector { id: monitorOut }
    onExited: (code) => {
      if (code !== 0 || root.layerMonitor !== "") return
      try {
        for (const m of JSON.parse(monitorOut.text)) {
          if (m.specialWorkspace && m.specialWorkspace.name === root.layerWs) root.layerMonitor = m.name
        }
      } catch (e) {}
    }
  }

  function onSpecialEvent(data) {
    const parts = String(data).split(",")
    const name = parts[0]
    const monitor = parts[parts.length - 1]
    if (name === layerWs) {
      layerMonitor = monitor
      onLayerShown()
    } else if (monitor === layerMonitor) {
      onLayerHidden()
    }
  }

  function load() {
    loader.command = ["hyprctl", "eval", "local m = dofile(" + luaString(luaFile) + "); m.start({ extra_classes = "
            + luaList(extraClasses) + ", never_fullscreen = " + luaList(neverFullscreen)
            + ", sweep_interval_ms = " + sweepIntervalMs + ", layer = " + luaString(layer)
            + ", keep_others = " + (layer !== "fullscreen" || keepOthers ? "true" : "false") + " })"]
    loader.running = false
    loader.running = true
    syncAnimations()
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
      let c = {}
      try { c = JSON.parse(text()) } catch (e) { c = {} }
      if (c === null || typeof c !== "object" || Array.isArray(c)) c = {}
      root.config = c
      root.applyConfig(c)
    }
    onLoadFailed: { root.config = ({}); root.applyConfig({}) }
  }

  IpcHandler {
    target: "fullscreen-app-auto-workspace"
    function toggle(): string {
      root.evalLua("if __game_layer then __game_layer.toggle() end")
      return "ok"
    }
    function reload(): string { configFile.reload(); return "ok" }
    // JSON with the settings in force: what config.json sets, and what the defaults are for the rest.
    function state(): string {
      return JSON.stringify({ layer: root.layer, extraClasses: root.extraClasses, neverFullscreen: root.neverFullscreen,
                              sweepIntervalMs: root.sweepIntervalMs, animationInMs: root.animationInMs,
                              animationOutMs: root.animationOutMs, muteOnHide: root.muteOnHide,
                              muteFadeMs: root.muteFadeMs, keepOthers: root.keepOthers, configured: Object.keys(root.config) })
    }
    // option <key> <value>: value is JSON (true, 400, ["^a$"]) or plain text; "unset" removes the key.
    function option(key: string, value: string): string {
      const known = ["layer", "extraClasses", "neverFullscreen", "sweepIntervalMs", "animationInMs",
                     "animationOutMs", "muteOnHide", "muteFadeMs", "keepOthers"]
      if (known.indexOf(key) < 0) return "error: unknown key " + key + " (" + known.join(", ") + ")"
      const next = Object.assign({}, root.config)
      if (value === "unset") delete next[key]
      else { let v = value; try { v = JSON.parse(value) } catch (e) {} next[key] = v }
      Quickshell.execDetached(["mkdir", "-p", Quickshell.env("HOME") + "/.config/fullscreen-app-auto-workspace"])
      root.config = next
      configFile.setText(JSON.stringify(next, null, 2) + "\n")
      root.applyConfig(next)
      return "ok"
    }
  }

  Connections {
    target: Hyprland
    function onRawEvent(event) {
      if (event.name === "configreloaded") {
        // A reload wipes our animation overrides, so their originals are current again.
        root.animOriginals = ({})
        root.load()
      } else if (event.name === "activespecial") {
        root.onSpecialEvent(event.data)
      }
    }
  }

  Component.onCompleted: monitorReader.running = true

  Component.onDestruction: {
    restoreAudio(true)
    restoreAnimations(false)
    Quickshell.execDetached(["hyprctl", "eval", "if __game_layer then __game_layer.stop(); __game_layer = nil end"])
  }
}
