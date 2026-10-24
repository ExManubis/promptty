// PrompTTY's push relay: takes a sealed notice from a Mac and hands it to Apple's push service
// (APNs) for one phone. It holds the APNs signing key, which can't ship inside the app, and sees
// only a device token and ciphertext: the Mac seals each notice with a key only the phone has, and
// the phone's notification service extension opens it. It keeps nothing and logs no payloads.
//
// `handle` is the whole relay; `worker.js` runs it as a Cloudflare Worker, `server.js` as a Node
// service. Configuration (`env`):
//   APNS_KEY       the .p8 signing key's text (a secret)
//   APNS_KEY_ID    its key id
//   APNS_TEAM_ID   the Apple developer team
//   APNS_TOPIC     the app's bundle id (dev.promptty.PrompTTY2.phone)
//   RELAY_SECRET   optional: then only POST /push/<secret> is served

export const MAX_BODY = 4096

const HEX = /^[0-9a-f]{32,200}$/i
const BASE64 = /^[A-Za-z0-9+/]+={0,2}$/
const ENVIRONMENTS = new Set(['development', 'production'])

/** `send(environment, token, headers, payload)` → `{ status, reason? }` delivers to APNs. */
export async function handle(request, env, { send, now = () => Date.now() }) {
  const url = new URL(request.url)
  const path = env.RELAY_SECRET ? `/push/${env.RELAY_SECRET}` : '/push'
  if (url.pathname !== path) return json(404, { error: 'not found' })
  if (request.method !== 'POST') return json(405, { error: 'POST only' })
  const text = await request.text()
  if (text.length > MAX_BODY) return json(413, { error: 'too large' })

  let push
  try { push = JSON.parse(text) } catch { return json(400, { error: 'not JSON' }) }
  const problem = check(push)
  if (problem) return json(400, { error: problem })

  let jwt
  try { jwt = await providerToken(env, now()) } catch { return json(500, { error: 'the relay has no usable APNs key' }) }
  const headers = {
    authorization: `bearer ${jwt}`,
    'apns-topic': env.APNS_TOPIC,
    'apns-push-type': 'alert',
    'apns-priority': '10',
  }
  // What APNs (and the lock screen, if the extension can't open it) sees: a placeholder, the key's
  // id and the sealed notice.
  const payload = JSON.stringify({
    aps: { alert: { title: 'PrompTTY', body: 'Something on your Mac needs you' }, sound: 'default', 'mutable-content': 1 },
    k: push.keyID,
    s: push.sealed,
  })
  const result = await send(push.environment, push.token, headers, payload)
  if (result.status === 200) return json(200, { ok: true })
  // 410: the phone dropped the app or the token; the Mac forgets the device.
  const status = result.status === 410 ? 410 : result.status === 400 ? 400 : 502
  return json(status, { error: result.reason ?? `APNs answered ${result.status}` })
}

/** What's wrong with a push, or nothing. */
export function check(push) {
  if (!push || typeof push !== 'object') return 'not an object'
  if (typeof push.token !== 'string' || !HEX.test(push.token)) return 'token is not a device token'
  if (!ENVIRONMENTS.has(push.environment)) return 'environment is development or production'
  if (typeof push.keyID !== 'string' || push.keyID.length < 1 || push.keyID.length > 64) return 'keyID is missing'
  if (typeof push.sealed !== 'string' || !BASE64.test(push.sealed) || push.sealed.length > 3000) return 'sealed is not base64'
  return null
}

export function apnsHost(environment) {
  return environment === 'production' ? 'api.push.apple.com' : 'api.sandbox.push.apple.com'
}

// APNs wants a provider token (an ES256 JWT) refreshed at most every 20 minutes and at least
// every hour: one is kept for 40 minutes.
let cached = null

export async function providerToken(env, nowMs) {
  const iat = Math.floor(nowMs / 1000)
  if (cached && cached.keyID === env.APNS_KEY_ID && iat - cached.iat < 40 * 60) return cached.jwt
  const key = await crypto.subtle.importKey('pkcs8', pemBytes(env.APNS_KEY), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: env.APNS_KEY_ID }))
  const claims = base64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat }))
  // WebCrypto signs ECDSA as r‖s, which is JWS's form.
  const signature = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(`${header}.${claims}`))
  const jwt = `${header}.${claims}.${base64url(new Uint8Array(signature))}`
  cached = { keyID: env.APNS_KEY_ID, iat, jwt }
  return jwt
}

export function forgetProviderToken() {
  cached = null
}

function pemBytes(pem) {
  const body = String(pem).replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
  return Uint8Array.from(atob(body), (c) => c.charCodeAt(0))
}

function base64url(input) {
  const bytes = typeof input === 'string' ? new TextEncoder().encode(input) : input
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function json(status, body) {
  return new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } })
}
