import { createPublicClient, createWalletClient, custom, fallback, formatUnits, http, keccak256, parseAbi, parseUnits, toHex } from "viem"
import { arc } from "viem/chains"
import { CONTRACT, DEPLOY_BLOCK } from "./config.js"

const USDC = "0x3600000000000000000000000000000000000000" // native USDC, ERC-20 interface (6 decimals)
const EXPLORER = "https://explorer.arc.io"

const POOL_ABI = parseAbi([
  "function cash() view returns (uint256)",
  "function totalAssets() view returns (uint256)",
  "function totalPrincipal() view returns (uint256)",
  "function totalRepaidInterest() view returns (uint256)",
  "function totalShares() view returns (uint256)",
  "function convertToAssets(uint256) view returns (uint256)",
  "function sharesOf(address) view returns (uint256)",
  "function underwriter() view returns (address)",
  "function borrowerCount() view returns (uint256)",
  "function borrowers(uint256) view returns (address)",
  "function lines(address) view returns (uint128 limit, uint128 principal, uint128 interest, uint32 aprBps, uint8 tier, uint8 score, bool active, uint64 lastAccrued, bytes32 scoreRef)",
  "function history(address) view returns (uint32 repayments, uint32 cyclesCompleted, uint32 writeOffs, uint64 firstBorrowAt, uint64 lastRepaidAt, uint64 cycleStart, uint128 cyclePeak, uint128 totalBorrowed, uint128 totalRepaid)",
  "function quote(uint8 score, uint32 cyclesCompleted) view returns (uint8 tier, uint32 aprBps, uint256 maxLimit)",
  "function owed(address) view returns (uint256 principal, uint256 interest)",
  "function available(address) view returns (uint256)",
  "function deposit(uint256 assets) returns (uint256)",
  "function withdraw(uint256 shares) returns (uint256)",
  "function borrow(uint256 amount)",
  "function repay(uint256 amount) returns (uint256)",
  "function setLine(address borrower, uint8 score, uint128 limit, bytes32 scoreRef)",
  "function freeze(address borrower)",
  "error NotOwner()", "error NotUnderwriter()", "error NotPendingOwner()", "error Reentrancy()", "error ZeroAmount()",
  "error ZeroAddress()", "error BadScore()", "error TierNotEligible()", "error LineInactive()", "error OverLimit()",
  "error InsufficientLiquidity()", "error InsufficientShares()", "error NothingOwed()", "error TransferFailed()",
  "event Deposited(address indexed lender, uint256 assets, uint256 shares)",
  "event Withdrawn(address indexed lender, uint256 assets, uint256 shares)",
  "event LineSet(address indexed borrower, uint256 limit, uint8 score, uint8 tier, uint256 aprBps, bytes32 scoreRef)",
  "event CycleCompleted(address indexed borrower, uint32 cyclesCompleted, uint256 newAprBps)",
  "event LineFrozen(address indexed borrower)",
  "event Borrowed(address indexed borrower, uint256 amount)",
  "event Repaid(address indexed borrower, address indexed payer, uint256 interestPaid, uint256 principalPaid)",
  "event WrittenOff(address indexed borrower, uint256 principal, uint256 interest)",
])
const ERC20_ABI = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address owner, address spender) view returns (uint256)",
  "function approve(address spender, uint256 amount) returns (bool)",
])

// Every public Arc mainnet RPC, tried in order: if one is blocked by a browser
// shield, a network or a rate limit, reads move on to the next. Contract reads
// are batched into Multicall3 calls to keep the request count low.
const RPCS = arc.rpcUrls.default.http
const reader = createPublicClient({
  chain: arc,
  transport: fallback(RPCS.map((url) => http(url, { timeout: 12_000, retryCount: 0 })), { retryCount: 1 }),
  batch: { multicall: { wait: 16 } },
})
let wallet = null
let account = null

