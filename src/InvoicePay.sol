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
///      stablecoin, 6 decimals). Every invoice is bound to a purchase order
///      reference (a bytes32 hash of the off-chain purchase order). The
///      contract rejects a second invoice for the same purchase order from
///      the same merchant while the first is not cancelled, so one purchase
///      order can only ever be settled once. Cancelling an invoice frees
///      its purchase order reference. The named payer settles the exact
///      amount; the contract pulls the tokens straight to the merchant with
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
        bytes32 poRef; // hash of the purchase order this invoice settles
        Status status;
    }

    /// @notice The stablecoin every invoice is denominated in (tUSD8 on Aevum).
    IERC20 public immutable token;

    /// @notice All invoices ever created. The array index is the invoice id.
    Invoice[] public invoices;

    /// @dev Active invoice per purchase order, keyed by merchant and poRef.
    ///      Stores invoiceId + 1 so that 0 means "no active invoice".
    ///      An entry is removed only when its invoice is cancelled, so a
    ///      paid purchase order stays locked forever.
    mapping(bytes32 => uint256) private _poInvoice;

    uint256 private _lock = 1;

    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed merchant,
        address indexed payer,
        uint256 amount,
        uint256 dueDate,
        string memo,
        bytes32 poRef
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
    error ZeroPurchaseOrder();
    error DuplicatePurchaseOrder();

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

    /// @notice Create a new invoice bound to a purchase order. The caller
    ///         becomes the merchant. Reverts if this merchant already has a
    ///         non-cancelled invoice for the same purchase order reference.
    /// @param payer The only address allowed to settle this invoice.
    /// @param amount Amount in token base units (e.g. 25_000000 = 25 tUSD8).
    /// @param dueDate Unix timestamp after which the invoice is overdue.
    /// @param memo Human readable note, e.g. "Invoice #1042, design work".
    /// @param poRef Hash of the purchase order being settled, e.g.
    ///        keccak256("PO 1042"). Must be non-zero and unique per merchant
    ///        among non-cancelled invoices.
    /// @return invoiceId Id of the new invoice.
    function createInvoice(address payer, uint256 amount, uint256 dueDate, string calldata memo, bytes32 poRef)
        external
        returns (uint256 invoiceId)
    {
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (dueDate <= block.timestamp) revert DueDateInPast();
        if (poRef == bytes32(0)) revert ZeroPurchaseOrder();

        bytes32 key = _poKey(msg.sender, poRef);
        if (_poInvoice[key] != 0) revert DuplicatePurchaseOrder();

        invoiceId = invoices.length;
        invoices.push(
            Invoice({
                merchant: msg.sender,
                payer: payer,
                amount: amount,
                dueDate: dueDate,
                paidAt: 0,
                memo: memo,
                poRef: poRef,
                status: Status.Open
            })
        );
        _poInvoice[key] = invoiceId + 1;

        emit InvoiceCreated(invoiceId, msg.sender, payer, amount, dueDate, memo, poRef);
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
    ///         Cancelling frees the purchase order reference, so a fresh
    ///         invoice can be created for the same purchase order.
    function cancelInvoice(uint256 invoiceId) external {
        if (invoiceId >= invoices.length) revert InvoiceNotFound();
        Invoice storage inv = invoices[invoiceId];
        if (msg.sender != inv.merchant) revert NotMerchant();
        if (inv.status != Status.Open) revert InvoiceNotOpen();

        inv.status = Status.Cancelled;
        delete _poInvoice[_poKey(inv.merchant, inv.poRef)];
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

    /// @notice Look up the active invoice bound to a purchase order.
    /// @return active True when a non-cancelled invoice exists for the pair.
    /// @return invoiceId The bound invoice id (meaningful only if active).
    function purchaseOrderStatus(address merchant, bytes32 poRef) external view returns (bool active, uint256 invoiceId) {
        uint256 stored = _poInvoice[_poKey(merchant, poRef)];
        if (stored == 0) return (false, 0);
        return (true, stored - 1);
    }

    function _poKey(address merchant, bytes32 poRef) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(merchant, poRef));
    }
}
