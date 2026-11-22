# InvoicePay: stablecoin invoices on QDay Aevum

An entry for the Aevum Builder Challenge #1 (QDay): one complete
stablecoin payment flow running on the QDay Aevum testnet.

The payer first approves a purchase order on chain: which merchant
may bill it, the total amount cap, and an expiry. The merchant then
creates invoices denominated in tUSD8 (the Aevum test stablecoin, 6
decimals) against that approval, in full or in parts. The contract
rejects anything beyond the approved total, and once the total is
settled the purchase order is locked forever. The named payer
settles each invoice on chain, the contract pulls the tokens
straight to the merchant, marks the invoice paid, and emits an
event. The contract never custodies funds.

## Verify in two minutes

Live demo: open demo/index.html from this repository in a browser
with a wallet such as MetaMask. The live contract address is
prefilled, and the demo adds the QDay Aevum testnet for you.

Repository: https://github.com/Niosoke/invoicepay-aevum

Contract: 0xbBbB9BDcbE16B548C5d452a74F2C67EcD66bA363
Explorer: https://explorer-test.qday.info/address/0xbBbB9BDcbE16B548C5d452a74F2C67EcD66bA363

One paid invoice to inspect: the pay transaction for invoice 0 is
https://explorer-test.qday.info/tx/0x80f82e996f4a6f74033c01b9a0f89ce10e171976a04f8c92571a36d897486651
It moves 0.5 tUSD8 from payer to merchant and emits InvoicePaid.
Invoice 0 is the first half of purchase order PO 3001, which the
payer approved for a total of 1 tUSD8; invoice 1 settled the second
half.

One rejected duplicate to inspect: after both halves settled, a
further invoice for the same purchase order reverted with
DuplicatePurchaseOrder in transaction
https://explorer-test.qday.info/tx/0xbd63b9e4778b4c28c30fd7d1cb7e3e46e6aa8703744710cbb3d3c577cb77a9d7

One rejected overrun to inspect: before payment, an invoice that
would have pushed the total past the approved cap reverted with
AmountExceedsApproval in transaction
https://explorer-test.qday.info/tx/0xa0bebe61ebe16615abdbad3a7dbc9c20ff96594deafc717e53dc5c6dff509380

Tests: forge test (33 tests, all passing).

## The problem

Consider a cross border freelancer who does design work for a
corporate client in another country. The client issues a purchase
order, the freelancer sends an invoice, and the finance team pays
in stablecoins. Today that invoice is a chat message or a PDF:
"send 25 USDT to this address, invoice 1042." There is no shared
record of what was billed, to whom, or whether it was paid. Worse,
the same purchase order can be billed twice by accident: two
invoice emails, two payments, and a messy refund conversation
afterwards. And when a payment does arrive, the finance team has
to match it to the right purchase order by hand, from an amount
and a timestamp.

InvoicePay puts that record on chain and binds it to the purchase
order the client approved. The client records the approval first:
the vendor wallet, the total they agreed to pay, and an expiry.
Only that vendor can bill against it, only up to that total, and
only while the approval is open. Every invoice carries the hash
of the purchase order it settles, so the finance team can verify
each bill against their own approval before paying, and point to
one public record that shows the obligation is settled.

## How it works

1. Approve the purchase order. The payer calls
   approvePurchaseOrder with the merchant address, the purchase
   order reference (a bytes32 hash of the purchase order), the
   total cap, and an expiry. This is the authorization step: the
   payer, not the merchant, states what may be billed. An approval
   that has not been used yet can be replaced by approving again;
   once an invoice reserves against it, its terms are locked.
2. Create. The merchant calls createInvoice with the payer, the
   amount, the due date, a memo, and the purchase order reference.
   The contract checks that the payer approved this reference for
   this merchant, that the approval has not expired, and that the
   amount fits in what is left of the approved total. The amount
   is reserved against the purchase order while the invoice is
   open. Several invoices can settle one purchase order in parts,
   for example one per delivery, as long as the settled plus
   reserved total never passes the cap.
3. Approve. The payer approves the contract to spend the invoice
   amount of tUSD8 (standard ERC20 allowance).
4. Pay. The payer calls payInvoice with the invoice id. The
   contract checks the caller is the named payer and the invoice
   is still open, marks it Paid, moves the amount from reserved
   to settled on the purchase order, then pulls the exact amount
   from payer to merchant with transferFrom and emits
   InvoicePaid. When the settled total reaches the cap, the
   purchase order is locked forever and any further invoice
   reverts with DuplicatePurchaseOrder.
5. Cancel. The merchant can cancel an unpaid invoice with
   cancelInvoice. Cancelling releases the reserved amount, so a
   corrected invoice can be created against the same purchase
   order. A paid invoice can never be cancelled or paid twice.