const $ = (id) => document.getElementById(id)
const usd = (v, dp = 2) => Number(formatUnits(v, 6)).toLocaleString("en", { minimumFractionDigits: dp, maximumFractionDigits: 6 })
const short = (a) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "")
const link = (kind, v, text) => `<a class="mono" href="${EXPLORER}/${kind}/${v}" target="_blank" rel="noopener">${text ?? short(v)}</a>`
const TIER = { 1: "A", 2: "B", 3: "C" }
const pct = (bps) => `${(Number(bps) / 100).toFixed(2)}%`
const asLine = (t) => ({ limit: t[0], principal: t[1], interest: t[2], aprBps: t[3], tier: t[4], score: t[5], active: t[6], lastAccrued: t[7], scoreRef: t[8] })
const asHistory = (t) => ({ repayments: t[0], cycles: t[1], writeOffs: t[2], firstBorrowAt: t[3], lastRepaidAt: t[4], cycleStart: t[5], cyclePeak: t[6], borrowed: t[7], repaid: t[8] })
const read = (functionName, args = []) => reader.readContract({ address: CONTRACT, abi: POOL_ABI, functionName, args })
const status = (msg) => { $("status").innerHTML = msg }
const setEnabled = (act, on, why) => { const b = document.querySelector(`[data-act="${act}"]`); const input = b.previousElementSibling; b.disabled = !on; b.title = on ? "" : why; if (input?.tagName === "INPUT") input.disabled = !on }
const banner = (msg) => { const b = $("banner"); b.textContent = msg; b.hidden = !msg }
const setLink = (el, href, text) => { el.href = href; el.textContent = text }

async function loadPool() {
  const [assets, cash, out, interest, shares, underwriter, block] = await Promise.all([
    read("totalAssets"), read("cash"), read("totalPrincipal"), read("totalRepaidInterest"), read("totalShares"), read("underwriter"), reader.getBlockNumber(),
  ])
  $("s-assets").textContent = usd(assets)
  $("s-cash").textContent = usd(cash)
  $("s-out").textContent = usd(out)
  $("s-int").textContent = usd(interest, 6)
  // One USDC deposited at launch mints about 1e12 shares; this is what that stake is worth now.
  $("s-share").textContent = shares > 0n ? (Number(await read("convertToAssets", [10n ** 12n])) / 1e6).toFixed(6) : "1.000000"
  setLink($("contract"), `${EXPLORER}/address/${CONTRACT}`, short(CONTRACT))
  setLink($("underwriter"), `${EXPLORER}/address/${underwriter}`, short(underwriter))
  $("block").textContent = block.toLocaleString("en")
}

async function loadLines() {
  const n = Number(await read("borrowerCount"))
  const body = $("lines").querySelector("tbody")
  if (!n) { body.innerHTML = `<tr><td colspan="10" class="empty">No credit lines yet.</td></tr>`; return }
  const addrs = await Promise.all([...Array(n).keys()].map((i) => read("borrowers", [BigInt(i)])))
  const rows = await Promise.all(addrs.map(async (a) => ({ a, l: asLine(await read("lines", [a])), h: asHistory(await read("history", [a])), o: await read("owed", [a]) })))
  body.innerHTML = rows.map(({ a, l, h, o }) => `<tr>
    <td>${link("address", a)}</td>
    <td class="num">${l.score}</td>
    <td><span class="tag">${TIER[l.tier]}</span></td>
    <td class="num">${usd(l.limit)}</td>
    <td class="num">${pct(l.aprBps)}</td>
    <td class="num">${usd(o[0])}</td>
    <td class="num">${usd(o[1], 6)}</td>
    <td class="num" title="${usd(h.borrowed)} borrowed · ${usd(h.repaid, 6)} repaid">${h.repayments} · ${h.cycles} cycle${h.cycles === 1 ? "" : "s"}</td>
    <td class="mono" title="${l.scoreRef}">${short(l.scoreRef)}</td>
    <td>${l.active ? '<span class="tag ok">active</span>' : '<span class="tag warn">frozen</span>'}</td>
  </tr>`).join("")
}

