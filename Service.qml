import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import "Model.js" as Model

// Polls the local CraftBot backend (loopback only) and controls its systemd
// user service. No shell is ever involved: requests go through
// XMLHttpRequest, and systemctl and the stream helper run with argv lists.
//
// Each step's short status line ("Reading the project README...") is only
// sent live on CraftBot's socket, so stream.py follows it while CraftBot is
// online and reports it per session (stepStatus).
Item {
  id: root

  property var settings: ({})
  property bool panelOpen: false

  readonly property string unit: Model.serviceName(setting("serviceName", ""), "craftbot.service")
  readonly property string home: Quickshell.env("HOME") || ""
  // Where Install puts CraftBot, and where a CraftBot without a service is
  // looked for. Must stay inside $HOME.
  readonly property string installDir: Model.homePath(setting("installDir", ""), home, home + "/CraftBot")

  // CraftBot moves to the next free ports when 7925/7926 are taken and records
  // the real ones in <install>/ui.json. A URL set in the settings wins.
  property var uiPorts: null
  readonly property string apiUrl: {
    var set = Model.loopbackUrl(setting("apiUrl", ""), "")
    if (set !== "" && set !== "http://127.0.0.1:7926") return set
    return uiPorts ? "http://127.0.0.1:" + uiPorts.backend : "http://127.0.0.1:7926"
  }
  readonly property string uiUrl: {
    var set = Model.loopbackUrl(setting("uiUrl", ""), "")
    if (set !== "" && set !== "http://localhost:7925") return set
    return uiPorts && uiPorts.frontend ? "http://localhost:" + uiPorts.frontend : "http://localhost:7925"
  }

  // offline | idle | thinking | running | working | waiting
  property string key: "offline"
  property bool online: false
  property bool checked: false
  property string agentName: "CraftBot"
  property string version: ""
  property var running: []
  property int busyCount: 0
  property var sessions: []
  property string provider: ""
  property string model: ""
  property var tokens: ({ input: 0, output: 0, cached: 0, total: 0 })
  property var requests: ({ today: 0, lastHour: 0 })
  property var cost: ({ today: 0, month: 0, total: 0 })
  property var lastRequest: null
  property double updatedAt: 0
  // sessionId -> the current step's status line, from stream.py.
  property var stepStatus: ({})

  // active | inactive | activating | deactivating | failed | reloading | missing | unknown
  property string serviceState: "unknown"
  property string serviceRoot: ""        // --state-root of the service
  property bool localInstall: false      // installDir holds a CraftBot (craftbot.py)
  property bool localChecked: false
  // start | stop | restart | install
  property string pendingVerb: ""
  property string lastError: ""

  readonly property bool busy: key === "running" || key === "thinking" || key === "working"
  readonly property bool controlBusy: controlProcess.running || pendingVerb !== ""
  readonly property bool serviceKnown: serviceState !== "missing" && serviceState !== "unknown"
  readonly property bool serviceUp: serviceState === "active" || serviceState === "activating" || serviceState === "reloading"
  readonly property string stateRoot: serviceRoot !== "" ? serviceRoot : localInstall ? installDir : ""
  // Nothing answers, no service, and no CraftBot folder: offer to install.
  readonly property bool notInstalled: checked && localChecked && !online && serviceState === "missing" && !localInstall
  readonly property bool canStart: !online && (serviceKnown ? !serviceUp : localInstall)
  readonly property int pollMs: notInstalled && pendingVerb === "" ? 60000
    : !online ? 15000 : (busy || key === "waiting" || panelOpen) ? 2000 : 5000

  // A run just ended (busy → idle): the bar gives a small hop.
  signal runFinished()

  property var _xhr: null
  property string _serviceOut: ""
  readonly property string streamScript: localFile("stream.py")
  readonly property string installScript: localFile("install.sh")

  function localFile(name) {
    var url = String(Qt.resolvedUrl(name))
    return url.indexOf("file://") === 0 ? decodeURIComponent(url.substring(7)) : url
  }

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function refresh() {
    if (_xhr) return
    var xhr = new XMLHttpRequest()
    _xhr = xhr
    timeoutTimer.restart()
    xhr.onreadystatechange = function() {
      if (xhr.readyState !== XMLHttpRequest.DONE || root._xhr !== xhr) return
      root._xhr = null
      timeoutTimer.stop()
      if (xhr.status === 200) root.applyState(xhr.responseText)
      else root.goOffline()
    }
    xhr.open("GET", apiUrl + "/api/state")
    xhr.send()
    if (!online || panelOpen) { refreshService(); checkLocalInstall() }
  }

  function applyState(raw) {
    var s = Model.parseState(raw)
    if (!s.ok) { goOffline(); return }
    var wasBusy = busy
    agentName = s.agentName
    version = s.version
    running = s.running
    busyCount = s.busyCount
    sessions = s.sessions
    provider = s.provider
    model = s.model
    tokens = s.tokens
    requests = s.requests
    cost = s.cost
    lastRequest = s.lastRequest
    online = true
    checked = true
    key = s.key
    updatedAt = Date.now()
    lastError = ""
    if (pendingVerb === "install") { pendingVerb = ""; installWatch.stop() }
    if (wasBusy && s.key === "idle") runFinished()
    // Self-healing: every good poll makes sure the status helper is up.
    if (!streamProcess.running && !streamRetry.running && !_streamStopping) ensureStream()
  }

  function goOffline() {
    online = false
    checked = true
    key = "offline"
    running = []
    busyCount = 0
  }

  function refreshService() {
    if (serviceProcess.running) return
    _serviceOut = ""
    serviceProcess.command = ["systemctl", "--user", "show", "-p", "LoadState", "-p", "ActiveState", "-p", "ExecStart", root.unit]
    serviceProcess.running = true
  }

  function applyService(text) {
    var load = "", active = ""
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var m = lines[i].match(/^(LoadState|ActiveState)=([a-z-]{1,24})$/)
      if (!m) continue
      if (m[1] === "LoadState") load = m[2]
      else active = m[2]
    }
    if (load === "not-found") serviceState = "missing"
    else if (active !== "") serviceState = active
    else serviceState = "unknown"
    serviceRoot = serviceState === "missing" ? "" : Model.stateRootFrom(text)
  }

  function checkLocalInstall() {
    if (localProcess.running || installDir === "") return
    localProcess.command = ["test", "-f", installDir + "/craftbot.py"]
    localProcess.running = true
  }

  // With a service: systemctl. Without one, a CraftBot folder can still be
  // started the way its README says (`python3 craftbot.py start`).
  function control(verb) {
    if (["start", "stop", "restart"].indexOf(verb) === -1 || controlProcess.running) return
    var command
    if (serviceKnown) command = ["systemctl", "--user", verb, root.unit]
    else if (verb === "start" && localInstall) command = ["python3", root.installDir + "/craftbot.py", "start"]
    else return
    pendingVerb = verb
    lastError = ""
    if (verb === "stop") goOffline()
    controlProcess.workingDirectory = serviceKnown ? root.home : root.installDir
    controlProcess.command = command
    controlProcess.running = true
  }

  // Clone and install CraftBot in a floating terminal (install.sh), then
  // watch for it to come up. Clicking again reopens the terminal.
  function install() {
    if (!notInstalled && pendingVerb !== "install") return
    pendingVerb = "install"
    lastError = ""
    Quickshell.execDetached(["omarchy-launch-floating-terminal-with-presentation",
      Util.shellQuote(root.installScript) + " " + Util.shellQuote(root.installDir)])
    installWatch.ticks = 0
    installWatch.restart()
  }

  function openUi() {
    // Focus a window already showing CraftBot (a browser tab or web app),
    // else open it as a web app. The URL is loopback-validated above.
    Quickshell.execDetached(["omarchy-launch-or-focus-webapp", "^CraftBot( - .*)?$", root.uiUrl])
  }

  Timer {
    id: pollTimer
    interval: root.pollMs
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: timeoutTimer
    interval: 2500
    onTriggered: {
      var xhr = root._xhr
      root._xhr = null
      if (xhr) xhr.abort()
      root.goOffline()
    }
  }

  // After start/stop/restart the backend takes a few seconds to come up or
  // go away; poll briskly until it settles.
  Timer {
    id: settleTimer
    property int ticks: 0
    interval: 1200
    repeat: true
    onTriggered: {
      ticks += 1
      root.refresh()
      root.refreshService()
      var settled = root.pendingVerb === "stop" ? !root.online : root.online
      if (settled || ticks >= 20) {
        running = false
        ticks = 0
        root.pendingVerb = ""
      }
    }
  }

  onPanelOpenChanged: if (panelOpen) { refresh(); refreshService(); checkLocalInstall() }

  // An install takes minutes; look every 3 s for up to 30 minutes.
  Timer {
    id: installWatch
    property int ticks: 0
    interval: 3000
    repeat: true
    onTriggered: {
      ticks += 1
      root.refresh()
      root.refreshService()
      root.checkLocalInstall()
      if (ticks >= 600) { running = false; ticks = 0; root.pendingVerb = "" }
    }
  }

  FileView {
    path: root.stateRoot !== "" ? root.stateRoot + "/ui.json" : ""
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.uiPorts = Model.parseUiJson(text())
    onLoadFailed: root.uiPorts = null
  }

  // ── live step status (stream.py) ──
  function ensureStream() {
    if (!online || streamProcess.running) return
    streamProcess.command = ["python3", "-I", "-u", root.streamScript, root.apiUrl]
    streamProcess.running = true
  }

  // Stopping on purpose (offline, or a new URL) is not a failure: the exit
  // handler starts a fresh helper at once when CraftBot is online.
  property bool _streamStopping: false
  property int _retryDelay: 5000

  function stopStream() {
    streamRetry.stop()
    if (streamProcess.running) {
      _streamStopping = true
      streamProcess.running = false
    }
    stepStatus = ({})
  }

  function applyStream(line) {
    if (line.length > 4096) return
    var m
    try { m = JSON.parse(line) } catch (e) { return }
    if (!m || typeof m !== "object") return
    if (m.event === "connected") { _retryDelay = 5000; return }
    if (typeof m.sessionId !== "string" || !/^[A-Za-z0-9_-]{1,64}$/.test(m.sessionId)) return
    var next = {}
    for (var k in stepStatus) next[k] = stepStatus[k]
    var text = Model.clean(m.status, 160)
    if (text !== "") next[m.sessionId] = text
    else delete next[m.sessionId]
    stepStatus = next
  }

  onOnlineChanged: if (online) ensureStream(); else stopStream()
  onApiUrlChanged: { stopStream(); if (!_streamStopping) ensureStream() }

  // A dropped or refused socket is retried: 5 s, then doubling to a minute,
  // back to 5 s once a helper connects.
  Timer {
    id: streamRetry
    interval: root._retryDelay
    onTriggered: {
      root.ensureStream()
      root._retryDelay = Math.min(60000, root._retryDelay * 2)
    }
  }

  Process {
    id: streamProcess
    command: []
    stdout: SplitParser { onRead: function(line) { root.applyStream(line) } }
    stderr: StdioCollector { id: streamStderr; waitForEnd: true }
    onExited: function(exitCode) {
      root.stepStatus = ({})
      if (root._streamStopping) {
        root._streamStopping = false
        // Once the old process has fully gone.
        Qt.callLater(root.ensureStream)
        return
      }
      if (exitCode !== 0) console.warn("craftbot.status: stream.py exited " + exitCode + ": " + Model.clean(streamStderr.text, 200))  // i18n: ignore
      if (root.online) streamRetry.restart()
    }
  }

  // A plugin reload can tear this down mid-request; drop the request so its
  // callback never lands on the old instance.
  Component.onDestruction: {
    var xhr = _xhr
    _xhr = null
    if (xhr) xhr.abort()
    streamRetry.stop()
    if (streamProcess.running) streamProcess.running = false
  }

  Process {
    id: serviceProcess
    command: []
    stdout: StdioCollector { id: serviceStdout; waitForEnd: true; onStreamFinished: root._serviceOut = text }
    onExited: function(exitCode) { root.applyService(serviceStdout.text || root._serviceOut) }
  }

  Process {
    id: localProcess
    command: []
    onExited: function(exitCode) {
      root.localInstall = exitCode === 0
      root.localChecked = true
    }
  }

  Process {
    id: controlProcess
    command: []
    stderr: StdioCollector { id: controlStderr; waitForEnd: true }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.lastError = Model.clean(controlStderr.text, 140) || ("Exited with " + exitCode)  // i18n: ignore
        root.pendingVerb = ""
      } else {
        settleTimer.ticks = 0
        settleTimer.restart()
      }
      root.refreshService()
    }
  }
}
