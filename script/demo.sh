#!/usr/bin/env bash
# Runs one full lending cycle on a deployed pool, with real USDC on Arc:
#   lender deposits -> underwriter opens a line backed by a score report hash
#   -> borrower draws -> borrower repays part, leaving a live loan.
#
# Uses cast, not forge script: Foundry's local EVM cannot simulate Arc's native
# USDC (calls into 0x3600… fail with OpcodeNotFound), so each transaction is
# sent as-is and executed by Arc itself.
#
#   POOL=0x... ./script/demo.sh   (reads DEPLOYER_, UNDERWRITER_ and BORROWER_PRIVATE_KEY from .env)
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

echo "route 2 (Stellar score, unsecured): underwriter submits score 71 -> tier A, 18.93%, 1 USDC line"
                                               send "$UNDERWRITER_PRIVATE_KEY" "$POOL" "setLine(address,uint8,uint128,bytes32)" "$BORROWER" 71 1000000 "$SCORE_REF"
echo "  borrower draws 0.50, repays 0.25";     send "$BORROWER_PRIVATE_KEY" "$POOL" "borrow(uint256)" 500000
                                               send "$BORROWER_PRIVATE_KEY" $USDC "approve(address,uint256)" "$POOL" 250000
                                               send "$BORROWER_PRIVATE_KEY" "$POOL" "repay(uint256)" 250000

echo "route 1 (liquidity, secured): the lender borrows against its own deposit, no score"
                                               send "$DEPLOYER_PRIVATE_KEY" "$POOL" "openSecuredLine()"
echo "  draws 0.50, repays 0.25";              send "$DEPLOYER_PRIVATE_KEY" "$POOL" "borrow(uint256)" 500000
                                               send "$DEPLOYER_PRIVATE_KEY" $USDC "approve(address,uint256)" "$POOL" 250000
                                               send "$DEPLOYER_PRIVATE_KEY" "$POOL" "repay(uint256)" 250000

echo "owed now (principal, interest):"
echo "  unsecured borrower: $(cast call "$POOL" "owed(address)(uint256,uint256)" "$BORROWER" --rpc-url "$RPC" | tr '\n' ' ')"
echo "  secured lender:     $(cast call "$POOL" "owed(address)(uint256,uint256)" "$(cast wallet address --private-key "$DEPLOYER_PRIVATE_KEY")" --rpc-url "$RPC" | tr '\n' ' ')"
