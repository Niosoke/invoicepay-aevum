# InvoicePay: stablecoin invoices on QDay Aevum

Suggested submission title: InvoicePay, Buyer Approved PO and
Milestone Payments

An entry for the Aevum Builder Challenge #1 (QDay): one complete
stablecoin payment flow running on the QDay Aevum testnet.

The payer first approves a purchase order on chain: which merchant
may bill it, the total amount cap, and an expiry. The merchant then
creates invoices denominated in tUSD8 (the Aevum test stablecoin, 6
decimals) against that approval, in full or in parts. The contract
rejects anything beyond the approved total, and once the total is
settled the purchase order is locked forever. Every invoice also
names the milestone it bills, and a milestone can be billed only
once per purchase order: a resubmitted bill for work already paid
is rejected even while budget remains, while the next installment
with the same amount goes through. The named payer settles each
invoice on chain, the contract pulls the tokens straight to the
merchant, marks the invoice paid, and emits an event. The contract
never custodies funds.

## Verify in two minutes

Live demo: open demo/index.html from this repository in a browser
with a wallet such as MetaMask. The live contract address is
prefilled, and the demo adds the QDay Aevum testnet for you.

Repository: https://github.com/Niosoke/invoicepay-aevum

Contract: 0x7159f69bc4c03598ba74e35b24bf828430310d8d
Explorer: https://explorer-test.qday.info/address/0x7159f69bc4c03598ba74e35b24bf828430310d8d

One paid invoice to inspect: the pay transaction for invoice 0 is
https://explorer-test.qday.info/tx/0x3b6842a59916f2a4a9568fbb7d3b4ae01b9d0a07bee1d173b29590cb7bd94cbc
It moves 0.4 tUSD8 from payer to merchant and emits InvoicePaid.
Invoice 0 is milestone 1 of purchase order PO 5001, which the
payer approved for a total of 1 tUSD8; invoice 1 settled milestone
2 for the same 0.4 tUSD8.

One rejected resubmission to inspect: while 0.6 tUSD8 of budget
still remained under the cap, billing milestone 1 a second time
reverted with DuplicateMilestone in transaction
https://explorer-test.qday.info/tx/0x7c15195264a6fbceb6e3509714c641ea6b3d39560aea97782f3cb94aa543fac1
The amount would have fitted the remaining budget; only the
milestone identity rejected it. The same resubmission after both
installments were paid reverted again in transaction
https://explorer-test.qday.info/tx/0x68a3551d78050d0c989142e748430a402b49d4dfd103f52cba1cd04e761ceb51

Tests: forge test (42 tests, all passing).

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
and a timestamp. Even with a budget cap, one ambiguity survives:
when a second bill for the same amount arrives while budget
remains, is it the next legitimate installment or the same work
billed again? Amounts cannot tell the two apart.

InvoicePay puts that record on chain and binds it to the purchase
order the client approved. The client records the approval first:
the vendor wallet, the total they agreed to pay, and an expiry.
Only that vendor can bill against it, only up to that total, and
only while the approval is open. Every invoice carries the hash
of the purchase order it settles and the hash of the milestone it
bills, and each milestone can be billed only once per purchase
order. So the finance team can verify each bill against their own
approval before paying, tell a resubmitted bill apart from the
next installment at a glance, and point to one public record that
shows the obligation is settled.

## How it works

1. Approve the purchase order. The payer calls
   approvePurchaseOrder with the merchant address, the purchase
   order reference (a bytes32 hash of the purchase order), the
   total cap, and an expiry. This is the authorization step: the
   payer, not the merchant, states what may be billed. An approval
   that has not been used yet can be replaced by approving again;
   once an invoice reserves against it, its terms are locked.
