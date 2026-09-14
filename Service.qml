pragma ComponentBehavior: Bound

import Quickshell
import Quickshell.Io
import QtQuick

// Plays a YouTube video (or anything mpv + yt-dlp can open) as the desktop
// background. Playback is delegated to mpvpaper, which draws on a click-through
// Wayland layer surface above the wallpaper and below every window. This
// service owns that process, talks to mpv over its JSON IPC socket for live
// pause/mute/volume, and persists settings on the plugin's shell.json entry.
//
// Every network URL is resolved through yt-dlp *before* mpvpaper is spawned.
// mpv swallows yt-dlp's error text, and mpvpaper deadlocks on quit/SIGTERM
// when its file never loaded, so a URL that cannot be resolved must never
// reach it. The probe also yields the title and the picked stream up front.
Item {
  id: root

  // Injected by the host after construction.
  property var shell
  property var manifest

  readonly property string pluginId:
    manifest && manifest.id ? String(manifest.id) : "ronholt.youtube-background"

  readonly property string home: Quickshell.env("HOME")
  readonly property string runtimeDir: {
    var dir = Quickshell.env("XDG_RUNTIME_DIR")
    return dir ? String(dir) : "/tmp"
  }
  readonly property string socketPath: runtimeDir + "/omarchy-youtube-background.sock"

  // ------------------------------------------------------------ settings

  FileView {
    id: userShellConfig
    path: root.home + "/.config/omarchy/shell.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.settingsRevision++
  }
  property int settingsRevision: 0

  // The plugin's inline entry. It lives in bar.layout.<section> when enabled
  // as a bar widget, or in plugins[] when enabled as a bare service.
  QtObject {
    id: settings

    readonly property var entry: {
      var revision = root.settingsRevision
      var config = null
      if (root.shell && root.shell.shellConfig) {
        config = root.shell.shellConfig
      } else {
        try {
          config = JSON.parse(String(userShellConfig.text() || "{}"))
        } catch (e) {
          config = null
        }
      }
      if (!config) return ({})
      var lists = []
      if (config.bar && config.bar.layout) {
        var sections = ["left", "center", "right"]
        for (var s = 0; s < sections.length; s++)
          if (Array.isArray(config.bar.layout[sections[s]])) lists.push(config.bar.layout[sections[s]])
      }
      if (Array.isArray(config.plugins)) lists.push(config.plugins)
      for (var l = 0; l < lists.length; l++)
        for (var i = 0; i < lists[l].length; i++)
          if (lists[l][i] && String(lists[l][i].id) === root.pluginId) return lists[l][i]
      return ({})
    }

    readonly property string url: typeof entry.url === "string" ? entry.url : ""
    readonly property bool playing: entry.playing === true
    readonly property bool muted: entry.muted !== false
    readonly property real volume: isFinite(Number(entry.volume)) ? Math.max(0, Math.min(100, Number(entry.volume))) : 50
    readonly property string quality: typeof entry.quality === "string" && entry.quality !== "" ? entry.quality : "1080"
    readonly property string codec: ["h264", "vp9", "any"].indexOf(entry.codec) !== -1 ? entry.codec : "h264"
    readonly property bool fill: entry.fill !== false
    readonly property string outputs: typeof entry.outputs === "string" && entry.outputs !== "" ? entry.outputs : "ALL"
    readonly property string layer: typeof entry.layer === "string" && entry.layer !== "" ? entry.layer : "bottom"
    readonly property string hwdec: typeof entry.hwdec === "string" && entry.hwdec !== "" ? entry.hwdec : "auto-safe"
    readonly property string extraOptions: typeof entry.extraOptions === "string" ? entry.extraOptions : ""
    // Netscape cookies.txt handed to yt-dlp, for videos YouTube gates behind
    // "Sign in to confirm you're not a bot" or an age check.
    readonly property string cookiesFile: typeof entry.cookiesFile === "string" ? entry.cookiesFile.trim() : ""
    // yt-dlp --cookies-from-browser spec, e.g. "brave+gnomekeyring:Default":
    // the browser's live session, decrypted on every resolve, nothing to export.
    readonly property string cookiesFromBrowser: typeof entry.cookiesFromBrowser === "string" ? entry.cookiesFromBrowser.trim() : ""
    // Most recently played first: [{ url, title }, ...], capped at historyLimit.
    readonly property var history: {
      if (!Array.isArray(entry.history)) return []
      var out = []
      for (var i = 0; i < entry.history.length && out.length < root.historyLimit; i++) {
        var h = entry.history[i]
        if (!h || typeof h.url !== "string" || h.url === "") continue
        out.push({ url: h.url, title: typeof h.title === "string" ? h.title : "" })
      }
      return out
    }
  }

  // updateEntryInline replaces the whole entry, so merge over current values.
  function persistMany(changes) {
    if (!shell || typeof shell.updateEntryInline !== "function") return false
    var next = { id: root.pluginId }
    for (var k in settings.entry)
      if (k !== "id") next[k] = settings.entry[k]
    for (var c in changes) next[c] = changes[c]
    shell.updateEntryInline(root.pluginId, next)
    return true
  }

  function persist(key, value) {
    var changes = {}
    changes[key] = value
    persistMany(changes)
    return value
  }

  // ------------------------------------------------------------ public state

  readonly property bool running: mpvProc.running
  readonly property bool probing: probeProc.running
  readonly property string url: settings.url
  readonly property string quality: settings.quality
  readonly property string codec: settings.codec
  readonly property bool fill: settings.fill
  readonly property string cookiesFile: settings.cookiesFile
  readonly property string cookiesFromBrowser: settings.cookiesFromBrowser
  // What the panel shows in its single cookies field.
  readonly property string cookies: settings.cookiesFile !== "" ? settings.cookiesFile : settings.cookiesFromBrowser

  // Mirrored from mpv over IPC while it runs; fall back to persisted values.
  property bool paused: false
  property bool muted: settings.muted
  property real volume: settings.volume
  property string title: ""
  // Playback position in seconds, polled at 1 Hz while mpv is up; duration
  // and seekable come from observe_property. A live stream has no duration.
  property real position: 0
  property real duration: 0
  property bool seekable: false
  // Human readable stream picked by yt-dlp, e.g. "H.264 1080p 25fps".
  property string stream: ""
  property string activeUrl: ""
  property string lastError: ""
  property string stderrTail: ""
  property bool stopRequested: false
  property bool loaded: false

  // "stopped" | "starting" | "playing" | "paused" | "error"
  readonly property string status: {
    if (!running) {
      if (probing) return "starting"
      return lastError ? "error" : "stopped"
    }
    if (lastError && !loaded) return "error"
    if (!ipcConnected || !loaded) return "starting"
    return paused ? "paused" : "playing"
  }

  readonly property var qualityOptions: ["best", "2160", "1440", "1080", "720", "480"]
  readonly property var codecOptions: ["h264", "vp9", "any"]

  // The last historyLimit videos that actually started, newest first, for
  // the panel's history dropdown. Titles come from the yt-dlp probe and are
  // refreshed from mpv's media-title once the file loads.
  readonly property int historyLimit: 10
  readonly property var history: settings.history

  // The new history array with url moved (or added) to the front, or null
  // when that changes nothing, so a replayed video costs no settings write.
  function historyWith(url, title) {
    var next = [{ url: url, title: String(title || "") }]
    var old = settings.history
    for (var i = 0; i < old.length && next.length < historyLimit; i++)
      if (old[i].url !== url) next.push(old[i])
    return JSON.stringify(next) === JSON.stringify(old) ? null : next
  }

  // Update the active entry's title once mpv reports one. Only touches the
  // entry that is already at the front, so playback order is unchanged.
  function refreshHistoryTitle(url, title) {
    var old = settings.history
    if (!url || !title || !old.length || old[0].url !== url || old[0].title === title) return
    // mpv's placeholder title for an unresolved URL is the URL's last segment.
    if (url.slice(-title.length) === title) return
    persist("history", historyWith(url, title))
  }

  function clearHistory() {
    persist("history", [])
  }

  function fallbackTitle(url) {
    var s = String(url || "")
    if (/^\//.test(s)) return s.split("/").pop()
    return s
  }

  // yt-dlp's default order picks AV1 first, which older GPUs cannot decode in
  // hardware; a 720p60 AV1 wallpaper then eats half a core. Prefer H.264,
  // which every VA-API/VDPAU/NVDEC generation handles, then VP9, then whatever
  // is left. "best" quality means no height cap.
  function ytdlFormat(quality, codec) {
    var cap = ""
    if (quality !== "best") {
      var h = parseInt(quality, 10)
      if (!(h > 0)) h = 1080
      cap = "[height<=?" + h + "]"
    }
    var chain = []
    if (codec === "h264") chain.push("bestvideo" + cap + "[vcodec^=avc1]+bestaudio",
                                     "bestvideo" + cap + "[vcodec^=vp]+bestaudio")
    else if (codec === "vp9") chain.push("bestvideo" + cap + "[vcodec^=vp]+bestaudio",
                                         "bestvideo" + cap + "[vcodec^=avc1]+bestaudio")
    chain.push("bestvideo" + cap + "+bestaudio", "best" + cap, "best")
    return chain.join("/")
  }

  function isPlayableUrl(value) {
    var s = String(value || "").trim()
    return /^(https?:\/\/|ytdl:\/\/|\/)/.test(s)
  }

  // Local files go straight to mpv; anything network goes through yt-dlp first.
  function needsProbe(value) {
    return /^(https?:\/\/|ytdl:\/\/)/.test(String(value || ""))
  }

  // Accepts a full URL, a bare 11-char YouTube id, or a youtu.be short link.
  function normalizeUrl(value) {
    var s = String(value || "").trim()
    if (/^[A-Za-z0-9_-]{11}$/.test(s)) return "https://www.youtube.com/watch?v=" + s
    return s
  }

  // ------------------------------------------------------------ control

  function buildCommand(url) {
    var opts = [
      "input-ipc-server=" + socketPath,
      "loop-file=inf",
      "hwdec=" + settings.hwdec,
      "mute=" + (settings.muted ? "yes" : "no"),
      "volume=" + Math.round(settings.volume),
      "ytdl=yes",
      "ytdl-format=" + ytdlFormat(settings.quality, settings.codec),
      "osc=no",
      "osd-bar=no",
      "osd-level=0",
      "input-default-bindings=no",
      "keep-open=no",
      "msg-level=all=warn"
    ]
    if (settings.fill) opts.push("panscan=1.0")
    var raw = []
    if (settings.cookiesFile !== "") raw.push("cookies=" + settings.cookiesFile)
    if (settings.cookiesFromBrowser !== "") raw.push("cookies-from-browser=" + settings.cookiesFromBrowser)
    if (raw.length) opts.push('ytdl-raw-options="' + raw.join(",").replace(/"/g, "") + '"')
    if (settings.extraOptions.trim() !== "") opts.push(settings.extraOptions.trim())

    var cmd = ["mpvpaper", "-l", settings.layer]
    cmd.push("-o", opts.join(" "))
    cmd.push(settings.outputs, url)
    return cmd
  }

  property string pendingUrl: ""

  // Validate, resolve through yt-dlp, then hand over to launch(). Returns
  // false only for input that is not a URL at all; resolution errors land in
  // lastError asynchronously.
  function start(value) {
    var url = normalizeUrl(value || settings.url)
    if (!isPlayableUrl(url)) {
      lastError = url ? "Not a URL: " + url : "No video URL set"
      return false
    }
    lastError = ""
    stopRequested = false
    retryTimer.stop()
    retries = 0
    if (needsProbe(url)) {
      runProbe(url, "start")
      return true
    }
    title = ""
    stream = ""
    launch(url)
    return true
  }

  // Kill any orphan mpvpaper from a previous shell life (identified by our
  // socket path), then spawn. Never runs plugin-supplied text through a shell.
  function launch(url) {
    pendingUrl = url
    var changes = {}
    if (url !== settings.url || !settings.playing) {
      changes.url = url
      changes.playing = true
    }
    var history = historyWith(url, title || fallbackTitle(url))
    if (history) changes.history = history
    if (Object.keys(changes).length) persistMany(changes)
    if (mpvProc.running) {
      // Same process, new file: no flicker, no re-spawn.
      activeUrl = url
      loaded = false
      ipcSend(["loadfile", url, "replace"])
      // mpv keeps "pause" across loadfile; a freshly chosen video always plays.
      if (paused) setPaused(false)
      return
    }
    if (!cleanupProc.running) cleanupProc.running = true
  }

  function launchPending() {
    console.log("youtube-background: launchPending url=" + pendingUrl + " running=" + mpvProc.running)
    if (!pendingUrl || mpvProc.running) return
    activeUrl = pendingUrl
    loaded = false
    mpvProc.command = buildCommand(pendingUrl)
    mpvProc.running = true
  }

  function stop(persistState) {
    if (persistState !== false && settings.playing) persist("playing", false)
    stopRequested = true
    lastError = ""
    retryTimer.stop()
    if (mpvProc.running) {
      ipcSend(["quit"])
      quitGrace.restart()
    }
  }

  function toggle() {
    if (running) stop()
    else start()
    return running
  }

  function ipcSend(command) {
    if (!ipcConnected) return false
    var msg = Array.isArray(command) ? { command: command } : command
    ipc.write(JSON.stringify(msg) + "\n")
    ipc.flush()
    return true
  }

  function setPaused(value) {
    paused = !!value
    ipcSend(["set_property", "pause", paused])
  }

  function togglePause() {
    setPaused(!paused)
  }

  // seek(secs, "relative" | "absolute"). Refused for live streams and
  // before the file has loaded. The optimistic position keeps the slider from
  // snapping back until the next poll answers.
  function seek(secs, mode) {
    var n = Number(secs)
    if (!isFinite(n) || !running || !loaded || !seekable) return false
    mode = mode === "absolute" ? "absolute" : "relative"
    var target = mode === "absolute" ? n : position + n
    if (duration > 0) target = Math.max(0, Math.min(duration, target))
    else target = Math.max(0, target)
    if (!ipcSend(["seek", target, "absolute"])) return false
    position = target
    pollPosition()
    return true
  }

  function pollPosition() {
    ipcSend({ command: ["get_property", "time-pos"], request_id: 1001 })
  }

  function setMuted(value) {
    muted = !!value
    persist("muted", muted)
    ipcSend(["set_property", "mute", muted])
  }

  function setVolume(value) {
    var v = Math.max(0, Math.min(100, Math.round(Number(value))))
    if (!isFinite(v)) return
    volume = v
    persist("volume", v)
    ipcSend(["set_property", "volume", v])
  }

  // Takes effect on the next start; yt-dlp picks the stream up front.
  function setQuality(value) {
    var q = String(value || "").replace(/p$/, "")
    if (qualityOptions.indexOf(q) === -1) return false
    persist("quality", q)
    if (running) restart()
    return true
  }

  function setCodec(value) {
    var c = String(value || "")
    if (codecOptions.indexOf(c) === -1) return false
    persist("codec", c)
    if (running) restart()
    return true
  }

  function setFill(value) {
    persist("fill", !!value)
    ipcSend(["set_property", "panscan", value ? 1.0 : 0.0])
  }

  // One entry point for both cookie sources: a path (starts with / or ~)
  // sets cookiesFile, anything else is a --cookies-from-browser spec such as
  // "brave+gnomekeyring:Default", and "" clears both. mpv reads them at
  // spawn, so a running video restarts; the probe picks them up either way.
  function setCookies(value) {
    var v = String(value || "").trim()
    var changes = { cookiesFile: "", cookiesFromBrowser: "" }
    if (/^[~\/]/.test(v)) changes.cookiesFile = v.replace(/^~(?=\/|$)/, home)
    else if (v !== "") changes.cookiesFromBrowser = v
    persistMany(changes)
    if (running) restart()
    return changes.cookiesFile || changes.cookiesFromBrowser
  }

  function setCookiesFile(value) {
    return setCookies(String(value || "").trim() === "" ? "" : value)
  }

  function restart() {
    if (!running) return
    restartPending = true
    stop(false)
  }
  property bool restartPending: false

  // ------------------------------------------------------------ yt-dlp probe

  property string probeUrl: ""
  property string probeReason: "start"

  // Only one probe runs at a time. A request that arrives mid-probe just
  // replaces probeUrl; the finish handler notices the mismatch and reruns.
  function runProbe(url, reason) {
    probeUrl = url
    probeReason = reason
    if (probeProc.running) return
    probeNow()
  }

  function probeNow() {
    var target = probeUrl.replace(/^ytdl:\/\//, "")
    // Everything user-supplied travels as a positional argument, never
    // interpolated into the script text. The exit code and the URL are echoed
    // back so one stdout stream carries the whole result in order.
    var script = 'out=$(timeout 45 yt-dlp --no-playlist --no-warnings -f "$2" '
      + '--print "T:%(title)s" --print "F:%(vcodec)s|%(height)s|%(fps)s" '
      + '${3:+--cookies "$3"} ${4:+--cookies-from-browser "$4"} -- "$1" 2>&1); rc=$?; '
      + 'printf "R:%s\\nU:%s\\n%s\\n" "$rc" "$1" "$out"'
    probeProc.command = ["bash", "-c", script, "yt-dlp-probe", target,
                         ytdlFormat(settings.quality, settings.codec),
                         settings.cookiesFile, settings.cookiesFromBrowser]
    probeProc.running = true
  }

  Process {
    id: probeProc
    stdout: StdioCollector {
      onStreamFinished: root.probeFinished(text)
    }
  }

  function probeFinished(text) {
    var rc = -1, url = "", title = "", info = "", err = ""
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line.indexOf("R:") === 0) rc = parseInt(line.slice(2), 10)
      else if (line.indexOf("U:") === 0) url = line.slice(2)
      else if (line.indexOf("T:") === 0) title = line.slice(2)
      else if (line.indexOf("F:") === 0) info = line.slice(2)
      else if (/^ERROR:/.test(line)) err = line
    }
    var target = probeUrl.replace(/^ytdl:\/\//, "")
    if (url !== target) {
      // Superseded while running; resolve the newer request instead.
      if (probeUrl) probeNow()
      return
    }
    if (probeReason === "start" && stopRequested) return

    if (rc === 0) {
      root.title = title
      root.stream = describeStream(info)
      lastError = ""
      console.log("youtube-background: resolved " + probeUrl + " as " + root.stream)
      if (probeReason === "start") launch(probeUrl)
      else if (mpvProc.running) ipcSend(["loadfile", probeUrl, "replace"])
      return
    }

    lastError = probeError(err, rc)
    console.log("youtube-background: probe failed rc=" + rc + ": " + lastError)
    if (probeReason === "retry") scheduleRetry()
  }

  function describeStream(info) {
    var parts = String(info || "").split("|")
    var vcodec = parts[0] || ""
    var codecName = /^avc1/.test(vcodec) ? "H.264"
      : /^(vp09|vp9)/.test(vcodec) ? "VP9"
      : /^av01/.test(vcodec) ? "AV1"
      : /^hev1|^hvc1/.test(vcodec) ? "H.265"
      : vcodec.split(".")[0]
    var out = [codecName]
    var h = parseInt(parts[1], 10)
    if (h > 0) out.push(h + "p")
    var fps = Math.round(Number(parts[2]))
    if (fps > 0) out.push(fps + "fps")
    return out.filter(function(s) { return s && s !== "none" }).join(" ")
  }

  function probeError(err, rc) {
    if (rc === 124) return "yt-dlp timed out resolving the stream"
    if (rc === 127 || /command not found/.test(err)) return "yt-dlp is not installed"
    var s = String(err || "")
      .replace(/^ERROR:\s*/, "")
      .replace(/^\[[^\]]+\]\s*/, "")
      .replace(/^[A-Za-z0-9_-]{11}:\s*/, "")
    // yt-dlp appends two sentences of wiki links; keep the reason.
    s = s.split(/\.?\s+Use --cookies/)[0].split(/\s+See\s+https?:/)[0].trim()
    if (/not a bot|sign in|login required|age/i.test(s))
      s += ". YouTube wants a signed-in session: set Cookies in Options"
    else if (/could not be decrypted|no key found|secretstorage|keyring/i.test(err))
      s = "Could not read browser cookies: " + s
    return s || "yt-dlp failed (exit " + rc + ")"
  }

  // ------------------------------------------------------------ processes

  // mpvpaper never handles SIGTERM while its file failed to load, so orphans
  // get SIGKILL straight away; there is nothing to save anyway.
  Process {
    id: cleanupProc
    command: ["pkill", "-9", "-f", "input-ipc-server=" + root.socketPath]
    onExited: root.launchPending()
  }

  Process {
    id: mpvProc
    // stderr is diagnostics only: hwdec probing on a non-NVIDIA box prints
    // "Failed to open VDPAU backend" and friends while playing back fine. The
    // last line is surfaced only if the process then dies.
    stderr: SplitParser {
      onRead: function(line) {
        var s = String(line || "").trim()
        if (!s) return
        console.log("youtube-background: " + s)
        if (/error|failed|ERROR/i.test(s)) root.stderrTail = s
      }
    }
    onStarted: {
      root.stopRequested = false
      root.stderrTail = ""
      reconnect.restart()
    }
    onExited: function(exitCode, exitStatus) {
      console.log("youtube-background: mpvpaper exited code=" + exitCode + " stopRequested=" + root.stopRequested)
      root.ipcDisconnect()
      quitGrace.stop()
      killGrace.stop()
      root.loaded = false
      if (!root.restartPending) {
        root.title = ""
        root.stream = ""
      }
      if (!root.stopRequested && exitCode !== 0) {
        if (!root.lastError)
          root.lastError = exitCode === 255 || exitCode === -1
            ? "mpvpaper failed to start (is it installed?)"
            : (root.stderrTail || "mpvpaper exited with code " + exitCode)
      }
      if (root.restartPending) {
        root.restartPending = false
        root.pendingUrl = root.activeUrl
        Qt.callLater(root.launchPending)
      }
    }
  }

  // quit over IPC is graceful. mpvpaper 1.9 deadlocks in its exit path when
  // the file never loaded (and ignores SIGTERM in the same state), so the
  // fallback escalates all the way to SIGKILL.
  Timer {
    id: quitGrace
    interval: 1500
    onTriggered: if (mpvProc.running) { mpvProc.signal(15); killGrace.restart() }
  }

  Timer {
    id: killGrace
    interval: 1500
    onTriggered: if (mpvProc.running) {
      console.log("youtube-background: mpvpaper ignored quit and SIGTERM, sending SIGKILL")
      mpvProc.signal(9)
    }
  }

  // mpvpaper is up but mpv never opened its socket: a hung process that no
  // IPC command can reach. Kill it and say so rather than spin forever.
  Timer {
    id: startWatchdog
    interval: 30000
    running: mpvProc.running && !root.ipcConnected && !root.stopRequested
    onTriggered: {
      root.lastError = "mpvpaper started but mpv never answered on its socket"
      root.stopRequested = true
      mpvProc.signal(9)
    }
  }

  // Resume once the settings entry has actually been read. shell.json is
  // loaded asynchronously and `shell` is injected after onCompleted, so an
  // eager check here would always see an empty entry after a hot reload.
  property bool restored: false

  function restoreIfNeeded() {
    if (restored || !settings.entry || settings.entry.id !== root.pluginId) return
    restored = true
    console.log("youtube-background: restore playing=" + settings.playing + " url=" + settings.url)
    // A stale mpvpaper from a crashed shell would otherwise keep playing with
    // nobody controlling it, so the cleanup runs even when nothing resumes.
    pendingUrl = ""
    if (!cleanupProc.running) cleanupProc.running = true
    if (settings.playing && settings.url) start(settings.url)
  }

  onSettingsRevisionChanged: restoreIfNeeded()
  onShellChanged: restoreIfNeeded()
  Component.onCompleted: restoreIfNeeded()

  // Not enabled anywhere: the entry never appears, so nothing to restore.
  Timer {
    interval: 3000
    running: !root.restored
    onTriggered: if (!root.restored) { root.restored = true; cleanupProc.running = true }
  }

  Component.onDestruction: {
    if (mpvProc.running) mpvProc.signal(9)
  }

  // ------------------------------------------------------------ mpv IPC

  // Quickshell's Socket keeps its QLocalSocket after a refused connect and
  // then ignores every later `connected = true`, so each attempt needs a fresh
  // object. The Loader is that object's lifetime.
  Loader {
    id: ipcLoader
    active: false
    // A unix connect completes synchronously inside component creation, so
    // `connected` can already be true before the Loader has assigned `item`.
    // Subscribe through the socket itself, from whichever hook runs last.
    onLoaded: if (item && item.connected) root.ipcSubscribe(item)
    sourceComponent: Socket {
      id: sock
      property bool subscribed: false
      path: root.socketPath
      connected: true
      parser: SplitParser {
        onRead: function(line) {
          var s = String(line || "").trim()
          if (!s) return
          var msg
          try { msg = JSON.parse(s) } catch (e) { return }
          root.handleIpc(msg)
        }
      }
      onConnectionStateChanged: {
        if (connected) root.ipcSubscribe(sock)
        else root.ipcLost()
      }
      onError: function(err) { root.ipcLost() }
    }
  }

  readonly property var ipc: ipcLoader.item
  readonly property bool ipcConnected: ipc ? ipc.connected === true : false

  function ipcSubscribe(socket) {
    if (!socket || socket.subscribed || !socket.connected) return
    socket.subscribed = true
    var props = ["pause", "mute", "volume", "media-title", "duration", "seekable"]
    for (var i = 0; i < props.length; i++)
      socket.write(JSON.stringify({ command: ["observe_property", i + 1, props[i]] }) + "\n")
    socket.write(JSON.stringify({ command: ["get_property", "pause"] }) + "\n")
    socket.flush()
  }

  function ipcConnect() {
    ipcLoader.active = false
    ipcLoader.active = true
  }

  function ipcDisconnect() {
    ipcLoader.active = false
  }

  // mpvpaper brings mpv up only after its Wayland surface is configured, so
  // the socket appears anywhere from a few hundred ms to a couple of seconds
  // after spawn. Keep knocking until it answers.
  function ipcLost() {
    if (mpvProc.running && !stopRequested) reconnect.restart()
  }

  Timer {
    id: reconnect
    interval: 500
    onTriggered: {
      if (!mpvProc.running || root.stopRequested || root.ipcConnected) return
      root.ipcConnect()
    }
  }

  Timer {
    interval: 2000
    repeat: true
    running: mpvProc.running && !root.ipcConnected && !reconnect.running
    onTriggered: reconnect.restart()
  }

  Timer {
    interval: 1000
    repeat: true
    running: mpvProc.running && root.ipcConnected && root.loaded && !root.paused
    onTriggered: root.pollPosition()
  }

  function handleIpc(msg) {
    if (!msg) return
    if (msg.event === "property-change") {
      if (msg.name === "pause") paused = msg.data === true
      else if (msg.name === "mute") muted = msg.data === true
      else if (msg.name === "volume" && isFinite(Number(msg.data))) volume = Number(msg.data)
      else if (msg.name === "media-title" && typeof msg.data === "string" && msg.data !== "") {
        title = msg.data
        // Before the file opens mpv reports the URL's tail ("watch?v=...")
        // as its title; only a title seen after load is worth keeping.
        if (loaded) refreshHistoryTitle(activeUrl, title)
      }
      else if (msg.name === "duration") duration = isFinite(Number(msg.data)) && Number(msg.data) > 0 ? Number(msg.data) : 0
      else if (msg.name === "seekable") seekable = msg.data === true
    } else if (msg.request_id === 1001) {
      if (msg.error === "success" && isFinite(Number(msg.data))) position = Number(msg.data)
    } else if (msg.event === "file-loaded") {
      loaded = true
      lastError = ""
      retries = 0
      position = 0
      pollPosition()
      // A local file was recorded under its basename; mpv knows better now.
      refreshHistoryTitle(activeUrl, title)
    } else if (msg.event === "end-file") {
      position = 0
      duration = 0
      seekable = false
      if (msg.reason === "error") {
        lastError = "Playback failed: " + (msg.file_error || "unknown error")
        loaded = false
        scheduleRetry()
      }
    }
  }

  // YouTube stream URLs expire after a few hours and networks drop. Re-resolve
  // through yt-dlp with growing backoff rather than leaving a blank desktop.
  // Each retry goes through the probe, so the reason for a persistent failure
  // is shown instead of a bare "unrecognized file format".
  property int retries: 0
  readonly property int maxRetries: 6

  function scheduleRetry() {
    if (stopRequested || restartPending || !activeUrl) return
    if (retries >= maxRetries) {
      lastError += " (gave up after " + maxRetries + " retries)"
      return
    }
    retries += 1
    retryTimer.interval = Math.min(120000, 5000 * Math.pow(2, retries - 1))
    retryTimer.restart()
  }

  Timer {
    id: retryTimer
    onTriggered: {
      if (!mpvProc.running || root.stopRequested) return
      console.log("youtube-background: retry " + root.retries + " for " + root.activeUrl)
      if (root.needsProbe(root.activeUrl)) root.runProbe(root.activeUrl, "retry")
      else root.ipcSend(["loadfile", root.activeUrl, "replace"])
    }
  }

  // ------------------------------------------------------------ CLI

  // omarchy-shell youtube-background <verb> [arg]
  IpcHandler {
    target: "youtube-background"

    function play(url: string): string {
      return root.start(url) ? "ok" : root.lastError
    }

    function stop(): string {
      root.stop()
      return "ok"
    }

    function toggle(): string {
      root.toggle()
      return root.running ? "stopping" : "starting"
    }

    function pause(value: string): string {
      if (value === "true" || value === "false") root.setPaused(value === "true")
      else if (value === "toggle") root.togglePause()
      else if (value !== "get") return "usage: pause get|true|false|toggle"
      return root.paused ? "true" : "false"
    }

    function mute(value: string): string {
      if (value === "true" || value === "false") root.setMuted(value === "true")
      else if (value === "toggle") root.setMuted(!root.muted)
      else if (value !== "get") return "usage: mute get|true|false|toggle"
      return root.muted ? "true" : "false"
    }

    function volume(value: string): string {
      if (value !== "get") {
        var n = Number(value)
        if (!isFinite(n)) return "usage: volume get|<0-100>"
        root.setVolume(n)
      }
      return String(Math.round(root.volume))
    }

    // seek get | seek +10 | seek -10 | seek 90   (signed = relative, unsigned = absolute)
    function seek(value: string): string {
      var v = String(value).trim()
      if (v !== "get") {
        var n = Number(v)
        if (!isFinite(n) || v === "") return "usage: seek get|+<secs>|-<secs>|<secs>"
        if (!root.seek(n, /^[+-]/.test(v) ? "relative" : "absolute"))
          return root.running ? (root.seekable ? "not loaded" : "not seekable") : "not running"
      }
      return Math.round(root.position) + "/" + Math.round(root.duration)
    }

    function quality(value: string): string {
      if (value === "get") return root.quality
      if (!root.setQuality(value)) return "usage: quality get|" + root.qualityOptions.join("|")
      // Settings reload asynchronously; report what was just persisted.
      return String(value).replace(/p$/, "")
    }

    function codec(value: string): string {
      if (value === "get") return root.codec
      if (!root.setCodec(value)) return "usage: codec get|" + root.codecOptions.join("|")
      return String(value)
    }

    function url(value: string): string {
      if (value !== "get") return root.start(value) ? "ok" : root.lastError
      return root.url
    }

    // cookies get | cookies /path/to/cookies.txt | cookies brave+gnomekeyring:Default | cookies ""
    function cookies(value: string): string {
      if (value === "get") return root.cookies
      return root.setCookies(value)
    }

    // history get | history clear
    function history(value: string): string {
      if (value === "clear") { root.clearHistory(); return "ok" }
      if (value !== "get") return "usage: history get|clear"
      return JSON.stringify(root.history)
    }

    function status(): string {
      return JSON.stringify({
        status: root.status,
        ipc: root.ipcConnected,
        probing: root.probing,
        url: root.url,
        title: root.title,
        stream: root.stream,
        paused: root.paused,
        muted: root.muted,
        volume: Math.round(root.volume),
        position: Math.round(root.position),
        duration: Math.round(root.duration),
        seekable: root.seekable,
        quality: root.quality,
        codec: root.codec,
        cookiesFile: root.cookiesFile,
        cookiesFromBrowser: root.cookiesFromBrowser,
        error: root.lastError
      })
    }
  }
}
