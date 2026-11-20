.pragma library

// Pure helpers for the CraftBot status widget: validate the configured
// endpoints, and turn CraftBot's /api/state snapshot into the handful of
// bounded, plain-text fields the bar and panel show.
//
// The status derivation mirrors the CraftBot UI's own
// (frontend/src/hooks/useDerivedAgentStatus.ts), so the bar agrees with the
// mascot in the app: waiting > running a tool > thinking > working > idle.

var MAX_TEXT = 96
var MAX_SESSIONS = 8
var MAX_RUNNING = 4
var MAX_RESPONSE_CHARS = 8 * 1024 * 1024

// Plain, single-line, bounded. Control characters become spaces so nothing
// shaped like markup or escape sequences survives as structure; the QML side
// still renders every string with Text.PlainText.
function clean(value, max) {
  var s = value === undefined || value === null ? "" : String(value)
  s = s.replace(/[\u0000-\u001f\u007f-\u009f]+/g, " ").replace(/\s+/g, " ").trim()
  var limit = max || MAX_TEXT
  return s.length > limit ? s.substring(0, limit - 1) + "…" : s
}

// Only CraftBot on this machine: http on a loopback name with an explicit port.
function loopbackUrl(value, fallback) {
  var s = String(value === undefined || value === null ? "" : value).trim().replace(/\/+$/, "")
  var m = s.match(/^http:\/\/(127\.0\.0\.1|localhost|\[::1\]):(\d{1,5})$/)
  if (!m) return fallback
  var port = parseInt(m[2], 10)
  return port > 0 && port < 65536 ? s : fallback
}

function serviceName(value, fallback) {
  var s = String(value === undefined || value === null ? "" : value).trim()
  return /^[A-Za-z0-9@._-]{1,64}\.service$/.test(s) ? s : fallback
}

function num(value) {
  var n = Number(value)
  return isFinite(n) ? n : 0
}

function normalizeActionName(name) {
  return String(name || "").toLowerCase().replace(/[\s-]+/g, "_")
}

function isSendMessage(item) {
  return normalizeActionName(item && item.name) === "send_message"
}

// Never throws: anything unexpected yields { ok: false }.
function parseState(raw) {
  if (typeof raw !== "string" || raw.length === 0 || raw.length > MAX_RESPONSE_CHARS) return { ok: false }
  var data
  try { data = JSON.parse(raw) } catch (e) { return { ok: false } }
  if (!data || typeof data !== "object" || Array.isArray(data)) return { ok: false }
  return deriveStatus(data)
}

