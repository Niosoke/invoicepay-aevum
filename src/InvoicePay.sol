// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-20 interface used by InvoicePay.
/// @dev Written locally so the project has zero external dependencies
///      beyond forge-std (tests only).
interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function decimals() external view returns (uint8);
}

/// @title InvoicePay
/// @notice On-chain stablecoin invoices for the QDay Aevum testnet.
/// @dev A merchant creates an invoice denominated in tUSD8 (the Aevum test
///      stablecoin, 6 decimals). The named payer settles the exact amount;
///      the contract pulls the tokens straight to the merchant with
///      `transferFrom`, marks the invoice paid and emits an event.
///      The contract never custodies funds.
contract InvoicePay {
    enum Status {
        Open,
        Paid,
        Cancelled
    }

    struct Invoice {
        address merchant;
        address payer;
        uint256 amount; // in token base units (tUSD8 has 6 decimals)
        uint256 dueDate; // unix timestamp
        uint256 paidAt; // unix timestamp, 0 while unpaid
        string memo;
        Status status;
    }

    /// @notice The stablecoin every invoice is denominated in (tUSD8 on Aevum).
    IERC20 public immutable token;

    /// @notice All invoices ever created. The array index is the invoice id.
    Invoice[] public invoices;

    uint256 private _lock = 1;

    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed merchant,
        address indexed payer,
        uint256 amount,
        uint256 dueDate,
        string memo
    );
    event InvoicePaid(uint256 indexed invoiceId, address indexed payer, address indexed merchant, uint256 amount, uint256 paidAt);
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed merchant);

    error ZeroAddress();
    error ZeroAmount();
    error DueDateInPast();
    error InvoiceNotFound();
    error NotPayer();
    error NotMerchant();
    error InvoiceNotOpen();
    error TransferFailed();
    error ReentrantCall();

    modifier nonReentrant() {
        if (_lock != 1) revert ReentrantCall();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address tokenAddress) {
        if (tokenAddress == address(0)) revert ZeroAddress();
        token = IERC20(tokenAddress);
    }

    /// @notice Create a new invoice. The caller becomes the merchant.
    /// @param payer The only address allowed to settle this invoice.
    /// @param amount Amount in token base units (e.g. 25_000000 = 25 tUSD8).
    /// @param dueDate Unix timestamp after which the invoice is overdue.
    /// @param memo Human readable note, e.g. "Invoice #1042, design work".
    /// @return invoiceId Id of the new invoice.
    function createInvoice(address payer, uint256 amount, uint256 dueDate, string calldata memo)
        external
        returns (uint256 invoiceId)
    {
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (dueDate <= block.timestamp) revert DueDateInPast();

        invoiceId = invoices.length;
        invoices.push(
            Invoice({
                merchant: msg.sender,
                payer: payer,
                amount: amount,
                dueDate: dueDate,
                paidAt: 0,
                memo: memo,
                status: Status.Open
            })
        );

        emit InvoiceCreated(invoiceId, msg.sender, payer, amount, dueDate, memo);
    }

    /// @notice Settle an invoice in full. The payer must first approve this
    ///         contract to spend at least the invoice amount of tUSD8.
    ///         Funds go directly to the merchant; nothing is custodied here.
    function payInvoice(uint256 invoiceId) external nonReentrant {
        if (invoiceId >= invoices.length) revert InvoiceNotFound();
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Open) revert InvoiceNotOpen();
        if (msg.sender != inv.payer) revert NotPayer();

        // Effects before interaction: a reentrant token cannot double-pay.
        inv.status = Status.Paid;
        inv.paidAt = block.timestamp;

        bool ok = token.transferFrom(msg.sender, inv.merchant, inv.amount);
        if (!ok) revert TransferFailed();

        emit InvoicePaid(invoiceId, msg.sender, inv.merchant, inv.amount, inv.paidAt);
    }

    /// @notice Cancel an unpaid invoice. Only the merchant can cancel.
    function cancelInvoice(uint256 invoiceId) external {
        if (invoiceId >= invoices.length) revert InvoiceNotFound();
        Invoice storage inv = invoices[invoiceId];
        if (msg.sender != inv.merchant) revert NotMerchant();
        if (inv.status != Status.Open) revert InvoiceNotOpen();

        inv.status = Status.Cancelled;
        emit InvoiceCancelled(invoiceId, msg.sender);
    }

    /// @notice Read one invoice.
    function getInvoice(uint256 invoiceId) external view returns (Invoice memory) {
        if (invoiceId >= invoices.length) revert InvoiceNotFound();
        return invoices[invoiceId];
    }

    /// @notice True when an open invoice is past its due date.
    function isOverdue(uint256 invoiceId) external view returns (bool) {
        if (invoiceId >= invoices.length) revert InvoiceNotFound();
        Invoice storage inv = invoices[invoiceId];
        return inv.status == Status.Open && block.timestamp > inv.dueDate;
    }

    /// @notice Total number of invoices ever created.
    function invoiceCount() external view returns (uint256) {
        return invoices.length;
    }
}
