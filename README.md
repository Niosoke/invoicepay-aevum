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
Aevum testnet to a wallet and walks through create, approve, pay, read.

demo/runcycle.sh runs the same full cycle from the command line
with cast.

## Network facts (QDay Aevum testnet)

Chain ID: 44005 (0xABE5)
RPC: https://rpc-test.qday.info
Explorer: https://explorer-test.qday.info
Gas token: tQDAY (18 decimals), from https://faucet.qday.info
Stablecoin: tUSD8 at 0x456569838f1d43009A91ebA4263147Afd7233483 (6 decimals)

## Run it

Tests: forge test

Deploy (needs a funded keystore wallet, see below):
forge script script/Deploy.s.sol with the RPC URL above, the keystore
at keystore/merchant, and the broadcast flag.

Full create and pay cycle from the CLI: set CONTRACT to the deployed
address and run ./demo/runcycle.sh

Web demo: open demo/index.html in a browser with MetaMask, paste the
deployed contract address, connect, create, pay.

Testnet wallets used for the live run (testnet only, no real funds):

Merchant and deployer: 0x41747089c2bEd5AB8c1975ae3f42E59C294a3791
Payer: 0xa7f32e07Ad8612b4f59BE699Ef9B8190645e462B

## Deployment

Live on QDay Aevum testnet since 23 Nov 2026.

InvoicePay contract: 0xdCDEab8178e0B2e937af833049260f912E634358
Deploy tx: 0xd2570bd4ada7a5c28c9d699701b38af2e9498224ad949378868dc15cd28d7f8e
Create invoice tx: 0x056d8d74ec4c27a83932ed5f7f6ca38203c621cc65b1b2298a2c1b587e287f8c
Approve tx: 0xd91db45108b4756288d484df4f3d98a12fadc87248c9b396ec78675e66459ae2
Pay invoice tx: 0x493134a9a3cb5da203dbaebfd30358cea661a3a5d7a81ec6e7607ea0caf82aa2

The full cycle ran on chain end to end: the merchant created invoice 0
for 1 tUSD8, the payer approved and paid it, and the merchant wallet
received the full 1 tUSD8. The invoice status is Paid and the payer
balance of tUSD8 is now zero. Look the contract and the transactions up
on the explorer at https://explorer-test.qday.info

## Technologies

Solidity 0.8, Foundry (forge, cast), ethers.js 6 for the web demo,
QDay Aevum testnet (EVM compatible, chain 44005).

## License

MIT. forge std is used under its own license (see lib/forge-std).
