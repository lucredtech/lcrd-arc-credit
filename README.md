# LCRD Credit Line on Arc

Unsecured USDC credit lines on Arc mainnet, priced on-chain from an LCRD credit score, with every repayment recorded and rewarded.

- **Contract:** [`0xA801A7529C76414c811d954DdDD05Ceb63F75D8C`](https://explorer.arc.io/address/0xA801A7529C76414c811d954DdDD05Ceb63F75D8C) on Arc mainnet, deployed in block 25979163
- **App:** https://lucredtech.github.io/lcrd-arc-credit/
- **Chain:** Arc mainnet (5042), USDC `0x3600000000000000000000000000000000000000`

## Why Arc

Lending to people and small businesses in USDC needs fees that are predictable in dollars, a dollar the borrower already holds, and settlement fast enough to feel like a payment. On Arc, gas is paid in USDC, so a borrower who only has USDC can draw and repay with no second token, and every cost in the app is a dollar amount.

## How it works

```
LCRD (off-chain)                         Arc (CreditLine.sol)
financial activity ──► score 0-100 ──►   setLine(borrower, score, limit, scoreRef)
                                           │  quote(score, cycles) → tier, APR, max line
lenders ── deposit USDC ── shares          ▼
                                         borrower ── borrow / repay in USDC
                                           │  every repayment recorded in history(borrower)
                                           ▼  completed cycle → APR −0.5%, line can grow
```

### 1. The score, off-chain

LCRD scores a borrower's real financial behaviour from 0 to 100: completed borrow-and-repay cycles where they exist, otherwise activity (protocols used, volume, active days, length of track record) plus income signals. The report is hashed with keccak-256 and only the hash (`scoreRef`) goes on-chain, so no personal data is on Arc, but anyone shown the report can check it is the one the line was based on.

### 2. The price, on-chain

The underwriter submits the score; the contract derives everything else with LCRD's published policy (`POLICY_VERSION = "lcrd-unsecured-2026-10"`), so no borrower can be quoted a different rate:

| | |
|---|---|
| Tier | A = 67–100, B = 34–66, C = 0–33 |
| APR | 8% cost of funds + score premium (20% at score 0 sliding to 3% at score 100) + 3% unsecured surcharge − 0.5% per completed cycle (max 2%), kept within 6–36% |
| Line | Starter: A 100 USDC, B 75 USDC, C none (unsecured lines are for A and B only). Grows by one starter amount per completed cycle, up to 2,500 (A) / 250 (B) |

Example: score 71 → tier A, 8% + 7.93% + 3% = **18.93%**. Anyone can price any score with `quote(score, cyclesCompleted)`.

### 3. Repayments build credit

`history(borrower)` records repayments, total borrowed and repaid, completed cycles, write-offs, and first-borrow and last-repay times. A cycle completes when a loan that used at least 25% of the line and ran at least 7 days is repaid in full (so dust loans cannot farm it). The contract then lowers that line's APR automatically and emits `CycleCompleted`; the underwriter can raise the limit up to the new maximum. A write-off resets completed cycles.

### Lenders

Lenders deposit USDC and receive pool shares. Their yield is the interest borrowers repay, shared pro rata: the pool is worth its cash plus principal still lent out, and repaid interest raises every share. Idle USDC earns nothing, so yield depends on how much of the pool is lent. Loans are **unsecured**: there is no collateral, so a written-off line lowers share value. That is why lines start small and only grow with a repayment record.

### Other details

Interest accrues by the second; repayments go to interest first, then principal, and never take more than is owed. Anyone can repay on a borrower's behalf (`repayFor`). The underwriter can freeze a line (no new draws, repayments still open) or write it off. Ownership transfers in two steps. USDC on Arc has one balance with two views (18 decimals natively, 6 through the ERC-20 interface at `0x3600…`); the contract only uses the ERC-20 interface and never mixes it with `msg.value`.

## The demo on mainnet

`script/demo.sh` runs a full cycle with real USDC: a lender deposits 3 USDC; the underwriter submits score 71 for a demo borrower, and the contract prices it at tier A, 18.93%, for a 2 USDC line, backed by the hash of [`docs/demo-score-report.json`](docs/demo-score-report.json): a synthetic borrower profile (not a real person) scored with LCRD's actual activity-path rules by [`script/demo-score.mjs`](script/demo-score.mjs), raw 82 → score 71; the borrower draws 1 USDC and repays 0.50, leaving a live loan on the page. The repayment is in the borrower's on-chain history, and repaying the rest after 7 days completes their first cycle.

The line's `scoreRef` on-chain is `0x9b5448e8cdf6475cc57e8675be8a936543894f3318cc0f65902334eff111a4d0`, the keccak-256 of the report file:

```bash
cast keccak "0x$(xxd -p docs/demo-score-report.json | tr -d '\n')"
```

The script uses `cast` rather than `forge script`: Foundry's local EVM cannot simulate Arc's native USDC (calls into `0x3600…` fail with `OpcodeNotFound`), so each transaction is sent as-is and executed by Arc. Deploying is unaffected, because the constructor never calls USDC.

Earlier versions ran full cycles too: v1 `0x2b77cf6BE10A5cC32c77aD10C06076ed06BdA7db` (manual APR; a loan repaid in full with interest, then the pool closed) and v2 `0x9A470662c7B32Ad79Bb236A54e25319a526a28cf` (on-chain pricing without history).

## Run it

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge test
```

28 tests, including LCRD's exact prices and tier boundaries, a fuzz test that a better score never costs more, cycle rules (dust loans and quick repays do not count, write-offs reset), a fuzz test that repayment never takes more than is owed, and a check against first-depositor share inflation.

Deploy (fund the deployer with a little USDC on Arc for gas):

```bash
cp .env.example .env   # set DEPLOYER_PRIVATE_KEY
forge script script/Deploy.s.sol --rpc-url arc --broadcast
POOL=0x... ./script/demo.sh   # optional: one real lending cycle
```

Then put the address and deployment block in `web/src/config.js`, run `npm install && npm run build` to bundle the app into `web/app.bundle.js` (no CDN at runtime), and serve `web/` as a static site. The app reads the pool straight from Arc and lets any wallet lend, withdraw, borrow (with a line) and repay.

## Built on

LCRD's off-chain credit scoring is existing work from Lucred. This repo, the contract, tests, scripts and app, was written for Arc.

## Licence

MIT