2. Create. The merchant calls createInvoice with the payer, the
   amount, the due date, a memo, the purchase order reference, and
   a milestone reference (a bytes32 hash of the milestone or
   invoice number being billed, for example the hash of "PO 1042
   milestone 1"). The contract checks that the payer approved this
   reference for this merchant, that the approval has not expired,
   that the milestone has not already been billed under this
   approval, and that the amount fits in what is left of the
   approved total. The amount is reserved against the purchase
   order while the invoice is open, and the milestone is claimed
   by this invoice. Several invoices can settle one purchase order
   in parts, for example one per delivery, as long as the settled
   plus reserved total never passes the cap and every part names a
   different milestone. Two installments with the identical amount
   are fine; billing the same milestone twice is not, even while
   budget remains and even after the first invoice was paid.
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
   cancelInvoice. Cancelling releases the reserved amount and
   frees the milestone reference, so a corrected invoice can be
   created against the same purchase order and the same milestone.
   A paid invoice can never be cancelled or paid twice, and its
   milestone stays claimed forever.

Late payment is accepted, and the due date is a marker only.
The isOverdue view reports whether an open invoice is past its
due date, but payInvoice never checks the due date: while an
invoice stays Open the named payer can still pay it, even after
the due date has passed. Nothing in the contract closes an
invoice automatically at its due date. The only way an open
invoice stops being payable is a cancel by its merchant, so the
effective payment deadline for a stale invoice depends on the
merchant cancelling it, not on the due date alone. The
getPurchaseOrder and purchaseOrderRemaining views report the
approval terms, how much is settled, how much open invoices
reserve, and how much is still available. The milestoneStatus
view reports whether a milestone is claimed under an approval,
by which invoice, and in what status. Approval expiry gates new
invoices only: an invoice created while the approval was open
can still be paid after the expiry passes, and cancelling after
expiry still frees the milestone, but no new invoice can be
created once the approval has expired.

The memo is public. It is stored on chain with the invoice and
emitted in the InvoiceCreated event, so anyone can read it. The
purchase order reference and the milestone reference are not
public in that way: only their hashes are stored, never the
plain text. Keep memos fictional or generic, and keep real
purchase order numbers and milestone names in the hashed
references only. The web demo follows this rule: its memo
fields default to neutral labels and never copy the purchase
order text into a memo.

Revising a purchase order after billing has started needs a new
reference. An approval locks as soon as any value is settled or
reserved against it, so after the first installment is paid the
payer can no longer rewrite the merchant, the cap, or the
expiry under the same reference. To revise, the payer approves
a replacement reference for the remaining work, for example a
new purchase order number that points back to the original one
in the finance records. The remaining balance to approve under
the replacement is the original cap minus what is already
settled, and any invoice still open under the old reference
stays payable under the old approval until it is paid or the
merchant cancels it, so settle or cancel those first to avoid
double counting. Settlement history then spans two approvals:
each approval keeps its own settled total and its own milestone
claims, and the finance team links the two references in their
own records while the explorer and the contract views prove
each part on chain. Milestone names should stay distinct across
the replacement so no milestone is billed under both references.

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

test/InvoicePay.t.sol holds 42 Foundry tests covering the full
cycle, every rejection path, the purchase order approval (no
approval, wrong merchant, amount above the cap, expired approval,
terms locked once in use), settlement against the cap (duplicate
settlement, partial invoices, cancel releasing the reservation),
and milestone identity (resubmitted milestone rejected while
budget remains, two equal installments both settling, cancel
freeing the milestone, a paid milestone staying locked, and both
sides of the approval expiry edge).

script/Deploy.s.sol deploys InvoicePay wired to the official
tUSD8 token on Aevum testnet.

demo/index.html is a single file web demo (ethers.js) that adds
the Aevum testnet to a wallet and walks through approving a
purchase order, creating an invoice with its milestone, a guided
check that bills two equal installments and watches the contract
reject a resubmitted milestone, and a payer view that lists
invoices addressed to you, verifies each one and its milestone
claim against your approval, pays it, and produces a settlement
proof you can copy for your records. Error messages are plain
language throughout.

demo/runcycle.sh runs the same full cycle from the command line
with cast, including a resubmitted milestone attempt that must
revert.

## Workflow in detail

Payer side, before any billing: approve the purchase order once.
Name the vendor wallet, the total you agreed to pay, and how long
the approval stays open for new invoices. That one transaction is
the whole authorization; the vendor cannot bill you without it,
cannot bill more than the cap, and cannot bill after the expiry.

Merchant side: pick the payer wallet, the amount in tUSD8, a due
date, a memo, the purchase order this invoice settles, and the
milestone it bills. The amount may be the full approved total or
one part of it; the milestone names the piece of work, so the
next installment of the same amount carries the next milestone
reference. One transaction creates the invoice and returns its
id. Share the id with the payer.

Payer side, at payment time: open the payer view in the demo. It
lists every invoice that names you, with the memo, the purchase
order hash, the milestone hash, the merchant, and the amount, and
next to each one the state of your own approval: the cap, what is
already settled, what open invoices reserve, and what is still
available, plus the milestone claim showing which invoice owns
that milestone. Verify the invoice matches the purchase order and
the milestone you expect, approve the contract for the exact
amount, then pay. Two wallet confirmations in total. Afterwards
the demo shows a settlement proof with the invoice id, the
purchase order hash, the milestone hash, the amount, the
transaction hash, the block, and the payment time, ready to copy
into your records.

After payment: the invoice status reads Paid, paidAt holds the
payment time, the settled total on the purchase order grows by
the invoice amount, the merchant balance grows by the same
amount, and the contract balance stays at zero. Anyone can verify
all of this on the explorer or with the read functions getInvoice,
getPurchaseOrder, purchaseOrderRemaining, milestoneStatus,
isOverdue, and invoiceCount.

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
| A milestone reference is required at creation | testCreateRejectsZeroMilestone |
| A resubmitted milestone is rejected while budget remains, open or paid | testResubmittedMilestoneRevertsWhileBudgetRemains |
| Two milestones with the identical amount both settle | testTwoMilestonesSameAmountBothSettle |
| Cancelling frees the milestone for a corrected invoice | testCancelFreesMilestone |
| A paid milestone stays locked forever | testPaidMilestoneStaysLocked |
| The same milestone under another purchase order stays independent | testSameMilestoneDifferentPurchaseOrders |
| The milestone status view agrees with the stored claims | testMilestoneStatusView |
| Expiry gates creation, never payment of an invoice created in time | testExpiryEdgeBothSides |
| Cancelling after expiry frees the milestone but creation stays gated | testCancelAfterExpiryFreesMilestoneButCreationStaysGated |

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

Every milestone billed once. Each invoice names the milestone it
bills, and the contract records which invoice claims that
milestone under the approval. Creating a second invoice for the
same milestone reverts with DuplicateMilestone even while budget
remains under the cap, and a paid milestone stays claimed
forever, so a resubmitted bill for work already paid can never
slip through as if it were the next installment. A different
milestone with the identical amount is accepted, which is exactly
how legitimate equal installments stay possible. Only a cancel
by the merchant while the invoice is unpaid frees a milestone,
so a corrected invoice can be issued for it.

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
AmountExceedsApproval, DuplicatePurchaseOrder, DuplicateMilestone,
NotPayer, and so on), and the web demo translates those errors
into plain language.

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
passes, because the invoice carries its own due date. The due
date itself only marks an invoice as overdue through the
isOverdue view: payment stays possible for as long as the
invoice is Open, and only a cancel by the merchant ends that.
Cancelling after expiry still releases the reservation and
frees the milestone, but the freed milestone cannot be billed
again once the approval has expired. Finance teams that need a
hard payment cutoff should set the invoice due dates
accordingly and cancel stale invoices, because the effective
deadline depends on that cancel, not on the due date alone.