async function loadActivity() {
  const latest = await reader.getBlockNumber()
  const logs = []
  // Query in windows so a long-lived pool does not hit RPC range limits.
  for (let from = BigInt(DEPLOY_BLOCK); from <= latest; from += 50_000n) {
    const to = from + 49_999n < latest ? from + 49_999n : latest
    logs.push(...(await reader.getContractEvents({ address: CONTRACT, abi: POOL_ABI, fromBlock: from, toBlock: to })))
  }
  const body = $("activity").querySelector("tbody")
  if (!logs.length) { body.innerHTML = `<tr><td colspan="5" class="empty">No activity yet.</td></tr>`; return }
  body.innerHTML = logs.reverse().slice(0, 25).map((e) => {
    const a = e.args
    const who = a.lender ?? a.borrower
    const amount = a.assets ?? a.amount ?? a.limit ?? (a.principalPaid !== undefined ? a.principalPaid + a.interestPaid : a.principal)
    return `<tr><td>${Number(e.blockNumber).toLocaleString("en")}</td><td>${e.eventName}</td><td>${who ? link("address", who) : ""}</td><td class="num">${amount !== undefined ? usd(amount) : ""}</td><td>${link("tx", e.transactionHash)}</td></tr>`
  }).join("")
}

async function loadMe() {
  if (!account) return
  const [shares, lineT, histT, owedNow, avail, bal] = await Promise.all([
    read("sharesOf", [account]), read("lines", [account]), read("history", [account]), read("owed", [account]), read("available", [account]),
    reader.readContract({ address: USDC, abi: ERC20_ABI, functionName: "balanceOf", args: [account] }),
  ])
  const line = asLine(lineT)
  const h = asHistory(histT)
  $("my-shares").textContent = shares.toLocaleString("en")
  $("my-worth").textContent = shares > 0n ? `${usd(await read("convertToAssets", [shares]))} USDC` : "0 USDC"
  const hasLine = line.lastAccrued > 0n
  const owes = owedNow[0] + owedNow[1]
  $("my-line").textContent = hasLine ? `${usd(line.limit)} USDC at ${pct(line.aprBps)}${line.active ? "" : " · frozen"}` : "No credit line yet"
  $("my-score").textContent = hasLine ? `${line.score} / 100 · tier ${TIER[line.tier]}` : "–"
  $("my-history").textContent = hasLine ? `${h.repayments} repayment${h.repayments === 1 ? "" : "s"} · ${h.cycles} completed cycle${h.cycles === 1 ? "" : "s"}` : "–"
  $("my-owed").textContent = owes > 0n ? `${usd(owes, 6)} USDC` : "Nothing — you owe 0 USDC"
  $("my-avail").textContent = `${usd(avail)} USDC`

  // What the next completed cycle earns, priced by the contract itself.
  if (hasLine && line.tier < 3) {
    const [, nextApr, nextMax] = await read("quote", [line.score, h.cycles + 1])
    const minDraw = (line.limit + 3n) / 4n
    $("my-next").textContent = nextApr < line.aprBps
      ? `Borrow at least ${usd(minDraw)} USDC, keep it 7+ days, repay in full: APR drops to ${pct(nextApr)} and your line can grow to ${usd(nextMax, 0)} USDC.`
      : `Borrow at least ${usd(minDraw)} USDC, keep it 7+ days, repay in full: your line can grow to ${usd(nextMax, 0)} USDC.`
  } else {
    $("my-next").textContent = ""
  }

  // Only offer what this wallet can actually do.
  const canBorrow = line.active && avail > 0n
  setEnabled("borrow", canBorrow, hasLine ? (line.active ? "Nothing left to draw on this line" : "Line frozen") : "Lines are opened by the underwriter after an LCRD credit check")
  setEnabled("repay", owes > 0n, "Nothing to repay")
  $("borrow-note").textContent = canBorrow ? "" : hasLine ? (line.active ? "Your line is fully drawn or the pool is empty." : "This line is frozen: repayments only.") : "This wallet has no credit line. Lines are opened by the underwriter after an LCRD credit check."
  if (owes > 0n) $("repay-amt").placeholder = `up to ${usd(owes, 6)} USDC`
  $("connect").textContent = `${short(account)} · ${usd(bal)} USDC`
  const uw = await read("underwriter")
  $("uw-card").hidden = uw.toLowerCase() !== account.toLowerCase()
}

let refreshCount = 0
async function refresh() {
  try {
    refreshCount++
    await Promise.all([loadPool(), loadLines(), refreshCount % 2 === 1 ? loadActivity() : null, loadMe()])
    banner("")
  } catch (err) {
    console.error(err)
    const where = err?.url ? ` via ${new URL(err.url).host}` : ""
    banner(`Could not read the pool from Arc${where} (${err.shortMessage ?? err.message}). Tried ${RPCS.length} public Arc RPCs. If you use Brave, try turning Shields off for this site; the page retries every 30 seconds.`)
  }
}