function deriveStatus(data) {
  var actions = Array.isArray(data.actions) ? data.actions : []
  var messages = Array.isArray(data.messages) ? data.messages : []
  var sessionsIn = Array.isArray(data.sessions) ? data.sessions : []
  var busyIn = Array.isArray(data.busySessions) ? data.busySessions : []

  var busy = {}
  for (var b = 0; b < busyIn.length && b < 64; b++) busy[String(busyIn[b])] = true


  // Live items, and the newest activity time (ms), as the UI computes them.
  var live = []
  var latestAt = 0
  for (var i = 0; i < actions.length && i < 1000; i++) {
    var a = actions[i]
    if (!a || typeof a !== "object") continue
    latestAt = Math.max(latestAt, num(a.createdAt), num(a.completedAt))
    if (a.status === "running" || a.status === "waiting") live.push(a)
  }

  var lastMessage = null
  for (var m = 0; m < messages.length && m < 2000; m++) {
    var msg = messages[m]
    if (msg && typeof msg === "object" && (!lastMessage || num(msg.timestamp) >= num(lastMessage.timestamp))) lastMessage = msg
  }

  var key = "idle"
  var running = []
  var waiting = false
  for (var w = 0; w < live.length; w++) if (live[w].status === "waiting") waiting = true
  if (waiting) {
    key = "waiting"
  } else {
    for (var r = 0; r < live.length; r++) {
      var item = live[r]
      if (item.itemType === "action" && item.status === "running" && !isSendMessage(item)) {
        var name = clean(item.name, 40)
        if (name !== "" && running.indexOf(name) === -1 && running.length < MAX_RUNNING) running.push(name)
      }
    }
    if (running.length > 0) key = "running"
    else if (live.length > 0) key = "thinking"
    else if (lastMessage && lastMessage.style === "user" && latestAt < num(lastMessage.timestamp) * 1000) key = "working"
    else if (busyIn.length > 0) key = "working"
  }

  // Per session: the newest message id, for unread as CraftBot's sidebar
  // decides it.
  var lastSeen = obj(data.lastSeenMessageIds)
  var newestMsg = {}
  for (var nm = 0; nm < messages.length && nm < 2000; nm++) {
    var mm0 = messages[nm]
    if (!mm0 || typeof mm0 !== "object" || mm0.sessionId === undefined) continue
    var sid0 = String(mm0.sessionId)
    if (!newestMsg[sid0] || num(mm0.timestamp) >= num(newestMsg[sid0].timestamp)) newestMsg[sid0] = mm0
  }

  var sessions = []
  for (var s = 0; s < sessionsIn.length && sessions.length < MAX_SESSIONS; s++) {
    var se = sessionsIn[s]
    if (!se || typeof se !== "object" || se.id === undefined) continue
    var id = String(se.id)
    if (!/^[A-Za-z0-9_-]{1,64}$/.test(id)) continue
    sessions.push({
      id: id,
      title: clean(se.title, 48) || id,
      type: /^[a-z_]{1,24}$/.test(String(se.type || "")) ? String(se.type) : "chat",
      busy: busy[id] === true,
      unread: !!newestMsg[id] && !!newestMsg[id].messageId && String(lastSeen[id] || "") !== String(newestMsg[id].messageId),
      lastActiveAt: clean(se.lastActiveAt, 32)
    })
  }
  // Busy first, then most recently active.
  sessions.sort(function(x, y) {
    if (x.busy !== y.busy) return x.busy ? -1 : 1
    return x.lastActiveAt < y.lastActiveAt ? 1 : x.lastActiveAt > y.lastActiveAt ? -1 : 0
  })

  // The most recent LLM request across sessions: its context size and cache hit.
  var lastRequest = null
  for (var q = 0; q < sessionsIn.length && q < 256; q++) {
    var sq = sessionsIn[q]
    var lr = sq && typeof sq === "object" ? sq.lastRequest : null
    if (!lr || typeof lr !== "object") continue
    if (lastRequest && num(lr.startedAt) <= lastRequest.at) continue
    lastRequest = {
      session: clean(sq.title, 48),
      input: count(lr.inputTokens),
      cached: count(lr.cachedTokens),
      provider: clean(lr.surface, 32),
      model: clean(lr.model, 64),
      at: num(lr.startedAt)
    }
  }

  var metrics = obj(data.dashboardMetrics)
  var mm = obj(metrics.model), tk = obj(metrics.token), us = obj(metrics.usage), co = obj(metrics.cost)
  var input = count(tk.input), output = count(tk.output)

  return {
    ok: true,
    agentName: clean(data.agentName, 32) || "CraftBot",
    version: clean(data.version, 24),
    key: key,
    running: running,
    busyCount: Math.min(busyIn.length, 64),
    sessions: sessions,
    provider: clean(mm.provider, 32) || (lastRequest ? lastRequest.provider : ""),
    model: clean(mm.modelName || mm.modelId, 64) || (lastRequest ? lastRequest.model : ""),
    tokens: {
      input: input,
      output: output,
      cached: Math.min(count(tk.cached), input),
      total: count(tk.total) || input + output
    },
    requests: { today: count(us.requestsToday), lastHour: count(us.requestsLastHour) },
    cost: { today: money(co.today), month: money(co.thisMonth), total: money(co.total) },
    lastRequest: lastRequest
  }
}

function obj(value) {
  return value && typeof value === "object" && !Array.isArray(value) ? value : {}
}

// Non-negative whole counts, capped well past anything real.
function count(value) {
  var n = Math.floor(num(value))
  return n < 0 ? 0 : Math.min(n, 1e15)
}

function money(value) {
  var n = num(value)
  return n < 0 ? 0 : Math.min(n, 1e9)
}

var PROVIDERS = {
  anthropic: "Anthropic", openai: "OpenAI", google: "Google", gemini: "Google Gemini",
  openrouter: "OpenRouter", ollama: "Ollama", deepseek: "DeepSeek", xai: "xAI", grok: "xAI",
  mistral: "Mistral", minimax: "MiniMax", moonshot: "Moonshot", kimi: "Moonshot",
  byteplus: "BytePlus", groq: "Groq", together: "Together AI", fireworks: "Fireworks",
  azure: "Azure OpenAI", bedrock: "Amazon Bedrock", vertex: "Google Vertex", lmstudio: "LM Studio",
  zai: "Z.ai", qwen: "Qwen", dashscope: "Alibaba DashScope"
}

// ── Finding CraftBot on disk ──

