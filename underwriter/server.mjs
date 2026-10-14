// LCRD automated underwriter for the Arc credit pool.
//
// A borrower proves they control an Arc wallet and a Stellar wallet (one
// signature from each), LCRD scores the Stellar wallet's on-chain history, and
// if the tier qualifies this service opens the line on Arc with its own
// underwriter key. The contract prices the line from the score and caps it by
// tier, so this key can never grant a cheaper or larger line than policy allows.
//
// Env: UNDERWRITER_PRIVATE_KEY, POOL, ARC_RPC_URL, SCORE_API, AUTO_MAX_LIMIT_USDC,
//      ALLOWED_ORIGINS (comma-separated), PORT, DATA_DIR
import http from "node:http"
import crypto from "node:crypto"
import fs from "node:fs"
import path from "node:path"
import { createPublicClient, createWalletClient, fallback, http as httpTransport, keccak256, parseAbi, parseUnits, toHex, verifyMessage, isAddress, getAddress } from "viem"
import { arc } from "viem/chains"
import { privateKeyToAccount } from "viem/accounts"

const env = (k, d) => process.env[k] ?? d
const POOL = getAddress(env("POOL"))
const SCORE_API = env("SCORE_API", "https://credit-score-api-d4jskyskga-uc.a.run.app")
const AUTO_MAX_LIMIT = parseUnits(env("AUTO_MAX_LIMIT_USDC", "1"), 6)
const ORIGINS = env("ALLOWED_ORIGINS", "https://lucredtech.github.io").split(",").map((s) => s.trim())
const DATA_DIR = env("DATA_DIR", "./data")
const MESSAGE_MAX_AGE_MS = 10 * 60 * 1000

const POOL_ABI = parseAbi([
  "function setLine(address borrower, uint8 score, uint128 limit, bytes32 scoreRef)",
  "function quote(uint8 score, uint32 cyclesCompleted) view returns (uint8 tier, uint32 aprBps, uint256 maxLimit)",
  "function history(address) view returns (uint32 repayments, uint32 cyclesCompleted, uint32 writeOffs, uint64 firstBorrowAt, uint64 lastRepaidAt, uint64 cycleStart, uint128 cyclePeak, uint128 totalBorrowed, uint128 totalRepaid)",
  "function underwriter() view returns (address)",
])

const account = privateKeyToAccount(env("UNDERWRITER_PRIVATE_KEY"))
const transport = fallback(arc.rpcUrls.default.http.map((u) => httpTransport(u, { timeout: 15_000, retryCount: 1 })))
const reader = createPublicClient({ chain: arc, transport })
const writer = createWalletClient({ chain: arc, transport, account })

fs.mkdirSync(path.join(DATA_DIR, "reports"), { recursive: true })
const LINKS_FILE = path.join(DATA_DIR, "links.json")
const links = fs.existsSync(LINKS_FILE) ? JSON.parse(fs.readFileSync(LINKS_FILE, "utf8")) : {} // stellar -> arc
const saveLinks = () => fs.writeFileSync(LINKS_FILE, JSON.stringify(links, null, 2))

// ---- Stellar (SEP-53) signature verification without the Stellar SDK ----

const B32 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
function base32Decode(s) {
  let bits = 0, value = 0
  const out = []
  for (const c of s) {
    const v = B32.indexOf(c)
    if (v < 0) throw new Error("bad base32")
    value = (value << 5) | v
    bits += 5
    if (bits >= 8) { out.push((value >>> (bits - 8)) & 0xff); bits -= 8 }
  }
  return Buffer.from(out)
}
function crc16xmodem(buf) {
  let crc = 0
  for (const b of buf) {
    crc ^= b << 8
    for (let i = 0; i < 8; i++) crc = crc & 0x8000 ? ((crc << 1) ^ 0x1021) & 0xffff : (crc << 1) & 0xffff
  }
  return crc
}
/** Raw ed25519 public key of a G… account address, or throws. */
function stellarPublicKey(g) {
  if (!/^G[A-Z2-7]{55}$/.test(g)) throw new Error("Stellar wallet must be a G… account address.")
  const raw = base32Decode(g)
  const payload = raw.subarray(0, 33)
  const checksum = raw.readUInt16LE(33)
  if (payload[0] !== 6 << 3 || crc16xmodem(payload) !== checksum) throw new Error("Invalid Stellar address checksum.")
  return payload.subarray(1)
}
/** G… address for a raw ed25519 public key (used by tests). */
export function stellarAddressFromRaw(raw) {
  const payload = Buffer.concat([Buffer.from([6 << 3]), raw])
  const crc = Buffer.alloc(2)
  crc.writeUInt16LE(crc16xmodem(payload))
  const bytes = Buffer.concat([payload, crc])
  let bits = 0, value = 0, out = ""
  for (const b of bytes) { value = (value << 8) | b; bits += 8; while (bits >= 5) { out += B32[(value >>> (bits - 5)) & 31]; bits -= 5 } }
  if (bits > 0) out += B32[(value << (5 - bits)) & 31]
  return out
}
/**
 * Verifies a Stellar wallet's signature over `message`. Current wallets follow SEP-53
 * (ed25519 over sha256("Stellar Signed Message:\n" + message)); some Freighter versions
 * signed sha256(message) or the raw message. Each variant still needs this key's signature
 * over this exact message, so accepting all three does not weaken the check.
 */
