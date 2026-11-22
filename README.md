# InvoicePay: stablecoin invoices on QDay Aevum

An entry for the Aevum Builder Challenge #1 (QDay): one complete
stablecoin payment flow running on the QDay Aevum testnet.

A merchant creates an invoice denominated in tUSD8 (the Aevum test
stablecoin, 6 decimals) and bound to a purchase order. The named payer
settles the exact amount on chain. The contract pulls the tokens
straight to the merchant, marks the invoice paid, and emits an event.
One purchase order can only be settled once: a second invoice for the
same purchase order from the same merchant is rejected while the first
is not cancelled. The contract never custodies funds.

## Verify in two minutes

Live demo: open demo/index.html from this repository in a browser with
a wallet such as MetaMask. The live contract address is prefilled, and
the demo adds the QDay Aevum testnet for you.

Repository: https://github.com/Niosoke/invoicepay-aevum

Contract: 0x72334b6555eaf05dc78f7a1519f25699700c38ee
Explorer: https://explorer-test.qday.info/address/0x72334b6555eaf05dc78f7a1519f25699700c38ee

One paid invoice to inspect: the pay transaction for invoice 0 is
https://explorer-test.qday.info/tx/0xcafff3ce16dc6e7f5c71432c7967260bb0f679b995ad451d92975a1c0b9e356b
It moves 0.5 tUSD8 from payer to merchant and emits InvoicePaid.

One rejected duplicate to inspect: a second invoice for the same
purchase order reverted with DuplicatePurchaseOrder in transaction
https://explorer-test.qday.info/tx/0xac6658cea2989206f72e0b6b34e60ce37ba5b980e8470fe9905e8b436bf908df

Tests: forge test (21 tests, all passing).

## The problem

Consider a cross border freelancer who does design work for a
corporate client in another country. The client issues a purchase
order, the freelancer sends an invoice, and the finance team pays in
stablecoins. Today that invoice is a chat message or a PDF: "send 25
USDT to this address, invoice 1042." There is no shared record of what
was billed, to whom, or whether it was paid. Worse, the same purchase
order can be billed twice by accident: two invoice emails, two
payments, and a messy refund conversation afterwards.

InvoicePay puts that record on chain and binds it to the purchase
order. Every invoice has an id, a merchant, a payer, an amount, a due
date, a memo, the hash of the purchase order it settles, and a status
that only the real payment can flip to Paid. The contract rejects a
second invoice for the same purchase order, so the finance team
cannot pay the same obligation twice, and the freelancer can point to
one public record that shows the invoice is settled.

## How it works

1. Create. The merchant calls createInvoice with the payer, the
   amount, the due date, a memo, and the purchase order reference (a
   bytes32 hash of the purchase order). The invoice is stored with
   status Open and an InvoiceCreated event. If the merchant already
   has a non cancelled invoice for that purchase order, the call
   reverts with DuplicatePurchaseOrder.
2. Approve. The payer approves the contract to spend the invoice
   amount of tUSD8 (standard ERC20 allowance).
3. Pay. The payer calls payInvoice with the invoice id. The contract
   checks the caller is the named payer and the invoice is still
   open, marks it Paid, then pulls the exact amount from payer to
   merchant with transferFrom and emits InvoicePaid. The purchase
   order stays locked after payment, so it can never be settled a
   second time.
4. Cancel. The merchant can cancel an unpaid invoice with
   cancelInvoice. Cancelling frees the purchase order reference, so a
   corrected invoice can be created for the same purchase order. A
   paid invoice can never be cancelled or paid twice.

Late payment is accepted. The isOverdue view reports whether an open
invoice is past its due date. The purchaseOrderStatus view reports
which invoice, if any, is bound to a purchase order for a merchant.

## Architecture

```
┌────────────┐   createInvoice    ┌──────────────┐
│  Merchant  │ ─────────────────▶ │              │
└────────────┘   with PO hash     │              │
                                  │  InvoicePay  │
┌────────────┐   approve tUSD8    │  contract    │   transferFrom, exact amount
│   Payer    │ ─────────────────▶ │  (no custody)│ ──────────────────────────▶ Merchant wallet
└────────────┘   payInvoice       │              │
                                  └──────────────┘
                                         │
                                         ▼
                              events: InvoiceCreated,
                              InvoicePaid, InvoiceCancelled
```

src/InvoicePay.sol is the whole product. One contract, no custody, a
reentrancy guard on the payment path, and checks effects interactions
ordering. The ERC20 interface is declared locally so the project has
no external dependencies beyond forge std (tests only).

src/MockUSD8.sol is a 6 decimal ERC20 used only in tests to stand in
for tUSD8.