function safePath(s) {
  return typeof s === "string" && s.length > 1 && s.length <= 512 && s.charAt(0) === "/"
    && !/[\u0000-\u001f\u007f]/.test(s) && !/(^|\/)\.\.(\/|$)/.test(s)
}

// A folder setting: "~" expands to home; it must stay inside home and use only
// plain path characters (no spaces or shell/systemd special characters).
function homePath(value, home, fallback) {
  var s = String(value === undefined || value === null ? "" : value).trim().replace(/\/+$/, "")
  if (s === "") return fallback
  if (s === "~") s = home
  else if (s.indexOf("~/") === 0) s = home + s.substring(1)
  return safePath(s) && /^\/[A-Za-z0-9._\/+-]+$/.test(s) && home !== "" && s.indexOf(home + "/") === 0 ? s : fallback
}

// The install folder from the service's ExecStart (`--state-root=PATH`).
function stateRootFrom(execStart) {
  var m = /--state-root=([^\s;]+)/.exec(String(execStart || ""))
  return m && safePath(m[1]) ? m[1].replace(/\/+$/, "") : ""
}

// The running CraftBot's ports, from <state root>/ui.json.
function parseUiJson(text) {
  var d
  try { d = JSON.parse(String(text || "")) } catch (e) { return null }
  if (!d || typeof d !== "object") return null
  var backend = Math.floor(num(d.backend_port)), frontend = Math.floor(num(d.frontend_port))
  var ok = function(p) { return p > 0 && p < 65536 }
  return ok(backend) ? { backend: backend, frontend: ok(frontend) ? frontend : 0 } : null
}

// "/home/me/CraftBot" -> "~/CraftBot" for display.
function tildePath(path, home) {
  var s = String(path || "")
  return home !== "" && s.indexOf(home + "/") === 0 ? "~" + s.substring(home.length) : s
}

// Provider -> mark in assets/providers (copied from Omarchy's Agents plugin).
var PROVIDER_ICONS = {
  anthropic: "claude", claude: "claude", openai: "codex", azure: "codex",
  deepseek: "deepseek", xai: "grok", grok: "grok", moonshot: "kimi", kimi: "kimi",
  minimax: "minimax", ollama: "ollama", openrouter: "openrouter", qwen: "qwen",
  dashscope: "qwen", zai: "zai", zhipu: "zai", fireworks: "fireworks", mistral: "vibe"
}
// Marks that are white on dark ship a dark twin for light themes.
var LIGHT_TWINS = { codex: true, grok: true, kimi: true, minimax: true, ollama: true, openrouter: true, zai: true }

function providerIcon(id, lightSurface) {
  var name = PROVIDER_ICONS[String(id || "").toLowerCase().replace(/[^a-z0-9]/g, "")]
  if (!name) return ""
  return "assets/providers/" + name + (lightSurface && LIGHT_TWINS[name] ? "-light" : "") + ".svg"
}

function providerLabel(id) {
  var key = String(id || "").toLowerCase().replace(/[^a-z0-9]/g, "")
  if (key === "") return ""
  if (PROVIDERS[key]) return PROVIDERS[key]
  var s = String(id)
  return s.charAt(0).toUpperCase() + s.substring(1)
}

// 641341 -> "641.3K", 1250000 -> "1.25M"; fmt(value, decimals) localizes.
// `brief` drops the decimal from 100K up (legends: 462K, not 462.0K).
function compact(n, fmt, brief) {
  var v = count(n)
  var f = fmt || function(x, d) { return Number(x).toFixed(d) }
  if (v < 1000) return f(v, 0)
  if (v < 1e6) return f(v / 1e3, v < 1e4 ? 2 : brief && v >= 1e5 ? 0 : 1) + "K"
  if (v < 1e9) return f(v / 1e6, v < 1e7 ? 2 : 1) + "M"
  return f(v / 1e9, 2) + "B"
}

function percent(part, whole) {
  return whole > 0 ? Math.round(Math.min(1, Math.max(0, part / whole)) * 100) : 0
}

// "3m ago" style, short and language-neutral enough for a caption; the
// widget passes the translator for the words.
function ago(ms, nowMs, t) {
  var diff = Math.max(0, Math.round((num(nowMs) - num(ms)) / 1000))
  if (!ms) return ""
  if (diff < 45) return t("time.now")
  if (diff < 3600) return t("time.minutes").arg(Math.max(1, Math.round(diff / 60)))
  if (diff < 86400) return t("time.hours").arg(Math.round(diff / 3600))
  return t("time.days").arg(Math.round(diff / 86400))
}