export function verifyStellarMessage(g, message, signature) {
  const key = crypto.createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: stellarPublicKey(g).toString("base64url") }, format: "jwk" })
  const sig = Buffer.from(signature, /^[0-9a-f]+$/i.test(signature) && signature.length === 128 ? "hex" : "base64")
  if (sig.length !== 64) return false
  const msg = Buffer.from(message, "utf8")
  const candidates = [
    crypto.createHash("sha256").update(Buffer.concat([Buffer.from("Stellar Signed Message:\n"), msg])).digest(),
    crypto.createHash("sha256").update(msg).digest(),
    msg,
  ]
  return candidates.some((data) => crypto.verify(null, data, key, sig))
}

// ---- the request ----

function parseMessage(message) {
  const m = /^LCRD credit on Arc\nArc wallet: (0x[0-9a-fA-F]{40})\nStellar wallet: (G[A-Z2-7]{55})\nIssued: (\S+)$/.exec(message ?? "")
  if (!m) throw new Error("Unrecognised message format.")
  const issued = Date.parse(m[3])
  if (!Number.isFinite(issued) || Math.abs(Date.now() - issued) > MESSAGE_MAX_AGE_MS) throw new Error("This request has expired. Please sign again.")
  return { arc: getAddress(m[1]), stellar: m[2] }
}

// ---- read-only Arc RPC relay ----
// Brave Shields blocks browser requests to the public Arc RPC endpoints
// (net::ERR_BLOCKED_BY_CLIENT). The app reads through this relay first, so it
// works with Shields on. Read methods only; transactions go from the user's wallet.
const RELAY_METHODS = new Set(["eth_chainId", "eth_blockNumber", "eth_call", "eth_getLogs", "eth_getBalance", "eth_getCode",
  "eth_getTransactionReceipt", "eth_getTransactionByHash", "eth_getBlockByNumber", "eth_getBlockByHash", "eth_estimateGas",
  "eth_gasPrice", "eth_maxPriorityFeePerGas", "eth_feeHistory", "net_version"])
const RELAY_UPSTREAMS = arc.rpcUrls.default.http
const relayHits = new Map() // ip -> [timestamps], per minute
function relayLimited(ip) {
  const now = Date.now()
  const hits = (relayHits.get(ip) ?? []).filter((t) => now - t < 60_000)
  hits.push(now)
  relayHits.set(ip, hits)
  return hits.length > 240
}
async function relay(raw) {
  const body = JSON.parse(raw)
  const calls = Array.isArray(body) ? body : [body]
  if (calls.length === 0 || calls.length > 20) throw new Error("Batch too large.")
  for (const c of calls) if (!RELAY_METHODS.has(c?.method)) throw new Error(`Method not allowed: ${c?.method}`)
  let lastErr
  for (const url of RELAY_UPSTREAMS) {
    try {
      const r = await fetch(url, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body), signal: AbortSignal.timeout(15_000) })
      if (r.ok) return await r.text()
      lastErr = new Error(`upstream ${r.status}`)
    } catch (e) { lastErr = e }
  }
  throw lastErr ?? new Error("no upstream")
}

const recent = new Map() // ip -> [timestamps]
function rateLimited(ip) {
  const now = Date.now()
  const hits = (recent.get(ip) ?? []).filter((t) => now - t < 60 * 60 * 1000)
  hits.push(now)
  recent.set(ip, hits)
  return hits.length > 6
}

let queue = Promise.resolve() // one on-chain write at a time (nonce order)

