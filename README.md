# InvoicePay: stablecoin invoices on QDay Aevum

An entry for the Aevum Builder Challenge #1 (QDay): one complete
stablecoin payment flow running on the QDay Aevum testnet.

A merchant creates an invoice denominated in tUSD8 (the Aevum test
stablecoin, 6 decimals). The named payer settles the exact amount on chain.
The contract pulls the tokens straight to the merchant, marks the invoice
paid, and emits an event. The contract never custodies funds.

## The problem

Freelancers and small merchants who invoice in stablecoins today do it with
chat messages and screenshots: "send 25 USDT to this address, invoice 1042."
There is no shared record of what was billed, to whom, or whether it was
paid. InvoicePay puts that record on chain: every invoice has an id, a
merchant, a payer, an amount, a due date, a memo, and a status that only the
real payment can flip to Paid.

## How it works

1. Create. The merchant calls createInvoice with the payer, the amount, the
   due date, and a memo. The invoice is stored with status Open and an
   InvoiceCreated event.
2. Approve. The payer approves the contract to spend the invoice amount
   of tUSD8 (standard ERC20 allowance).
3. Pay. The payer calls payInvoice with the invoice id. The contract checks
   the caller is the named payer and the invoice is still open, marks it
   Paid, then pulls the exact amount from payer to merchant with
   transferFrom and emits InvoicePaid.
4. Cancel. The merchant can cancel an unpaid invoice with cancelInvoice.
   A paid invoice can never be cancelled or paid twice.

Late payment is accepted. The isOverdue view reports whether an open
invoice is past its due date.

## Architecture

```
┌────────────┐   createInvoice    ┌──────────────┐
│  Merchant  │ ─────────────────▶ │              │
└────────────┘                    │              │
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
ordering. The ERC20 interface is declared locally so the project has no
external dependencies beyond forge std (tests only).

src/MockUSD8.sol is a 6 decimal ERC20 used only in tests to stand in
for tUSD8.

test/InvoicePay.t.sol holds 14 Foundry tests covering the full cycle and
every rejection path (wrong payer, double payment, missing allowance,
cancel rules, overdue flag, independent invoices).

script/Deploy.s.sol deploys InvoicePay wired to the official tUSD8
token on Aevum testnet.

demo/index.html is a single file web demo (ethers.js) that adds the
Aevum testnet to a wallet and walks through create, approve, pay, read,
with a live invoice list and plain language error messages.

demo/runcycle.sh runs the same full cycle from the command line
with cast.

## Workflow in detail

Merchant side: pick the payer wallet, the amount in tUSD8, a due date,
and a memo. One transaction creates the invoice and returns its id.
Share the id with the payer.

Payer side: read the invoice first (the demo lists every invoice with
its memo, amount, due date, and status). Approve the contract for the
exact amount, then pay. Two wallet confirmations in total.

After payment: the invoice status reads Paid, paidAt holds the payment
time, the merchant balance grows by the invoice amount, and the contract
balance stays at zero. Anyone can verify all of this on the explorer or
with the read functions getInvoice, isOverdue, and invoiceCount.

## Safety notes

No custody. The contract never holds tokens. payInvoice moves funds with
transferFrom directly from payer to merchant, so there is no pool to
drain and no withdrawal function to abuse.

Exact amount only. The contract pulls the stored invoice amount. The
payer cannot underpay, overpay, or redirect the funds.

Named payer only. payInvoice reverts unless the caller is the payer
recorded at creation. A stranger with an allowance still cannot pay
someone else invoice.

Paid is final. Status flips to Paid before the token transfer (checks
effects interactions ordering), a reentrancy guard covers the payment
path, and a paid or cancelled invoice can never be paid again.

No admin surface. There is no owner, no pause switch, no upgrade path,
and no way to edit an invoice after creation. The only privileged act
is the merchant cancelling their own unpaid invoice.

Failures are explicit. Every rejection path reverts with a named custom
error (NotPayer, InvoiceNotOpen, ZeroAmount, and so on), and the web
demo translates those errors into plain language.

Tested. 14 Foundry tests cover the full cycle plus every rejection
path, including a zero balance assertion on the contract after payment.

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
forge script script/Deploy.s.sol with the RPC URL above, the keystore
at keystore/merchant, and the broadcast flag.

Full create and pay cycle from the CLI: set CONTRACT to the deployed
address and run ./demo/runcycle.sh

Web demo: open demo/index.html in a browser with MetaMask. The live
contract address is prefilled. Connect, create an invoice as the
merchant, switch accounts, approve and pay as the payer, then refresh
the invoice list to see the status flip to Paid.

Testnet wallets used for the live run (testnet only, no real funds):

Merchant and deployer: 0x41747089c2bEd5AB8c1975ae3f42E59C294a3791
Payer: 0xa7f32e07Ad8612b4f59BE699Ef9B8190645e462B

## Deployment

Live on QDay Aevum testnet since 23 Nov 2026.

InvoicePay contract: 0xf1295031c9454bd067D3763052a0410C536792f6
Deploy tx: 0x5ffd001ba40c55f2f469c1cf72b4a6932fb80ef9aa6aaef0ab852dd4ba582175
Create invoice tx: 0x24b195de95a5efbb663f06cb2bd92b30e3182f108d9660ebbd37bcf873b0836a
Approve tx: 0xdbac4894fee8739b5fe05980f25c7580e487832265cdbb0842a792627b3f0de1
Pay invoice tx: 0x0aaf179e0d7a74a819574aa67da14aad07d93e9876db2ac638ccc8463c54fda6

The full cycle ran on chain from start to finish: the merchant created
invoice 0 for 1 tUSD8, the payer approved and paid it, and the merchant
wallet received the full 1 tUSD8. The invoice status is Paid, the payer
balance of tUSD8 is zero, and the contract balance is zero, which proves
nothing is custodied. Look the contract and the transactions up on the
explorer at https://explorer-test.qday.info

This deployment replaces the first one at
0xdCDEab8178e0B2e937af833049260f912E634358. That build used the Cancun
MCOPY opcode, and the Aevum testnet node rejects MCOPY inside read
calls, so getInvoice failed with an invalid opcode error even though
every payment transaction worked. The current build targets the paris
EVM version (see evm_version in foundry.toml), contains no MCOPY, and
the read path works: getInvoice returns the full invoice including the
memo. The first deployment still sits on chain with its own paid
invoice, but the address above is the one to use.

## Technologies

Solidity 0.8, Foundry (forge, cast), ethers.js 6 for the web demo,
QDay Aevum testnet (EVM compatible, chain 44005).

## License

MIT. forge std is used under its own license (see lib/forge-std).
