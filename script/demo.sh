#!/usr/bin/env bash
# Runs one full lending cycle on a deployed pool, with real USDC on Arc:
#   lender deposits -> underwriter opens a line backed by a score report hash
#   -> borrower draws -> borrower repays part, leaving a live loan.
#
# Uses cast, not forge script: Foundry's local EVM cannot simulate Arc's native
# USDC (calls into 0x3600… fail with OpcodeNotFound), so each transaction is
# sent as-is and executed by Arc itself.
#
#   POOL=0x... ./script/demo.sh        (reads DEPLOYER_/BORROWER_PRIVATE_KEY from .env)
set -euo pipefail
set -a; . ./.env; set +a

RPC=${ARC_RPC_URL:-https://rpc.mainnet.arc.io}
USDC=0x3600000000000000000000000000000000000000
BORROWER=$(cast wallet address --private-key "$BORROWER_PRIVATE_KEY")
# The line is justified by an off-chain score report; only its hash goes on-chain.
SCORE_REF=$(cast keccak "0x$(xxd -p docs/demo-score-report.json | tr -d '\n')")

# Public Arc RPCs are load-balanced and occasionally answer a single call with an error; retry.
send() {
  local key=$1; shift
  for attempt in 1 2 3; do
    if out=$(cast send "$@" --rpc-url "$RPC" --private-key "$key" --json 2>/dev/null); then
      echo "$out" | python3 -c 'import sys,json; r=json.load(sys.stdin); print(" ", r["transactionHash"], "status", int(r["status"], 16))'
      return 0
    fi
    sleep 2
  done
  echo "  failed after 3 attempts: $*" >&2; return 1
}

echo "score report hash: $SCORE_REF"
echo "lender: approve + deposit 3 USDC";       send "$DEPLOYER_PRIVATE_KEY" $USDC "approve(address,uint256)" "$POOL" 3000000
                                               send "$DEPLOYER_PRIVATE_KEY" "$POOL" "deposit(uint256)" 3000000
echo "underwriter: score 71 -> contract prices it (tier A, 18.93%), 2 USDC line"; send "$DEPLOYER_PRIVATE_KEY" "$POOL" "setLine(address,uint8,uint128,bytes32)" "$BORROWER" 71 2000000 "$SCORE_REF"
echo "gas money for the borrower: 0.10 USDC";  send "$DEPLOYER_PRIVATE_KEY" $USDC "transfer(address,uint256)" "$BORROWER" 100000
echo "borrower: draw 1 USDC";                  send "$BORROWER_PRIVATE_KEY" "$POOL" "borrow(uint256)" 1000000
echo "borrower: approve + repay 0.50 USDC";    send "$BORROWER_PRIVATE_KEY" $USDC "approve(address,uint256)" "$POOL" 500000
                                               send "$BORROWER_PRIVATE_KEY" "$POOL" "repay(uint256)" 500000
echo "owed now (principal, interest):"; cast call "$POOL" "owed(address)(uint256,uint256)" "$BORROWER" --rpc-url "$RPC"
