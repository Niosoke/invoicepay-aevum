#!/usr/bin/env bash
# Full invoice cycle on QDay Aevum testnet, driven with cast.
# Prereqs: merchant + payer wallets funded (tQDAY for gas, tUSD8 for payer)
# and InvoicePay deployed. Set CONTRACT below after deployment.
set -euo pipefail

export PATH="$HOME/.foundry/bin:$PATH"
RPC="https://rpc-test.qday.info"
TUSD8="0x456569838f1d43009A91ebA4263147Afd7233483"
CONTRACT="${CONTRACT:?set CONTRACT to the deployed InvoicePay address}"
PW=$(cat keystore/password.txt)
MERCHANT=0x41747089c2bEd5AB8c1975ae3f42E59C294a3791
PAYER=0xa7f32e07Ad8612b4f59BE699Ef9B8190645e462B
AMOUNT=1000000 # 1 tUSD8 (6 decimals) — the faucet drip size
DUE=$(( $(date +%s) + 7*24*3600 ))
# The invoice is bound to a purchase order reference. Reuse of the same
# reference by the same merchant is rejected while the first invoice is
# not cancelled, so bump the number if you rerun against the same contract.
PO=$(cast keccak "PO 1042")

echo "== balances before =="
cast balance "$MERCHANT" --rpc-url "$RPC"
cast balance "$PAYER" --rpc-url "$RPC"
cast call "$TUSD8" "balanceOf(address)(uint256)" "$PAYER" --rpc-url "$RPC"

echo "== 1. merchant creates invoice =="
cast send "$CONTRACT" "createInvoice(address,uint256,uint256,string,bytes32)" \
  "$PAYER" "$AMOUNT" "$DUE" "Invoice 1, demo payment" "$PO" \
  --keystore keystore/merchant --password "$PW" --rpc-url "$RPC"

ID=$(cast call "$CONTRACT" "invoiceCount()(uint256)" --rpc-url "$RPC")
ID=$(( ID - 1 ))
echo "invoice id: $ID"

echo "== 1b. duplicate invoice for the same purchase order (must revert) =="
cast call "$CONTRACT" "createInvoice(address,uint256,uint256,string,bytes32)" \
  "$PAYER" "$AMOUNT" "$DUE" "Duplicate for PO 1042" "$PO" \
  --from "$MERCHANT" --rpc-url "$RPC" || echo "duplicate rejected as expected"

echo "== 2. payer approves tUSD8 =="
cast send "$TUSD8" "approve(address,uint256)" "$CONTRACT" "$AMOUNT" \
  --keystore keystore/payer --password "$PW" --rpc-url "$RPC"

echo "== 3. payer pays invoice =="
cast send "$CONTRACT" "payInvoice(uint256)" "$ID" \
  --keystore keystore/payer --password "$PW" --rpc-url "$RPC"

echo "== invoice state after =="
cast call "$CONTRACT" "getInvoice(uint256)((address,address,uint256,uint256,uint256,string,bytes32,uint8))" "$ID" --rpc-url "$RPC"
cast call "$TUSD8" "balanceOf(address)(uint256)" "$MERCHANT" --rpc-url "$RPC"