Late payment is accepted. The isOverdue view reports whether an
open invoice is past its due date. The getPurchaseOrder and
purchaseOrderRemaining views report the approval terms, how much
is settled, how much open invoices reserve, and how much is still
available. Approval expiry gates new invoices only: an invoice
created while the approval was open can still be paid after the
expiry passes.

## Architecture

```
┌────────────┐  approvePurchaseOrder  ┌──────────────┐
│   Payer    │ ─────────────────────▶ │              │
└────────────┘  merchant, cap, expiry │              │
┌────────────┐   createInvoice        │  InvoicePay  │
│  Merchant  │ ─────────────────────▶ │  contract    │   transferFrom, exact amount
└────────────┘   with PO hash         │  (no custody)│ ──────────────────────────▶ Merchant wallet
┌────────────┐   approve tUSD8        │              │
│   Payer    │ ─────────────────────▶ │              │
└────────────┘   payInvoice           └──────────────┘
                                             │
                                             ▼
                              events: PurchaseOrderApproved,
                              InvoiceCreated, InvoicePaid,
                              InvoiceCancelled
```

src/InvoicePay.sol is the whole product. One contract, no custody,
a reentrancy guard on the payment path, and checks effects
interactions ordering. The purchase order accounting keeps two
counters per approval, settled and reserved, with the invariant
that their sum never passes the approved cap. The ERC20 interface
is declared locally so the project has no external dependencies
beyond forge std (tests only).

src/MockUSD8.sol is a 6 decimal ERC20 used only in tests to stand
in for tUSD8.

test/InvoicePay.t.sol holds 33 Foundry tests covering the full
cycle, every rejection path, the purchase order approval (no
approval, wrong merchant, amount above the cap, expired approval,
terms locked once in use), and settlement against the cap
(duplicate settlement, partial invoices, cancel releasing the
reservation).

script/Deploy.s.sol deploys InvoicePay wired to the official
tUSD8 token on Aevum testnet.

demo/index.html is a single file web demo (ethers.js) that adds
the Aevum testnet to a wallet and walks through approving a
purchase order, creating an invoice, a guided check that watches
the contract reject billing beyond the cap, and a payer view that
lists invoices addressed to you, verifies each one against your
approval, pays it, and produces a settlement proof you can copy
for your records. Error messages are plain language throughout.

demo/runcycle.sh runs the same full cycle from the command line
with cast, including an attempt beyond the cap that must revert.

## Workflow in detail

Payer side, before any billing: approve the purchase order once.
Name the vendor wallet, the total you agreed to pay, and how long
the approval stays open for new invoices. That one transaction is
the whole authorization; the vendor cannot bill you without it,
cannot bill more than the cap, and cannot bill after the expiry.

Merchant side: pick the payer wallet, the amount in tUSD8, a due
date, a memo, and the purchase order this invoice settles. The
amount may be the full approved total or one part of it. One
transaction creates the invoice and returns its id. Share the id
with the payer.

Payer side, at payment time: open the payer view in the demo. It
lists every invoice that names you, with the memo, the purchase
order hash, the merchant, and the amount, and next to each one
the state of your own approval: the cap, what is already settled,
what open invoices reserve, and what is still available. Verify
the invoice matches the purchase order you approved, approve the
contract for the exact amount, then pay. Two wallet confirmations
in total. Afterwards the demo shows a settlement proof with the
invoice id, the purchase order hash, the amount, the transaction
hash, the block, and the payment time, ready to copy into your
records.

After payment: the invoice status reads Paid, paidAt holds the
payment time, the settled total on the purchase order grows by
the invoice amount, the merchant balance grows by the same
amount, and the contract balance stays at zero. Anyone can verify
all of this on the explorer or with the read functions getInvoice,
getPurchaseOrder, purchaseOrderRemaining, isOverdue, and
invoiceCount.

## Security claims

Every claim below maps to a test in test/InvoicePay.t.sol. Run
forge test to check them all.

