#!/usr/bin/env bash
# Rare manual actions. Lines are opened automatically by the underwriter service;
# these are the exceptions, run by whoever holds the relevant key.
#
#   ./script/admin.sh freeze  0xBorrower   # stop new draws (repayments stay open)   [underwriter key]
#   ./script/admin.sh seize   0xBorrower   # settle a defaulted secured line from the borrower's deposit [underwriter key]
#   ./script/admin.sh writeoff 0xBorrower  # recognise an unsecured loss          [underwriter key]
#   ./script/admin.sh underwriter 0xNew    # hand underwriting to another key     [owner key]
set -euo pipefail
set -a; . ./.env; set +a
RPC=${ARC_RPC_URL:-https://rpc.mainnet.arc.io}
POOL=${POOL:-0xF25d9f4be85688cE02b3190D14De573145F59EEf}
action=${1:?action}; target=${2:?address}
case "$action" in
  freeze)      cast send "$POOL" "freeze(address)" "$target" --rpc-url "$RPC" --private-key "$UNDERWRITER_PRIVATE_KEY" ;;
  seize)       cast send "$POOL" "seizeCollateral(address)" "$target" --rpc-url "$RPC" --private-key "$UNDERWRITER_PRIVATE_KEY" ;;
  writeoff)    cast send "$POOL" "writeOff(address)" "$target" --rpc-url "$RPC" --private-key "$UNDERWRITER_PRIVATE_KEY" ;;
  underwriter) cast send "$POOL" "setUnderwriter(address)" "$target" --rpc-url "$RPC" --private-key "$DEPLOYER_PRIVATE_KEY" ;;
  *) echo "unknown action: $action" >&2; exit 1 ;;
esac
