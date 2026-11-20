// node tests/model.test.mjs [path/to/state.json]
import fs from 'node:fs'
import vm from 'node:vm'
import assert from 'node:assert/strict'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const here = path.dirname(fileURLToPath(import.meta.url))
const src = fs.readFileSync(path.join(here, '..', 'Model.js'), 'utf8').replace(/^\.pragma library\s*$/m, '')
const M = {}
vm.createContext(M)
vm.runInContext(src, M)
String.prototype.arg = function (v) { return this.replace('%1', String(v)) }

const base = (over = {}) => JSON.stringify({
  agentName: 'CraftBot', version: '1.4.4', agentState: 'idle',
  busySessions: [], sessions: [{ id: 'main', type: 'main', title: 'Main', lastActiveAt: '2026-11-19T10:00:00' }],
  messages: [], actions: [], ...over,
})

let n = 0
const test = (name, fn) => { fn(); n++; console.log('ok', name) }

test('idle by default', () => {
  const s = M.parseState(base())
  assert.equal(s.ok, true); assert.equal(s.key, 'idle'); assert.equal(s.agentName, 'CraftBot')
})

test('waiting beats running', () => {
  const s = M.parseState(base({ actions: [
    { itemType: 'action', name: 'Web search', status: 'running', createdAt: 1 },
    { itemType: 'action', name: 'Ask user', status: 'waiting', createdAt: 2 },
  ] }))
  assert.equal(s.key, 'waiting')
})

test('running names, send_message excluded', () => {
  const s = M.parseState(base({ actions: [
    { itemType: 'action', name: 'Send message', status: 'running', createdAt: 1 },
    { itemType: 'action', name: 'Web search', status: 'running', createdAt: 2 },
  ] }))
  assert.equal(s.key, 'running'); assert.deepEqual([...s.running], ['Web search'])
})

test('only send_message or reasoning running is thinking', () => {
  assert.equal(M.parseState(base({ actions: [{ itemType: 'reasoning', name: 'Reasoning', status: 'running' }] })).key, 'thinking')
  assert.equal(M.parseState(base({ actions: [{ itemType: 'action', name: 'send-message', status: 'running' }] })).key, 'thinking')
})

test('user message with no activity since is working', () => {
  const s = M.parseState(base({ messages: [{ style: 'user', timestamp: 2000 }], actions: [{ itemType: 'action', name: 'x', status: 'completed', createdAt: 1000 }] }))
  assert.equal(s.key, 'working')
  const t = M.parseState(base({ messages: [{ style: 'user', timestamp: 1 }], actions: [{ itemType: 'action', name: 'x', status: 'completed', createdAt: 5000 }] }))
  assert.equal(t.key, 'idle')
})

test('busy session alone is working', () => {
  assert.equal(M.parseState(base({ busySessions: ['main'] })).key, 'working')
})

test('markup and control characters come out flat and bounded', () => {
  const evil = '<img src="https://example.invalid/t">\u001b[31m' + 'A'.repeat(500)
  const s = M.parseState(base({ agentName: evil, sessions: [{ id: 'main', title: evil }], actions: [{ itemType: 'action', name: evil, status: 'running' }] }))
  for (const v of [s.agentName, s.sessions[0].title, s.running[0]]) {
    assert.ok(!/[\u0000-\u001f]/.test(v)); assert.ok(v.length <= 48)
  }
})

test('bad ids and garbage are dropped; garbage input never throws', () => {
  const s = M.parseState(base({ sessions: [{ id: '../../etc', title: 'x' }, { id: 'ok_1', title: 'y' }] }))
  assert.deepEqual([...s.sessions.map(x => x.id)], ['ok_1'])
  for (const raw of ['', 'null', '[]', '{', '"x"', 'x'.repeat(9 * 1024 * 1024)]) assert.equal(M.parseState(raw).ok, false)
})

test('endpoint validation is loopback-only', () => {
  assert.equal(M.loopbackUrl('http://127.0.0.1:7926/', 'F'), 'http://127.0.0.1:7926')
  assert.equal(M.loopbackUrl('http://localhost:7925', 'F'), 'http://localhost:7925')
  for (const bad of ['https://evil.example:7926', 'http://127.0.0.1', 'http://127.0.0.1:7926/x', 'http://127.0.0.1.evil.com:80', 'file:///etc/passwd'])
    assert.equal(M.loopbackUrl(bad, 'F'), 'F')
  assert.equal(M.serviceName('craftbot.service', 'F'), 'craftbot.service')
  assert.equal(M.serviceName('x; rm -rf ~.service', 'F'), 'F')
})