| Claim | Test |
| --- | --- |
| The payer approval records merchant, cap, and expiry and emits an event | testApprovePurchaseOrder |
| Approval rejects a zero merchant, a zero reference, a zero amount, and a past expiry | testApproveRejectsBadInputs |
| An unused approval can be corrected and a used one is locked | testReapproveUnusedPurchaseOrder, testApprovalLockedOnceInUse |
| Creation without a payer approval is rejected | testCreateRejectsWithoutApproval |
| Only the merchant named in the approval can bill it | testCreateRejectsWrongMerchant |
| An invoice above the approved total is rejected | testCreateRejectsAmountAboveApproval |
| An expired approval accepts no new invoices | testCreateRejectsExpiredApproval |
| An invoice created before expiry can still be paid after it | testPayAfterApprovalExpiry |
| A second invoice beyond the approved total is rejected | testSecondInvoiceBeyondApprovalReverts |
| A fully settled purchase order stays locked forever | testPaidPurchaseOrderStaysLocked |
| Partial invoices settle up to the approved total and no further | testPartialInvoicesUpToTotal |
| A partial invoice that would overrun the cap is rejected | testPartialOverrunReverts |
| Cancelling releases the reserved amount | testCancelFreesPurchaseOrder, testCancelReleasesPartialReservation |
| Two purchase orders with the same amount both settle | testDifferentPurchaseOrdersSameAmount |
| The same reference approved by two payers stays independent | testSameReferenceDifferentPayers |
| The purchase order views agree with the stored state | testGetPurchaseOrderView |
| Only the named payer can settle an invoice | testPayRejectsWrongPayer |
| The exact stored amount moves from payer to merchant and the contract keeps nothing | testPayInvoiceFullCycle |
| An invoice can be paid at most once | testPayRejectsDoublePayment |
| A purchase order reference is required at creation | testCreateRejectsZeroPurchaseOrder |
| Only the merchant can cancel, and only while unpaid | testCancelInvoice, testCancelRejectsNonMerchant, testCancelRejectsPaidInvoice |
| Creation rejects a zero payer, a zero amount, and a past due date | testCreateRejectsZeroPayer, testCreateRejectsZeroAmount, testCreateRejectsPastDueDate |
| Payment without a token allowance fails | testPayRejectsWithoutAllowance |
| Unknown invoice ids fail | testPayRejectsUnknownInvoice |
| The overdue flag tracks open invoices past their due date | testOverdueFlag |
| Invoices stay independent of each other | testMultipleInvoicesAreIndependent |
| The stored invoice fields match what the merchant created | testCreateInvoice |

## Safety notes

No custody. The contract never holds tokens. payInvoice moves
funds with transferFrom directly from payer to merchant, so there
is no pool to drain and no withdrawal function to abuse.

The payer authorizes, the merchant bills. An invoice can only be
created against a purchase order the payer approved on chain for
that merchant. The merchant cannot invent an obligation, raise
the total, or bill a different payer against the same approval.

One approved total, never more. Every approval tracks how much is
settled and how much open invoices reserve. Creation is rejected
when the new amount would push that sum past the approved cap,
so a purchase order can be settled in parts but never beyond the
total the payer agreed to. Once the settled total reaches the
cap, the purchase order is locked forever. Only a cancel by the
merchant releases a reservation, and only while the invoice is
unpaid.

Approval terms lock once in use. The payer can correct an
approval before anything is billed against it. After the first
invoice reserves against it, the merchant, cap, and expiry can no
longer be rewritten, so neither side can move the goalposts mid
way.

Exact amount only. The contract pulls the stored invoice amount.
The payer cannot underpay, overpay, or redirect the funds.

Named payer only. payInvoice reverts unless the caller is the
payer recorded at creation. A stranger with an allowance still
cannot pay someone else invoice.

Paid is final. Status flips to Paid before the token transfer
(checks effects interactions ordering), a reentrancy guard covers
the payment path, and a paid or cancelled invoice can never be
paid again.

No admin surface. There is no owner, no pause switch, no upgrade
path, and no way to edit an invoice or an approval after creation
beyond the rules above. The only privileged acts are the merchant
cancelling their own unpaid invoice and the payer approving their
own purchase orders.

Failures are explicit. Every rejection path reverts with a named
custom error (PurchaseOrderNotApproved, WrongMerchant,
AmountExceedsApproval, DuplicatePurchaseOrder, NotPayer, and so
on), and the web demo translates those errors into plain
language.

## Limits

No refunds and no dispute handling. Settlement is direct and
final: once the payer pays, the tokens sit in the merchant wallet
and the contract cannot pull them back. If goods or services are
not delivered, the dispute stays between the two parties off
chain. InvoicePay records and enforces payment; it does not judge
delivery.

No escrow. Each invoice settles in full in one payment or not at
all. A purchase order can be billed in several invoices up to
its approved total, but a single invoice is never paid in parts.

Approval expiry gates new invoices only. An invoice created
while the approval was open can still be paid after the expiry
passes, because the invoice carries its own due date. Finance
teams that need a hard payment cutoff should set the invoice due
dates accordingly and cancel stale invoices.

One token only. Every invoice is denominated in tUSD8, the Aevum
test stablecoin.

No admin surface cuts both ways. There is no owner, no pause,
and no upgrade path, so there is no operator who can freeze or
redirect funds. It also means a mistaken invoice can only be
cancelled by its merchant while unpaid, a mistaken approval can
only be corrected before it is used, and a paid invoice can never
be undone by the contract.

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