An approval cannot be revised once billing has started. After
the first invoice reserves or settles value, the merchant, cap,
and expiry under that reference are locked. A revision uses a
replacement reference approved for the remaining balance, with
the two references linked in the finance records as described
under How it works.

Milestone references are agreed off chain. The contract enforces
that a milestone is billed at most once per purchase order, but
the merchant picks the milestone reference when creating the
invoice. The protection works when both sides agree the milestone
naming up front, for example one reference per delivery or per
invoice number, so the payer can recognise each claim in the
payer view before paying.

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
merchant naming its milestone, run the guided check to bill two
equal installments and watch the contract reject a resubmitted
milestone, then switch back to the payer, open the payer view,
verify the invoice and its milestone against your approval, pay
it, and copy the settlement proof.

Testnet wallets used for the live run (testnet only, no real
funds):

Merchant and deployer: 0x41747089c2bEd5AB8c1975ae3f42E59C294a3791
Payer: 0xa7f32e07Ad8612b4f59BE699Ef9B8190645e462B

## Deployment

Live on QDay Aevum testnet since 23 Nov 2026. This deployment
adds milestone identity on top of payer approved purchase orders
with a total cap and partial billing up to that cap: every
invoice names the milestone it bills, and each milestone can be
billed only once per purchase order.

