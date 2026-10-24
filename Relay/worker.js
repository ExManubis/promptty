// The relay as a Cloudflare Worker (`wrangler deploy`); APNs over the Worker's fetch (HTTP/2).
import { apnsHost, handle } from './relay.js'

async function send(environment, token, headers, payload) {
  const response = await fetch(`https://${apnsHost(environment)}/3/device/${token}`, { method: 'POST', headers, body: payload })
  if (response.status === 200) return { status: 200 }
  const answer = await response.json().catch(() => ({}))
  return { status: response.status, reason: answer.reason }
}

export default {
  fetch: (request, env) => handle(request, env, { send }),
}