Full approve, create, and pay cycle from the CLI: set CONTRACT
to the deployed address and run ./demo/runcycle.sh

Web demo: open demo/index.html in a browser with MetaMask. The
live contract address is prefilled. Connect, approve a purchase
order as the payer, switch accounts and create an invoice as the
merchant, run the guided check to watch the contract reject
billing beyond the approved total, then switch back to the payer,
open the payer view, verify the invoice against your approval,
pay it, and copy the settlement proof.

Testnet wallets used for the live run (testnet only, no real
funds):

Merchant and deployer: 0x41747089c2bEd5AB8c1975ae3f42E59C294a3791
Payer: 0xa7f32e07Ad8612b4f59BE699Ef9B8190645e462B

## Deployment

Live on QDay Aevum testnet since 23 Nov 2026. This deployment
adds payer approved purchase orders with a total cap and partial
billing up to that cap.

InvoicePay contract: 0xbBbB9BDcbE16B548C5d452a74F2C67EcD66bA363
Deploy tx: 0x40b64da438b68ef21f7756b14451bb58fc8b203073ba699abc2d4a5725cb56f0
Fund payer tx: 0xdc09b93deda166a111d8793cfe43b948e6020bead31ce0e3950acda7c1756287
Approve PO 3001 tx: 0x4d918a78ba0fa8210163880394b49fd6818cd7bacc6d6a7c6eea76f162a88d42
Create invoice 0, first half of PO 3001: 0xbeac031344acc1baeca65b672d4d47a1677b7bd1478e3a69ec72c67cb9299062
Create invoice 1, second half of PO 3001: 0x728bab22135a6a941a9936b0691584925fbbb61c5a2ae11d451bafabf22acbc4
Overrun attempt for PO 3001, reverted: 0xa0bebe61ebe16615abdbad3a7dbc9c20ff96594deafc717e53dc5c6dff509380
Approve tx: 0xf420aa8fbd628273f9e90969a19d5390e11f03d1e7bf81ae8e23afbbb34e72cb
Pay invoice 0 tx: 0x80f82e996f4a6f74033c01b9a0f89ce10e171976a04f8c92571a36d897486651
Pay invoice 1 tx: 0xb51027bd1d308b5e0f8c1c18487c3b068f5a7bf266541530c1998ac0298d4ffa
Duplicate attempt for PO 3001, reverted: 0xbd63b9e4778b4c28c30fd7d1cb7e3e46e6aa8703744710cbb3d3c577cb77a9d7

The full cycle ran on chain from start to finish. The merchant
funded the payer with 1 tUSD8. The payer approved purchase order
PO 3001 for the merchant with a total cap of 1 tUSD8. The
merchant created invoice 0 for the first half, 0.5 tUSD8, and
invoice 1 for the second half, another 0.5 tUSD8, so one purchase
order was billed in two parts. A further invoice for 0.1 tUSD8
was attempted while both halves were open and reverted with
AmountExceedsApproval, because the two open invoices already
reserved the whole cap. The payer then approved the token
allowance and paid both invoices. A final invoice attempt
against PO 3001 reverted with DuplicatePurchaseOrder, because
the purchase order is now fully settled and locked. Final reads
show the purchase order settled at exactly 1 tUSD8 with nothing
left available, both invoices Paid, and final balances of
merchant 1 tUSD8, payer 0, contract 0, which proves nothing is
custodied. Two read only simulations against the same contract
also reverted as expected: creating an invoice against a purchase
order the payer never approved (PurchaseOrderNotApproved) and
creating one from a wallet the approval does not name
(WrongMerchant). Look the contract and the transactions up on
the explorer at https://explorer-test.qday.info

This deployment replaces the earlier one at
0x72334b6555eaf05dc78f7a1519f25699700c38ee, where the merchant
alone asserted the purchase order reference and each purchase
order could carry only one invoice. That build in turn replaced
the deployment at 0xf1295031c9454bd067D3763052a0410C536792f6,
which had no purchase order binding, and the first deployment at
0xdCDEab8178e0B2e937af833049260f912E634358, whose bytecode used
the Cancun MCOPY opcode that the Aevum testnet node rejects
inside read calls. The current build targets the paris EVM
version (see evm_version in foundry.toml), contains no MCOPY,
and the read path works: getInvoice returns the full invoice and
getPurchaseOrder returns the full approval record. The earlier
deployments still sit on chain with their own paid invoices, but
the address above is the one to use.

## Technologies

Solidity 0.8, Foundry (forge, cast), ethers.js 6 for the web demo,
QDay Aevum testnet (EVM compatible, chain 44005).

## License

MIT. forge std is used under its own license (see lib/forge-std).