test('provider, model, token totals and last request', () => {
  const s = M.parseState(base({
    dashboardMetrics: {
      model: { provider: 'anthropic', modelId: 'claude-sonnet-5-5', modelName: 'claude-sonnet-5-5' },
      token: { input: 611423, output: 29918, cached: 462022, total: 641341 },
      usage: { requestsToday: 12, requestsLastHour: 3 },
      cost: { today: 0.5, thisMonth: 4.25, total: 9 },
    },
    sessions: [
      { id: 'a', title: 'Old', lastRequest: { inputTokens: 1000, cachedTokens: 10, startedAt: 1, surface: 'openai', model: 'gpt' } },
      { id: 'b', title: 'New', lastRequest: { inputTokens: 27830, cachedTokens: 21962, startedAt: 2, surface: 'anthropic', model: 'claude-sonnet-5-5' } },
    ],
  }))
  assert.equal(s.provider, 'anthropic'); assert.equal(s.model, 'claude-sonnet-5-5')
  assert.equal(s.tokens.total, 641341); assert.equal(s.tokens.cached, 462022)
  assert.equal(s.requests.today, 12); assert.equal(s.cost.month, 4.25)
  assert.equal(s.lastRequest.session, 'New'); assert.equal(s.lastRequest.input, 27830)
  assert.equal(M.providerLabel('anthropic'), 'Anthropic'); assert.equal(M.providerLabel('openai'), 'OpenAI')
  assert.equal(M.providerLabel('somenew'), 'Somenew'); assert.equal(M.providerLabel(''), '')
  assert.equal(M.compact(641341), '641.3K'); assert.equal(M.compact(1250000), '1.25M'); assert.equal(M.compact(950), '950'); assert.equal(M.compact(462022, undefined, true), '462K'); assert.equal(M.compact(29918, undefined, true), '29.9K')
  assert.equal(M.percent(462022, 611423), 76)
})

test('missing metrics fall back to the last request; bad numbers are clamped', () => {
  const s = M.parseState(base({
    dashboardMetrics: { token: { input: -5, output: 'x', cached: 999 }, cost: { total: -3 } },
    sessions: [{ id: 'b', title: 'B', lastRequest: { inputTokens: 10, startedAt: 1, surface: 'openrouter', model: 'some/model' } }],
  }))
  assert.equal(s.provider, 'openrouter'); assert.equal(s.model, 'some/model')
  assert.equal(s.tokens.input, 0); assert.equal(s.tokens.output, 0); assert.equal(s.tokens.cached, 0)
  assert.equal(s.cost.total, 0)
  assert.equal(M.parseState(base()).lastRequest, null)
})

test('session unread and provider icons', () => {
  const s = M.parseState(base({
    sessions: [{ id: 'a', title: 'A' }, { id: 'b', title: 'B' }, { id: 'c', title: 'C' }],
    busySessions: ['a'],
    lastSeenMessageIds: { a: 'm2', b: 'm3' },
    messages: [
      { sessionId: 'a', messageId: 'm1', timestamp: 1 }, { sessionId: 'a', messageId: 'm2', timestamp: 2 },
      { sessionId: 'b', messageId: 'm3', timestamp: 3 }, { sessionId: 'b', messageId: 'm4', timestamp: 4 },
    ],
    actions: [
      { itemType: 'reasoning', sessionId: 'a', createdAt: 1, output: 'old thought' },
      { itemType: 'reasoning', sessionId: 'a', createdAt: 5, output: 'Reading the <b>config</b>\nthen editing it' },
      { itemType: 'action', sessionId: 'a', createdAt: 6, name: 'Read file', output: '{"status":"ok"}' },
    ],
  }))
  const by = Object.fromEntries(s.sessions.map(x => [x.id, x]))
  assert.equal(by.a.busy, true); assert.equal(by.a.unread, false)
  assert.equal(by.b.unread, true); assert.equal(by.c.unread, false)
  assert.equal(M.providerIcon('anthropic', false), 'assets/providers/claude.svg')
  assert.equal(M.providerIcon('openai', true), 'assets/providers/codex-light.svg')
  assert.equal(M.providerIcon('anthropic', true), 'assets/providers/claude.svg')
  assert.equal(M.providerIcon('../../etc', false), '')
})

test('install folder, state root, and ui.json ports', () => {
  const H = '/home/me'
  assert.equal(M.homePath('', H, H + '/CraftBot'), '/home/me/CraftBot')
  assert.equal(M.homePath('~/apps/CraftBot/', H, 'F'), '/home/me/apps/CraftBot')
  for (const bad of ['/etc', '~/../root', '/home/me/a/../../x', 'relative/dir', '/home/meX/y', '~/a\nb'])
    assert.equal(M.homePath(bad, H, 'F'), 'F', bad)
  const exec = 'ExecStart={ path=/x/python3 ; argv[]=/x/python3 /home/me/Work/CraftBot/run.py --no-open-browser --service --state-root=/home/me/Work/CraftBot ; ignore_errors=no }'
  assert.equal(M.stateRootFrom(exec), '/home/me/Work/CraftBot')
  assert.equal(M.stateRootFrom('ExecStart={ argv[]=python3 run.py }'), '')
  assert.equal(M.stateRootFrom('--state-root=relative/x'), '')
  assert.deepEqual({ ...M.parseUiJson('{"url":"http://localhost:7927","frontend_port":7927,"backend_port":7928}') }, { backend: 7928, frontend: 7927 })
  assert.equal(M.parseUiJson('{"backend_port":0}'), null)
  assert.equal(M.parseUiJson('nope'), null)
  assert.equal(M.tildePath('/home/me/CraftBot', H), '~/CraftBot')
})

const live = process.argv[2]
if (live) {
  const s = M.parseState(fs.readFileSync(live, 'utf8'))
  assert.equal(s.ok, true)
  console.log('live:', JSON.stringify({ key: s.key, agentName: s.agentName, version: s.version, sessions: s.sessions.length, provider: s.provider, model: s.model, icon: M.providerIcon(s.provider, false), sessions: s.sessions.map(x => ({ t: x.title, busy: x.busy, unread: x.unread })) }))
}
console.log(`${n} tests passed`)