// Wallets announce themselves through EIP-6963; fall back to window.ethereum.
const announced = []
window.addEventListener("eip6963:announceProvider", (e) => announced.push(e.detail))
window.dispatchEvent(new Event("eip6963:requestProvider"))
const pickProvider = () => announced.find((p) => /metamask|rabby|brave|coinbase|okx/i.test(p.info?.name ?? ""))?.provider ?? announced[0]?.provider ?? window.ethereum

let provider = null

const CONTRACT_ERRORS = {
  LineInactive: "This wallet has no active credit line. Lines are opened by the underwriter after an LCRD credit check.",
  OverLimit: "That is more than allowed: above the line when borrowing, or above the tier's maximum when opening a line.",
  InsufficientLiquidity: "The pool does not have that much USDC available right now.",
  NothingOwed: "This wallet has nothing to repay.",
  InsufficientShares: "You do not have that many shares.",
  NotUnderwriter: "Only the underwriter wallet can open or freeze lines.",
  BadScore: "The LCRD score must be a whole number from 0 to 100.",
  TierNotEligible: "Scores below 34 (tier C) do not qualify for an unsecured line under LCRD policy.",
  ZeroAmount: "Enter an amount above zero.",
  ZeroAddress: "Enter a valid wallet address.",
}

function walletError(err) {
  const name = err?.walk?.((e) => e?.data?.errorName)?.data?.errorName ?? err?.data?.errorName
  if (name && CONTRACT_ERRORS[name]) return CONTRACT_ERRORS[name]
  if (err?.code === 4001 || err?.cause?.code === 4001) return "Request rejected in your wallet."
  if (err?.code === -32002) return "Your wallet already has a request open. Open the wallet extension to continue."
  return err?.shortMessage ?? err?.message ?? String(err)
}

async function connect() {
  provider = pickProvider()
  if (!provider) throw new Error("No browser wallet found. Install MetaMask or Rabby, or use a wallet's built-in browser on mobile.")
  const btn = $("connect")
  btn.textContent = "Connecting…"
  try {
    ;[account] = await provider.request({ method: "eth_requestAccounts" })
    const chainId = `0x${arc.id.toString(16)}`
    try {
      await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] })
    } catch (err) {
      if (err?.code === 4001) throw err
      // Not added yet (MetaMask says 4902; other wallets use other codes): add, then switch.
      await provider.request({ method: "wallet_addEthereumChain", params: [{ chainId, chainName: "Arc", nativeCurrency: arc.nativeCurrency, rpcUrls: [arc.rpcUrls.default.http[0]], blockExplorerUrls: [EXPLORER] }] })
      await provider.request({ method: "wallet_switchEthereumChain", params: [{ chainId }] }).catch(() => {})
    }
    wallet = createWalletClient({ chain: arc, transport: custom(provider), account })
    provider.on?.("accountsChanged", (a) => { account = a[0]; wallet = account ? createWalletClient({ chain: arc, transport: custom(provider), account }) : null; refresh() })
    await loadMe()
  } catch (err) {
    btn.textContent = "Connect wallet"
    throw err
  }
}

async function send(functionName, args, label) {
  // Simulate first, so a revert comes back as a named contract error rather than a wallet gas-estimation failure.
  const { request } = await reader.simulateContract({ account, address: CONTRACT, abi: POOL_ABI, functionName, args })
  status(`${label}: confirm in your wallet…`)
  const hash = await wallet.writeContract(request)
  status(`${label}: sent ${link("tx", hash)}, waiting…`)
  await reader.waitForTransactionReceipt({ hash })
  status(`${label}: done ${link("tx", hash)}`)
}

async function ensureAllowance(amount) {
  const allowance = await reader.readContract({ address: USDC, abi: ERC20_ABI, functionName: "allowance", args: [account, CONTRACT] })
  if (allowance >= amount) return
  status("Approve USDC: confirm in your wallet…")
  const hash = await wallet.writeContract({ address: USDC, abi: ERC20_ABI, functionName: "approve", args: [CONTRACT, amount] })
  await reader.waitForTransactionReceipt({ hash })
}