InvoicePay contract: 0x7159f69bc4c03598ba74e35b24bf828430310d8d
Deploy tx: 0xb9f683a76fb5f600cc6630accdfe7a532d5a6b909829f2e8c685e1bf74c65a17
Fund payer tx: 0x3afc48ab9d191ba2543b3ba217c0cb01a4e2511a04c71b3611977b98cafe087b
Approve PO 5001 tx: 0xeefd044e9447d5c605d890574df83c7eb96de3ce23169a2922aa4f9d7f4f9be7
Create invoice 0, milestone 1 of PO 5001: 0x23b8acf8707214af5d622b265bfb05e23f483906ab787dc5619621709bda86f8
Resubmit milestone 1 while budget remained, reverted: 0x7c15195264a6fbceb6e3509714c641ea6b3d39560aea97782f3cb94aa543fac1
Create invoice 1, milestone 2 of PO 5001: 0x308c184e8e0eacb04b0d7c32e29b1b876d3ddae278f62cfa2b36ec0ad7baffce
Approve tx: 0xd57f03047e35b47081e60f09ce0ad11ee5de22c8172a5b5f8fc71999ea20dd0a
Pay invoice 0 tx: 0x3b6842a59916f2a4a9568fbb7d3b4ae01b9d0a07bee1d173b29590cb7bd94cbc
Pay invoice 1 tx: 0x725406749d5915f2c79cc9dde7f0968f2e260059d80e7e83e080e76463ea0826
Resubmit milestone 1 after payment, reverted: 0x68a3551d78050d0c989142e748430a402b49d4dfd103f52cba1cd04e761ceb51

The full cycle ran on chain from start to finish. The merchant
funded the payer with 0.8 tUSD8. The payer approved purchase
order PO 5001 for the merchant with a total cap of 1 tUSD8. The
merchant created invoice 0 for milestone 1 at 0.4 tUSD8. A second
invoice naming milestone 1 again was attempted while 0.6 tUSD8 of
budget still remained and the amount would have fitted, and it
reverted with DuplicateMilestone: only the milestone identity
rejected it. The merchant then created invoice 1 for milestone 2
at the same 0.4 tUSD8, which was accepted, so two equal
installments stood side by side. The payer approved the token
allowance and paid both invoices. A final resubmission of
milestone 1 reverted again with DuplicateMilestone, because a
paid milestone stays claimed forever. Final reads show the
purchase order settled at 0.8 tUSD8 with 0.2 tUSD8 still
available, both invoices Paid, both milestones claimed and Paid
in milestoneStatus, and final balances of merchant 1 tUSD8, payer
0, contract 0, which proves nothing is custodied. A read only
simulation of the same resubmission also reverted with
DuplicateMilestone. Look the contract and the transactions up on
the explorer at https://explorer-test.qday.info

This deployment replaces the earlier one at
0xbBbB9BDcbE16B548C5d452a74F2C67EcD66bA363, which had payer
approved purchase orders and partial billing but no milestone
identity, so two equal bills under one approval could not be told
apart. That build in turn replaced the deployment at
0x72334b6555eaf05dc78f7a1519f25699700c38ee, where the merchant
alone asserted the purchase order reference and each purchase
order could carry only one invoice, which in turn replaced the
deployment at 0xf1295031c9454bd067D3763052a0410C536792f6, which
had no purchase order binding, and the first deployment at
0xdCDEab8178e0B2e937af833049260f912E634358, whose bytecode used
the Cancun MCOPY opcode that the Aevum testnet node rejects
inside read calls. The current build targets the paris EVM
version (see evm_version in foundry.toml), contains no MCOPY,
and the read path works: getInvoice returns the full invoice,
getPurchaseOrder returns the full approval record, and
milestoneStatus returns the milestone claim. The earlier
deployments still sit on chain with their own paid invoices, but
the address above is the one to use.

## Technologies

Solidity 0.8, Foundry (forge, cast), ethers.js 6 for the web demo,
QDay Aevum testnet (EVM compatible, chain 44005).

## License

MIT. forge std is used under its own license (see lib/forge-std).
