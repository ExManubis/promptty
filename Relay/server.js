// The relay as a Node service (22+), for a server of your own: `node server.js`, configured by the
// environment variables `relay.js` lists, plus HOST (127.0.0.1) and PORT (8790). APNs needs HTTP/2,
// which Node's fetch doesn't speak, so this sends with `node:http2`.
import http from 'node:http'
import http2 from 'node:http2'
import { apnsHost, handle, MAX_BODY } from './relay.js'

const sessions = new Map()

function session(environment) {
  const host = apnsHost(environment)
  let current = sessions.get(host)
  if (!current || current.closed || current.destroyed) {
    current = http2.connect(`https://${host}`)
    current.on('error', () => sessions.delete(host))
    current.on('close', () => sessions.delete(host))
    sessions.set(host, current)
  }
  return current
}

function send(environment, token, headers, payload) {
  return new Promise((resolve) => {
    const stream = session(environment).request({ ':method': 'POST', ':path': `/3/device/${token}`, ...headers })
    let status = 0
    let body = ''
    stream.on('response', (h) => { status = h[':status'] })
    stream.on('data', (chunk) => { body += chunk })
    stream.on('end', () => {
      let reason
      try { reason = JSON.parse(body).reason } catch {}
      resolve({ status, reason })
    })
    stream.on('error', (error) => resolve({ status: 502, reason: error.code }))
    stream.end(payload)
  })
}

const server = http.createServer(async (req, res) => {
  const chunks = []
  let size = 0
  for await (const chunk of req) {
    size += chunk.length
    if (size > MAX_BODY) { res.writeHead(413).end(); return }
    chunks.push(chunk)
  }
  const request = new Request(`http://relay${req.url}`, {
    method: req.method,
    body: req.method === 'POST' ? Buffer.concat(chunks) : undefined,
  })
  const response = await handle(request, process.env, { send })
  res.writeHead(response.status, { 'content-type': 'application/json' }).end(await response.text())
  // Status only: never a token or a payload.
  console.log(new Date().toISOString(), req.method, response.status)
})

server.listen(Number(process.env.PORT ?? 8790), process.env.HOST ?? '127.0.0.1')