const amountOf = (id) => {
  const v = $(id).value.trim()
  if (!v || Number(v) <= 0) throw new Error("Enter an amount in USDC.")
  return parseUnits(v, 6)
}

const actions = {
  async deposit() { const a = amountOf("lend-amt"); await ensureAllowance(a); await send("deposit", [a], "Deposit") },
  async withdraw() { const s = await read("sharesOf", [account]); if (!s) throw new Error("You have no shares."); await send("withdraw", [s], "Withdraw") },
  async borrow() {
    const a = amountOf("borrow-amt")
    const line = await read("lines", [account])
    if (!line[5]) throw new Error(CONTRACT_ERRORS.LineInactive)
    const avail = await read("available", [account])
    if (a > avail) throw new Error(`You can draw up to ${usd(avail)} USDC right now.`)
    await send("borrow", [a], "Borrow")
  },
  async repay() {
    const [p, i] = await read("owed", [account])
    if (p + i === 0n) throw new Error(CONTRACT_ERRORS.NothingOwed)
    let a = amountOf("repay-amt")
    if (a > p + i) a = p + i + 1n // accrual between now and inclusion; the contract never takes more than is owed
    await ensureAllowance(a)
    await send("repay", [a], "Repay")
  },
  async setline() {
    const who = $("uw-addr").value.trim()
    if (!/^0x[0-9a-fA-F]{40}$/.test(who)) throw new Error(CONTRACT_ERRORS.ZeroAddress)
    const score = Number($("uw-score").value)
    if (!Number.isInteger(score) || score < 0 || score > 100) throw new Error(CONTRACT_ERRORS.BadScore)
    const limit = amountOf("uw-limit")
    let ref = $("uw-ref").value.trim()
    if (!ref) ref = keccak256(toHex(`lcrd-score-report:${who.toLowerCase()}:${score}:${new Date().toISOString()}`))
    if (!/^0x[0-9a-fA-F]{64}$/.test(ref)) throw new Error("Score reference must be a 32-byte hex hash (0x + 64 hex characters), or leave it empty.")
    await send("setLine", [who, score, limit, ref], "Open line")
  },
  async freeze() {
    const who = $("uw-addr").value.trim()
    if (!/^0x[0-9a-fA-F]{40}$/.test(who)) throw new Error(CONTRACT_ERRORS.ZeroAddress)
    await send("freeze", [who], "Freeze line")
  },
}

$("connect").addEventListener("click", () => connect().catch((e) => { status(walletError(e)); banner(walletError(e)) }))
document.querySelectorAll("[data-act]").forEach((b) => b.addEventListener("click", async () => {
  b.disabled = true
  try {
    if (!wallet) await connect()
    await actions[b.dataset.act]()
    await refresh()
  } catch (e) {
    status(walletError(e))
  } finally {
    b.disabled = false
    if (account) loadMe().catch(() => {}) // re-apply what this wallet can do
  }
}))

refresh()
setInterval(refresh, 30_000)

// Underwriter panel: price the score live, using the contract's own quote().
async function previewQuote() {
  const score = Number($("uw-score").value)
  if (!Number.isInteger(score) || score < 0 || score > 100) { $("uw-quote").textContent = "Enter a score from 0 to 100."; return }
  const who = $("uw-addr").value.trim()
  const cycles = /^0x[0-9a-fA-F]{40}$/.test(who) ? asHistory(await read("history", [who])).cycles : 0
  const [tier, apr, maxLimit] = await read("quote", [score, cycles])
  $("uw-quote").textContent = maxLimit === 0n
    ? `Tier ${TIER[tier]}: not eligible for an unsecured line.`
    : `Tier ${TIER[tier]} · APR ${pct(apr)} · line up to ${usd(maxLimit, 0)} USDC${cycles ? ` (with ${cycles} completed cycle${cycles === 1 ? "" : "s"})` : ""}`
}
for (const id of ["uw-score", "uw-addr"]) $(id).addEventListener("input", () => previewQuote().catch(() => {}))
previewQuote().catch(() => {})
