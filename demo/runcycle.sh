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
CAP=1000000 # 1 tUSD8 approved total (6 decimals) — the faucet drip size
HALF=500000 # 0.5 tUSD8 per installment
DUE=$(( $(date +%s) + 7*24*3600 ))
EXPIRY=$(( $(date +%s) + 30*24*3600 ))
# The invoices settle a purchase order the payer approved on chain. The
# approval caps the total, so bump the number if you rerun against the
# same contract once the cap is settled. Each invoice also names the
# milestone it bills; a milestone can be billed only once per purchase
# order, so the resubmission below must revert.
PO=$(cast keccak "PO 1042")
M1=$(cast keccak "PO 1042 milestone 1")
M2=$(cast keccak "PO 1042 milestone 2")

echo "== balances before =="
cast balance "$MERCHANT" --rpc-url "$RPC"
cast balance "$PAYER" --rpc-url "$RPC"
cast call "$TUSD8" "balanceOf(address)(uint256)" "$PAYER" --rpc-url "$RPC"

echo "== 1. payer approves the purchase order for the merchant =="
cast send "$CONTRACT" "approvePurchaseOrder(address,bytes32,uint256,uint256)" \
  "$MERCHANT" "$PO" "$CAP" "$EXPIRY" \
  --keystore keystore/payer --password "$PW" --rpc-url "$RPC"

echo "== 2. merchant creates installment 1 (milestone 1) =="
cast send "$CONTRACT" "createInvoice(address,uint256,uint256,string,bytes32,bytes32)" \
  "$PAYER" "$HALF" "$DUE" "Invoice 1, milestone 1" "$PO" "$M1" \
  --keystore keystore/merchant --password "$PW" --rpc-url "$RPC"

echo "== 3. merchant creates installment 2 (milestone 2, same amount) =="
cast send "$CONTRACT" "createInvoice(address,uint256,uint256,string,bytes32,bytes32)" \
  "$PAYER" "$HALF" "$DUE" "Invoice 2, milestone 2" "$PO" "$M2" \
  --keystore keystore/merchant --password "$PW" --rpc-url "$RPC"

COUNT=$(cast call "$CONTRACT" "invoiceCount()(uint256)" --rpc-url "$RPC")
ID2=$(( COUNT - 1 ))
ID1=$(( COUNT - 2 ))
echo "invoice ids: $ID1 and $ID2"

echo "== 4. resubmitted milestone 1 (must revert) =="
cast call "$CONTRACT" "createInvoice(address,uint256,uint256,string,bytes32,bytes32)" \
  "$PAYER" "$HALF" "$DUE" "Milestone 1 again for PO 1042" "$PO" "$M1" \
  --from "$MERCHANT" --rpc-url "$RPC" || echo "resubmitted milestone rejected as expected"

echo "== 5. payer approves tUSD8 =="
cast send "$TUSD8" "approve(address,uint256)" "$CONTRACT" "$CAP" \
  --keystore keystore/payer --password "$PW" --rpc-url "$RPC"

echo "== 6. payer pays both installments =="
cast send "$CONTRACT" "payInvoice(uint256)" "$ID1" \
  --keystore keystore/payer --password "$PW" --rpc-url "$RPC"
cast send "$CONTRACT" "payInvoice(uint256)" "$ID2" \
  --keystore keystore/payer --password "$PW" --rpc-url "$RPC"

echo "== invoice, purchase order and milestone state after =="
cast call "$CONTRACT" "getInvoice(uint256)((address,address,uint256,uint256,uint256,string,bytes32,bytes32,uint8))" "$ID1" --rpc-url "$RPC"
cast call "$CONTRACT" "getInvoice(uint256)((address,address,uint256,uint256,uint256,string,bytes32,bytes32,uint8))" "$ID2" --rpc-url "$RPC"
cast call "$CONTRACT" "getPurchaseOrder(address,bytes32)((address,uint256,uint256,uint256,uint256,bool))" "$PAYER" "$PO" --rpc-url "$RPC"
cast call "$CONTRACT" "milestoneStatus(address,bytes32,bytes32)(bool,uint256,uint8)" "$PAYER" "$PO" "$M1" --rpc-url "$RPC"
cast call "$TUSD8" "balanceOf(address)(uint256)" "$MERCHANT" --rpc-url "$RPC"