test/InvoicePay.t.sol holds 21 Foundry tests covering the full cycle,
every rejection path, and the purchase order binding (duplicate
creation, two purchase orders with the same amount, cancel freeing
the reference, paid purchase orders staying locked).

script/Deploy.s.sol deploys InvoicePay wired to the official tUSD8
token on Aevum testnet.

demo/index.html is a single file web demo (ethers.js) that adds the
Aevum testnet to a wallet and walks through create, approve, pay, and
read, with a live invoice list, a guided duplicate check, and plain
language error messages.

demo/runcycle.sh runs the same full cycle from the command line
with cast, including a duplicate attempt that must revert.

## Workflow in detail

Merchant side: pick the payer wallet, the amount in tUSD8, a due
date, a memo, and the purchase order this invoice settles. One
transaction creates the invoice and returns its id. Share the id
with the payer.

Payer side: read the invoice first (the demo lists every invoice with
its memo, purchase order hash, amount, due date, and status).
Approve the contract for the exact amount, then pay. Two wallet
confirmations in total.

After payment: the invoice status reads Paid, paidAt holds the
payment time, the merchant balance grows by the invoice amount, and
the contract balance stays at zero. Anyone can verify all of this on
the explorer or with the read functions getInvoice, isOverdue,
invoiceCount, and purchaseOrderStatus.

## Security claims

Every claim below maps to a test in test/InvoicePay.t.sol. Run
forge test to check them all.

| Claim | Test |
| --- | --- |
| Only the named payer can settle an invoice | testPayRejectsWrongPayer |
| The exact stored amount moves from payer to merchant and the contract keeps nothing | testPayInvoiceFullCycle |
| An invoice can be paid at most once | testPayRejectsDoublePayment |
| A second invoice for the same purchase order is rejected | testDuplicatePurchaseOrderReverts |
| A settled purchase order stays locked forever | testPaidPurchaseOrderStaysLocked |
| Two purchase orders with the same amount both settle | testDifferentPurchaseOrdersSameAmount |
| Cancelling frees the purchase order for a fresh invoice | testCancelFreesPurchaseOrder |
| The purchase order binding is per merchant | testSamePurchaseOrderDifferentMerchant |
| A purchase order reference is required at creation | testCreateRejectsZeroPurchaseOrder |
| The purchase order lookup view agrees with the stored state | testPurchaseOrderStatusView |
| Only the merchant can cancel, and only while unpaid | testCancelInvoice, testCancelRejectsNonMerchant, testCancelRejectsPaidInvoice |
| Creation rejects a zero payer, a zero amount, and a past due date | testCreateRejectsZeroPayer, testCreateRejectsZeroAmount, testCreateRejectsPastDueDate |
| Payment without a token allowance fails | testPayRejectsWithoutAllowance |
| Unknown invoice ids fail | testPayRejectsUnknownInvoice |
| The overdue flag tracks open invoices past their due date | testOverdueFlag |
| Invoices stay independent of each other | testMultipleInvoicesAreIndependent |
| The stored invoice fields match what the merchant created | testCreateInvoice |

## Safety notes

No custody. The contract never holds tokens. payInvoice moves funds
with transferFrom directly from payer to merchant, so there is no
pool to drain and no withdrawal function to abuse.

One purchase order, one settlement. Creation stores the purchase
order hash and rejects a second live invoice for the same merchant
and purchase order pair. Payment keeps the lock in place. Only a
cancel by the merchant releases the reference, and only while the
invoice is unpaid.

Exact amount only. The contract pulls the stored invoice amount. The
payer cannot underpay, overpay, or redirect the funds.

Named payer only. payInvoice reverts unless the caller is the payer
recorded at creation. A stranger with an allowance still cannot pay
someone else invoice.

Paid is final. Status flips to Paid before the token transfer
(checks effects interactions ordering), a reentrancy guard covers
the payment path, and a paid or cancelled invoice can never be paid
again.

No admin surface. There is no owner, no pause switch, no upgrade
path, and no way to edit an invoice after creation. The only
privileged act is the merchant cancelling their own unpaid invoice.

Failures are explicit. Every rejection path reverts with a named
custom error (NotPayer, InvoiceNotOpen, DuplicatePurchaseOrder, and
so on), and the web demo translates those errors into plain
language.

## Limits

No refunds and no dispute handling. Settlement is direct and final:
once the payer pays, the tokens sit in the merchant wallet and the
contract cannot pull them back. If goods or services are not
delivered, the dispute stays between the two parties off chain.
InvoicePay records and enforces payment; it does not judge delivery.

No escrow and no partial payments. Each invoice settles in full in
one payment or not at all.

One token only. Every invoice is denominated in tUSD8, the Aevum
test stablecoin.

