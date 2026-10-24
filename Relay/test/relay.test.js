import assert from 'node:assert/strict'
import { beforeEach, test } from 'node:test'
import { forgetProviderToken, handle } from '../relay.js'

const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
const pkcs8 = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64')
const env = {
  APNS_KEY: `-----BEGIN PRIVATE KEY-----\n${pkcs8.match(/.{1,64}/g).join('\n')}\n-----END PRIVATE KEY-----\n`,
  APNS_KEY_ID: 'ABC123DEFG',
  APNS_TEAM_ID: 'RQ2CW4W282',
  APNS_TOPIC: 'dev.promptty.PrompTTY2.phone',
}
const token = 'ab'.repeat(32)
const push = { token, environment: 'development', keyID: 'K1', sealed: Buffer.from('ciphertext and tag').toString('base64') }

function post(body, path = '/push') {
  return new Request(`https://relay.example${path}`, { method: 'POST', body: typeof body === 'string' ? body : JSON.stringify(body) })
}

function fakeAPNs(status = 200, reason) {
  const sent = []
  return { sent, send: async (...args) => { sent.push(args); return { status, reason } } }
}

beforeEach(() => forgetProviderToken())

test('hands the sealed notice to APNs for the token, signed with the provider token', async () => {
  const apns = fakeAPNs()
  const response = await handle(post(push), env, apns)
  assert.equal(response.status, 200)
  const [[environment, to, headers, payload]] = apns.sent
  assert.equal(environment, 'development')
  assert.equal(to, token)
  assert.equal(headers['apns-topic'], env.APNS_TOPIC)
  assert.equal(headers['apns-push-type'], 'alert')
  const sent = JSON.parse(payload)
  assert.equal(sent.aps['mutable-content'], 1)
  assert.equal(sent.k, 'K1')
  assert.equal(sent.s, push.sealed)

  const [header, claims, signature] = headers.authorization.replace('bearer ', '').split('.')
  const decode = (part) => JSON.parse(Buffer.from(part, 'base64url').toString())
  assert.deepEqual(decode(header), { alg: 'ES256', kid: env.APNS_KEY_ID })
  assert.equal(decode(claims).iss, env.APNS_TEAM_ID)
  const valid = await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pair.publicKey,
    Buffer.from(signature, 'base64url'), new TextEncoder().encode(`${header}.${claims}`))
  assert.ok(valid)
})

test('keeps its provider token for a while, then makes a new one', async () => {
  const apns = fakeAPNs()
  let now = 1_800_000_000_000
  await handle(post(push), env, { ...apns, now: () => now })
  now += 10 * 60_000
  await handle(post(push), env, { ...apns, now: () => now })
  now += 45 * 60_000
  await handle(post(push), env, { ...apns, now: () => now })
  const tokens = apns.sent.map(([, , headers]) => headers.authorization)
  assert.equal(tokens[0], tokens[1])
  assert.notEqual(tokens[1], tokens[2])
})

test('refuses what is not a sealed push for a device', async () => {
  const apns = fakeAPNs()
  for (const bad of [
    'not json',
    { ...push, token: 'not-a-token' },
    { ...push, environment: 'staging' },
    { ...push, keyID: '' },
    { ...push, sealed: 'plain text, not base64!' },
  ]) {
    assert.equal((await handle(post(bad), env, apns)).status, 400, JSON.stringify(bad))
  }
  assert.equal((await handle(post('x'.repeat(5000)), env, apns)).status, 413)
  assert.equal((await handle(new Request('https://relay.example/push'), env, apns)).status, 405)
  assert.equal((await handle(post(push, '/other'), env, apns)).status, 404)
  assert.equal(apns.sent.length, 0)
})

test('with a secret, serves only its path', async () => {
  const apns = fakeAPNs()
  const secret = { ...env, RELAY_SECRET: 's3cret' }
  assert.equal((await handle(post(push), secret, apns)).status, 404)
  assert.equal((await handle(post(push, '/push/wrong'), secret, apns)).status, 404)
  assert.equal((await handle(post(push, '/push/s3cret'), secret, apns)).status, 200)
})

test("passes on a token APNs doesn't know any more, so the Mac forgets the device", async () => {
  const gone = await handle(post(push), env, fakeAPNs(410, 'Unregistered'))
  assert.equal(gone.status, 410)
  assert.deepEqual(await gone.json(), { error: 'Unregistered' })
  assert.equal((await handle(post(push), env, fakeAPNs(500, 'InternalServerError'))).status, 502)
})

test('says so when its key is missing', async () => {
  assert.equal((await handle(post(push), { ...env, APNS_KEY: '' }, fakeAPNs())).status, 500)
})
