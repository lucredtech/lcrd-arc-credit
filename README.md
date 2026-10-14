# LCRD Credit Line on Arc

A USDC lending pool on Arc mainnet with underwritten, per-borrower credit lines backed by LCRD credit scores.

- **Contract:** [`0x2b77cf6BE10A5cC32c77aD10C06076ed06BdA7db`](https://explorer.arc.io/address/0x2b77cf6BE10A5cC32c77aD10C06076ed06BdA7db) on Arc mainnet, deployed in block 25975885
- **App:** https://lucredtech.github.io/lcrd-arc-credit/
- **Chain:** Arc mainnet (5042), USDC `0x3600000000000000000000000000000000000000`

## Why Arc

Lending to people and small businesses in USDC needs three things a general-purpose chain makes awkward: fees that are predictable in dollars, a dollar the borrower already holds, and settlement fast enough to feel like a payment. On Arc, gas is paid in USDC, so a borrower who has only USDC can draw and repay with no second token, and every cost in the app is a dollar amount.

## How it works

```
LCRD (off-chain)                     Arc (CreditLine.sol)
bank / wallet activity ──► score ──► setLine(borrower, limit, APR, tier, scoreRef)
                                       ▲                      │
lenders ── deposit USDC ── shares ─────┘                      ▼
                                     borrower ── borrow / repay in USDC
```

- **Lenders** deposit USDC and receive pool shares. The pool is worth its cash plus principal still lent out. Interest raises the share value once it is repaid; a written-off line lowers it.
- **The underwriter** opens a line per borrower: a limit, a simple APR, a risk tier from 1 to 5, and `scoreRef`, the keccak-256 hash of the LCRD score report that justified the limit. The report itself stays off-chain, so no personal data is on Arc, but anyone given the report can check it is the one the line was based on.
- **Borrowers** draw up to their limit while the pool has cash, and repay in USDC. Interest accrues by the second; repayments go to interest first, then principal, and never take more than is owed. Anyone can repay on a borrower's behalf (`repayFor`): an employer, a guarantor, or a payment app.
- **Risk controls:** the underwriter can freeze a line (no new draws, repayments still open) or write it off. Ownership transfers in two steps.

USDC on Arc has one balance with two views: 18 decimals natively and 6 through the ERC-20 interface at `0x3600…`. The contract only uses the ERC-20 interface, as Arc's docs recommend for application logic, and never mixes it with `msg.value`.

## The demo on mainnet

`script/demo.sh` runs a full cycle with real USDC: a lender deposits 3 USDC, the underwriter opens a 2 USDC line at 12% for a demo borrower, backed by the hash of [`docs/demo-score-report.json`](docs/demo-score-report.json) (a synthetic report, not a real person), and the borrower draws 1 USDC and repays 0.50, leaving a live loan that accrues interest on the page.

It ran on mainnet on 14 October 2026. The demo borrower is `0xfb3B44ce78De13e18Df55be0F92b94C7e5879dDc`; the line's `scoreRef` on-chain is `0xd88854915e1b20e54efbd902dad359e5a399ec4b86793066f15f75e604c418b6`, the keccak-256 of the report file, which you can check with:

```bash
cast keccak "0x$(xxd -p docs/demo-score-report.json | tr -d '\n')"
```

The script uses `cast` rather than `forge script`: Foundry's local EVM cannot simulate Arc's native USDC (calls into `0x3600…` fail with `OpcodeNotFound`), so each transaction is sent as-is and executed by Arc. Deploying is unaffected, because the constructor never calls USDC.

## Run it

Requires [Foundry](https://book.getfoundry.sh/).

```bash
forge test
```

16 tests, including a fuzz test that repayment never takes more than is owed and a check against first-depositor share inflation.

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