No admin surface cuts both ways. There is no owner, no pause, and
no upgrade path, so there is no operator who can freeze or redirect
funds. It also means a mistaken invoice can only be cancelled by
its merchant while unpaid, and a paid invoice can never be undone
by the contract.

Testnet only. This deployment runs on the QDay Aevum testnet with
test tokens that have no real value.

## Network facts (QDay Aevum testnet)

Chain ID: 44005 (0xABE5)
RPC: https://rpc-test.qday.info
Explorer: https://explorer-test.qday.info
Gas token: tQDAY (18 decimals), from https://faucet.qday.info
Stablecoin: tUSD8 at 0x456569838f1d43009A91ebA4263147Afd7233483 (6 decimals)

## Run it

Prerequisites: Foundry (forge and cast), and for the web demo any
browser wallet such as MetaMask.

Tests: forge test

Deploy (needs a funded keystore wallet, see below):
forge script script/Deploy.s.sol with the RPC URL above, the
keystore at keystore/merchant, and the broadcast flag.

Full create and pay cycle from the CLI: set CONTRACT to the
deployed address and run ./demo/runcycle.sh

Web demo: open demo/index.html in a browser with MetaMask. The live
contract address is prefilled. Connect, create an invoice as the
merchant, run the guided duplicate check to watch the contract
reject a second invoice for the same purchase order, switch
accounts, approve and pay as the payer, then refresh the invoice
list to see the status flip to Paid.

Testnet wallets used for the live run (testnet only, no real funds):

Merchant and deployer: 0x41747089c2bEd5AB8c1975ae3f42E59C294a3791
Payer: 0xa7f32e07Ad8612b4f59BE699Ef9B8190645e462B

## Deployment

Live on QDay Aevum testnet since 23 Nov 2026. This deployment adds
the purchase order binding.

InvoicePay contract: 0x72334b6555eaf05dc78f7a1519f25699700c38ee
Deploy tx: 0x3725afc9a6da6e731dc2f7be840a52acda71af8ff32104bc39b88cc8d7d3eae6
Fund payer tx: 0x90878d8914a2b3b2a7fb79fe83c31f336f6a0716cfa716d7890d10df76931345
Create invoice 0 for PO 1042: 0x91b38169fb8f412ba3b4a196cc874a52868176a0c85df3c5c0e145d0c3886164
Approve tx: 0x6bcdc097640399e654961ac6d194f43b1209cc7403286add1ccdd71202817446
Pay invoice 0 tx: 0xcafff3ce16dc6e7f5c71432c7967260bb0f679b995ad451d92975a1c0b9e356b
Create invoice 1 for PO 1043: 0xa52f7d947fb1604fbb04277cb8858ddd847c7f443787a6f82490e1874979a0db
Approve tx: 0xcd10717ff39000e6a938d1a9899d8dc4206b1c0d15caea3871158dd42c9210fa
Pay invoice 1 tx: 0xf00ab06ca522d5081595dc613566fa5054eb33f88c58ea28f0f1fbfe9d17cf34
Duplicate attempt for PO 1042, reverted: 0xac6658cea2989206f72e0b6b34e60ce37ba5b980e8470fe9905e8b436bf908df

The full cycle ran on chain from start to finish. The merchant
funded the payer with 1 tUSD8, created invoice 0 for 0.5 tUSD8
against purchase order PO 1042, and the payer approved and paid it.
The merchant then created invoice 1 for the same 0.5 tUSD8 against
a different purchase order, PO 1043, and the payer paid that one
too. Two purchase orders with the same amount both settled. A
second invoice for PO 1042 was then attempted and the transaction
reverted with DuplicatePurchaseOrder, so the settled purchase order
stays locked. Final balances: merchant 1 tUSD8, payer 0, contract
0, which proves nothing is custodied. Look the contract and the
transactions up on the explorer at https://explorer-test.qday.info

This deployment replaces the earlier one at
0xf1295031c9454bd067D3763052a0410C536792f6, which had no purchase
order binding. That build in turn replaced the first deployment at
0xdCDEab8178e0B2e937af833049260f912E634358, whose bytecode used the
Cancun MCOPY opcode that the Aevum testnet node rejects inside read
calls. The current build targets the paris EVM version (see
evm_version in foundry.toml), contains no MCOPY, and the read path
works: getInvoice returns the full invoice including the memo and
the purchase order hash. The earlier deployments still sit on chain
with their own paid invoices, but the address above is the one to
use.

## Technologies

Solidity 0.8, Foundry (forge, cast), ethers.js 6 for the web demo,
QDay Aevum testnet (EVM compatible, chain 44005).

## License

MIT. forge std is used under its own license (see lib/forge-std).