async function requestLine(body) {
  const { message, arcSignature, stellarSignature } = body
  const { arc: arcAddress, stellar } = parseMessage(message)
  if (!(await verifyMessage({ address: arcAddress, message, signature: arcSignature }))) throw new Error("The Arc wallet signature does not match.")
  if (!verifyStellarMessage(stellar, message, stellarSignature ?? "")) throw new Error("The Stellar wallet signature does not match.")
  if (links[stellar] && links[stellar] !== arcAddress) throw new Error("This Stellar wallet already backs another Arc wallet.")

  const res = await fetch(`${SCORE_API}/score?wallet=${stellar}`, { signal: AbortSignal.timeout(90_000) })
  const scored = await res.json().catch(() => ({}))
  if (!res.ok) throw new Error(scored.error ?? `Scoring failed (HTTP ${res.status}).`)
  const score = Math.max(0, Math.min(100, Math.round(Number(scored.score))))
  if (!Number.isFinite(score)) throw new Error("LCRD has no score for this wallet yet.")

  const history = await reader.readContract({ address: POOL, abi: POOL_ABI, functionName: "history", args: [arcAddress] })
  const [tier, aprBps, maxLimit] = await reader.readContract({ address: POOL, abi: POOL_ABI, functionName: "quote", args: [score, history[1]] })
  const result = { stellar, arc: arcAddress, score, tier: ["", "A", "B", "C"][tier], path: scored.path, aprBps: Number(aprBps) }
  if (maxLimit === 0n) {
    const reason = scored.path === "no-history"
      ? "LCRD found no DeFi history for this Stellar wallet, so there is nothing to score yet. You can still qualify through the pool: deposit USDC and borrow against it (secured line), which builds your on-chain record."
      : `Score ${score} (tier ${result.tier}). Unsecured credit needs tier A or a score of 55 or more in tier B. You can still qualify through the pool: deposit USDC and borrow against it (secured line), which builds your on-chain record.`
    return { ...result, eligible: false, reason }
  }

  const limit = maxLimit < AUTO_MAX_LIMIT ? maxLimit : AUTO_MAX_LIMIT
  const report = {
    schema: "lcrd-score-report/1",
    subject: { arc: arcAddress, stellar },
    linkProof: { message, arcSignature, stellarSignature },
    computedAt: new Date().toISOString(),
    source: `${SCORE_API}/score`,
    model: "LCRD Stellar score",
    path: scored.path,
    score,
    tier: result.tier,
    components: scored.components ?? [],
    reasons: scored.reasons ?? [],
    policy: { version: "lcrd-unsecured-2026-10", autoMaxLimitUsdc: Number(AUTO_MAX_LIMIT) / 1e6 },
  }
  const reportJson = JSON.stringify(report, null, 2) + "\n"
  const scoreRef = keccak256(toHex(reportJson))

  const write = async () => {
    const h = await writer.writeContract({ address: POOL, abi: POOL_ABI, functionName: "setLine", args: [arcAddress, score, limit, scoreRef] })
    await reader.waitForTransactionReceipt({ hash: h })
    return h
  }
  const pending = queue.catch(() => {}).then(write)
  queue = pending
  const hash = await pending

  fs.writeFileSync(path.join(DATA_DIR, "reports", `${scoreRef}.json`), reportJson)
  links[stellar] = arcAddress
  saveLinks()
  return { ...result, eligible: true, limit: Number(limit) / 1e6, scoreRef, txHash: hash, report: reportJson }
}

// ---- http ----

function send(res, status, body, origin) {
  const headers = { "content-type": "application/json", "cache-control": "no-store" }
  if (origin && ORIGINS.includes(origin)) Object.assign(headers, { "access-control-allow-origin": origin, "access-control-allow-headers": "content-type", "access-control-allow-methods": "GET, POST, OPTIONS", vary: "origin" })
  res.writeHead(status, headers)
  res.end(body === null ? "" : JSON.stringify(body))
}

const server = http.createServer(async (req, res) => {
  const origin = req.headers.origin
  const ip = (req.headers["x-forwarded-for"] ?? req.socket.remoteAddress ?? "").split(",")[0].trim()
  try {
    if (req.method === "OPTIONS") return send(res, 204, null, origin)
    if (req.method === "GET" && req.url === "/health") {
      const uw = await reader.readContract({ address: POOL, abi: POOL_ABI, functionName: "underwriter" })
      return send(res, 200, { ok: true, pool: POOL, underwriter: account.address, active: uw.toLowerCase() === account.address.toLowerCase(), autoMaxLimitUsdc: Number(AUTO_MAX_LIMIT) / 1e6 }, origin)
    }
    if (req.method === "POST" && req.url === "/chain") {
      if (relayLimited(ip)) return send(res, 429, { jsonrpc: "2.0", id: null, error: { code: -32005, message: "rate limited" } }, origin)
      let raw = ""
      for await (const chunk of req) { raw += chunk; if (raw.length > 64_000) return send(res, 413, { error: "Request too large." }, origin) }
      const text = await relay(raw)
      const headers = { "content-type": "application/json", "cache-control": "no-store" }
      if (origin && ORIGINS.includes(origin)) Object.assign(headers, { "access-control-allow-origin": origin, "access-control-allow-headers": "content-type", "access-control-allow-methods": "GET, POST, OPTIONS", vary: "origin" })
      res.writeHead(200, headers)
      return res.end(text)
    }
    if (req.method === "POST" && req.url === "/request-line") {
      if (rateLimited(ip)) return send(res, 429, { error: "Too many requests. Try again later." }, origin)
      let raw = ""
      for await (const chunk of req) { raw += chunk; if (raw.length > 8_000) return send(res, 413, { error: "Request too large." }, origin) }
      const out = await requestLine(JSON.parse(raw || "{}"))
      console.log(new Date().toISOString(), "request-line", out.stellar, "->", out.arc, "score", out.score, out.eligible ? `line ${out.limit} tx ${out.txHash}` : "not eligible")
      return send(res, 200, out, origin)
    }
    send(res, 404, { error: "Not found" }, origin)
  } catch (err) {
    console.error(new Date().toISOString(), err.shortMessage ?? err.message)
    send(res, 400, { error: err.shortMessage ?? err.message }, origin)
  }
})

if (!isAddress(POOL)) throw new Error("POOL is not set")
if (env("PORT") !== "0") server.listen(Number(env("PORT", 8080)), () => console.log(`underwriter ${account.address} for pool ${POOL} on :${env("PORT", 8080)}`))
