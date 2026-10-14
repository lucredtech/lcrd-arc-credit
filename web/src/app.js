import { createPublicClient, createWalletClient, custom, fallback, formatUnits, http, parseAbi, parseUnits } from "viem"
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
  "function lines(address) view returns (uint128 limit, uint128 principal, uint128 interest, uint32 aprBps, uint8 tier, bool active, uint64 lastAccrued, bytes32 scoreRef)",
  "function owed(address) view returns (uint256 principal, uint256 interest)",
  "function available(address) view returns (uint256)",
  "function deposit(uint256 assets) returns (uint256)",
  "function withdraw(uint256 shares) returns (uint256)",
  "function borrow(uint256 amount)",
  "function repay(uint256 amount) returns (uint256)",
  "event Deposited(address indexed lender, uint256 assets, uint256 shares)",
  "event Withdrawn(address indexed lender, uint256 assets, uint256 shares)",
  "event LineSet(address indexed borrower, uint256 limit, uint256 aprBps, uint8 tier, bytes32 scoreRef)",
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
const read = (functionName, args = []) => reader.readContract({ address: CONTRACT, abi: POOL_ABI, functionName, args })
const status = (msg) => { $("status").innerHTML = msg }
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
  if (!n) { body.innerHTML = `<tr><td colspan="8" class="empty">No credit lines yet.</td></tr>`; return }
  const addrs = await Promise.all([...Array(n).keys()].map((i) => read("borrowers", [BigInt(i)])))
  const rows = await Promise.all(addrs.map(async (a) => ({ a, l: await read("lines", [a]), o: await read("owed", [a]) })))
  body.innerHTML = rows.map(({ a, l, o }) => `<tr>
    <td>${link("address", a)}</td>
    <td><span class="tag">tier ${l[4]}</span></td>
    <td class="num">${usd(l[0])}</td>
    <td class="num">${(Number(l[3]) / 100).toFixed(2)}%</td>
    <td class="num">${usd(o[0])}</td>
    <td class="num">${usd(o[1], 6)}</td>
    <td class="mono" title="${l[7]}">${short(l[7])}</td>
    <td>${l[5] ? '<span class="tag ok">active</span>' : '<span class="tag warn">frozen</span>'}</td>
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
  const [shares, line, owedNow, avail, bal] = await Promise.all([
    read("sharesOf", [account]), read("lines", [account]), read("owed", [account]), read("available", [account]),
    reader.readContract({ address: USDC, abi: ERC20_ABI, functionName: "balanceOf", args: [account] }),
  ])
  $("my-shares").textContent = shares.toLocaleString("en")
  $("my-worth").textContent = shares > 0n ? `${usd(await read("convertToAssets", [shares]))} USDC` : "0 USDC"
  $("my-line").textContent = line[6] > 0n ? `${usd(line[0])} USDC · ${(Number(line[3]) / 100).toFixed(2)}% · tier ${line[4]}${line[5] ? "" : " · frozen"}` : "no line"
  $("my-owed").textContent = `${usd(owedNow[0] + owedNow[1], 6)} USDC`
  $("my-avail").textContent = `${usd(avail)} USDC`
  $("connect").textContent = `${short(account)} · ${usd(bal)} USDC`
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

function walletError(err) {
  if (err?.code === 4001) return "Request rejected in your wallet."
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
  status(`${label}: confirm in your wallet…`)
  const hash = await wallet.writeContract({ address: CONTRACT, abi: POOL_ABI, functionName, args })
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
  async borrow() { await send("borrow", [amountOf("borrow-amt")], "Borrow") },
  async repay() { const a = amountOf("repay-amt"); await ensureAllowance(a); await send("repay", [a], "Repay") },
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
  }
}))

refresh()
setInterval(refresh, 30_000)
