// Builds docs/demo-score-report.json: an LCRD score for a synthetic borrower,
// computed with LCRD's activity-path rules (lucred-wallet-connect,
// backend/credit-score-api/index.js, October 2026). The profile below is made
// up; the method is LCRD's. Run: node script/demo-score.mjs
import fs from "node:fs"

const BORROWER = "0xfb3B44ce78De13e18Df55be0F92b94C7e5879dDc"

// Synthetic borrower profile: what LCRD's indexer would observe.
const profile = {
  distinctProtocols: 3, // e.g. a lending pool, an AMM, a savings vault
  meaningfulActions: 40,
  distinctActiveDays: 45,
  trackRecordDays: 150, // first to latest action
  yield: { distinctIncomeMonths: 8, realizedReturn: 0.08 }, // 8% realized on deposits
  distributions: null, // no payroll / mass-distribution claims
  rewards: { distinctClaimMonths: 2, totalClaimedUsd: 10 },
}

// ---- LCRD activity path (constants as in credit-score-api) ----
const bucket = (buckets, v) => buckets.find((b) => v <= b.max).pts
const CONSISTENCY = [{ max: 2, pts: 0 }, { max: 6, pts: 4 }, { max: 13, pts: 8 }, { max: 29, pts: 14 }, { max: 89, pts: 20 }, { max: Infinity, pts: 26 }]
const TENURE = [{ max: 7, pts: 0 }, { max: 30, pts: 3 }, { max: 90, pts: 7 }, { max: 180, pts: 11 }, { max: Infinity, pts: 15 }]

const breadth = Math.min(profile.distinctProtocols * 5, 15)
const volume = Math.min(profile.meaningfulActions, 25)
const consistency = bucket(CONSISTENCY, profile.distinctActiveDays)
const tenure = bucket(TENURE, profile.trackRecordDays)
const yieldPts = profile.yield
  ? 2 + Math.round(Math.min(1, profile.yield.distinctIncomeMonths / 8) * 5) + Math.round(Math.max(0, Math.min(1, profile.yield.realizedReturn / 0.2)) * 5)
  : 0
const distributionPts = 0 // none in this profile
const rewardPts = profile.rewards
  ? 1 + Math.round(Math.min(1, profile.rewards.distinctClaimMonths / 8) * 2) + Math.round(Math.min(1, profile.rewards.totalClaimedUsd / 50) * 1)
  : 0

const raw = breadth + volume + consistency + tenure + yieldPts + distributionPts + rewardPts
// Raw 8..93 is mapped onto 34..90 with a cubic curve: average records land low, strong ones high.
const t = Math.max(0, Math.min(1, (raw - 8) / (93 - 8)))
const score = Math.round(Math.max(34, Math.min(90, 34 + Math.pow(t, 3) * (90 - 34))))
const tier = score >= 67 ? "A" : "B"

const report = {
  schema: "lcrd-score-report/1",
  note: "Synthetic borrower profile for the public demo. No real person's data. Scored with LCRD's activity-path rules by script/demo-score.mjs.",
  subject: BORROWER,
  computedAt: "2026-10-14T21:00:00Z",
  model: "LCRD activity score v1",
  path: "activity",
  profile,
  components: [
    { name: "breadth", label: "Protocols used", points: breadth, max: 15 },
    { name: "volume", label: "Activity", points: volume, max: 25 },
    { name: "consistency", label: "Active days", points: consistency, max: 26 },
    { name: "tenure", label: "Track record", points: tenure, max: 15 },
    { name: "income", label: "Yield income", points: yieldPts, max: 12 },
    { name: "distribution", label: "Payroll / distributions", points: distributionPts, max: 6 },
    { name: "rewards", label: "Protocol rewards", points: rewardPts, max: 4 },
  ],
  raw,
  scaling: "score = 34 + ((raw - 8) / 85)^3 * 56, clamped to 34..90 (activity path)",
  score,
  tier,
  policy: { version: "lcrd-unsecured-2026-10", requestedLimitUsdc: "2.00", note: "Tier, APR and the maximum line are computed on-chain by CreditLine.quote(score, cycles)." },
}

fs.writeFileSync(new URL("../docs/demo-score-report.json", import.meta.url), JSON.stringify(report, null, 2) + "\n")
console.log(`raw ${raw} -> score ${score}, tier ${tier}`)
