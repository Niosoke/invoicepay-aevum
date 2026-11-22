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
///      reference (a bytes32 hash of the off-chain purchase order) that the
///      payer has approved on chain beforehand: `approvePurchaseOrder`
///      records which merchant may bill against the reference, the total
///      amount cap, and an expiry. The merchant can then create invoices
///      against that approval, in full or in parts, but the settled plus
///      reserved total can never exceed the approved cap. Once the cap is
///      fully settled the purchase order is locked forever, so one
///      approved purchase order can never be settled beyond its approved
///      total. Cancelling an unpaid invoice releases its reservation.
///      Every invoice also carries its own milestone reference (a bytes32
///      hash of the milestone or invoice number it bills). The milestone
///      reference must be unique within its purchase order approval: a
///      second invoice naming the same milestone reverts even while the
///      purchase order still has budget left, and even after the first
///      invoice was paid. That is how the payer tells a resubmitted bill
///      for work already paid apart from a legitimate next installment
///      that happens to carry the same amount: installments carry
///      different milestone references, resubmissions do not. Cancelling
///      an unpaid invoice frees its milestone reference so a corrected
///      invoice can be issued. The named payer settles each invoice in
///      full; the contract pulls the tokens straight to the merchant with
///      `transferFrom`, marks the invoice paid and emits an event. The
///      contract never custodies funds.
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
        bytes32 milestoneRef; // hash of the milestone this invoice bills
        Status status;
    }

    /// @notice A purchase order approved by a payer.
    /// @dev Invariant: settled + live <= amount at all times. `live` is the
    ///      sum of the amounts of open invoices against this purchase
    ///      order, so a merchant cannot reserve more than the cap with
    ///      unpaid invoices either.
    struct PurchaseOrder {
        address merchant; // the only merchant allowed to bill this reference
        uint256 amount; // approved total cap, in token base units
        uint256 expiry; // unix timestamp; new invoices are rejected after it
        uint256 settled; // amount already paid against this purchase order
        uint256 live; // amount reserved by open invoices
        bool exists;
    }

    /// @notice The stablecoin every invoice is denominated in (tUSD8 on Aevum).
    IERC20 public immutable token;

    /// @notice All invoices ever created. The array index is the invoice id.
    Invoice[] public invoices;

    /// @dev Purchase order approvals, keyed by payer and poRef. The payer
    ///      is the approver, so the same reference approved by two
    ///      different payers is two independent purchase orders.
    mapping(bytes32 => PurchaseOrder) private _purchaseOrders;

    /// @dev The invoice that currently claims a milestone, keyed by payer,
    ///      poRef and milestoneRef. Stores invoiceId + 1 so that 0 means
    ///      the milestone is free. Set at creation, kept after payment (a
    ///      paid milestone stays locked forever), cleared on cancel.
    mapping(bytes32 => uint256) private _milestoneInvoice;

    uint256 private _lock = 1;

    event PurchaseOrderApproved(
        address indexed payer, address indexed merchant, bytes32 indexed poRef, uint256 amount, uint256 expiry
    );
    event InvoiceCreated(
        uint256 indexed invoiceId,
        address indexed merchant,
        address indexed payer,
        uint256 amount,
        uint256 dueDate,
        string memo,
        bytes32 poRef,
        bytes32 milestoneRef
    );
    event InvoicePaid(uint256 indexed invoiceId, address indexed payer, address indexed merchant, uint256 amount, uint256 paidAt);
    event InvoiceCancelled(uint256 indexed invoiceId, address indexed merchant);

    error ZeroAddress();
    error ZeroAmount();
    error DueDateInPast();
    error ExpiryInPast();
    error InvoiceNotFound();
    error NotPayer();
    error NotMerchant();
    error InvoiceNotOpen();
    error TransferFailed();
    error ReentrantCall();
    error ZeroPurchaseOrder();
    error DuplicatePurchaseOrder();
    error PurchaseOrderNotApproved();
    error PurchaseOrderAlreadyApproved();
    error WrongMerchant();
    error PurchaseOrderExpired();
    error AmountExceedsApproval();
    error ZeroMilestone();
    error DuplicateMilestone();

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

    /// @notice Approve a purchase order. The caller is the payer: only this
    ///         payer can later be billed against the reference, and only by
    ///         the named merchant, up to the approved total, until expiry.
    ///         An approval that has not been used yet (nothing settled and
    ///         no open invoice) can be replaced by approving again; once
    ///         money is reserved or settled against it, its terms are
    ///         locked.
    /// @param merchant The only merchant allowed to create invoices
    ///        against this purchase order.
    /// @param poRef Hash of the purchase order, e.g. keccak256("PO 1042").
    /// @param amount Approved total cap in token base units. Invoices may
    ///        settle it in parts, but never beyond this total.
    /// @param expiry Unix timestamp after which new invoices against this
    ///        purchase order are rejected. Invoices created before expiry
    ///        can still be paid afterwards.
    function approvePurchaseOrder(address merchant, bytes32 poRef, uint256 amount, uint256 expiry) external {
        if (merchant == address(0)) revert ZeroAddress();
        if (poRef == bytes32(0)) revert ZeroPurchaseOrder();
        if (amount == 0) revert ZeroAmount();
        if (expiry <= block.timestamp) revert ExpiryInPast();

        PurchaseOrder storage po = _purchaseOrders[_poKey(msg.sender, poRef)];
        if (po.exists && (po.settled != 0 || po.live != 0)) revert PurchaseOrderAlreadyApproved();

        po.merchant = merchant;
        po.amount = amount;
        po.expiry = expiry;
        po.settled = 0;
        po.live = 0;
        po.exists = true;

        emit PurchaseOrderApproved(msg.sender, merchant, poRef, amount, expiry);
    }

    /// @notice Create a new invoice against a purchase order the payer has
    ///         approved. The caller becomes the merchant and must be the
    ///         merchant named in the approval. Reverts when there is no
    ///         approval, the approval names another merchant, the approval
    ///         has expired, the purchase order is already fully settled,
    ///         the milestone reference is already claimed by another
    ///         invoice under this approval, or the amount would push the
    ///         settled plus reserved total past the approved cap.
    /// @param payer The only address allowed to settle this invoice. Must
    ///        have approved this purchase order for the caller.
    /// @param amount Amount in token base units (e.g. 25_000000 = 25 tUSD8).
    /// @param dueDate Unix timestamp after which the invoice is overdue.
    /// @param memo Human readable note, e.g. "Invoice #1042, design work".
    /// @param poRef Hash of the purchase order being settled, e.g.
    ///        keccak256("PO 1042"). Must be non-zero and approved by the
    ///        payer for the caller.
    /// @param milestoneRef Hash of the milestone this invoice bills, e.g.
    ///        keccak256("PO 1042 milestone 1"). Must be non-zero and
    ///        unique within the purchase order approval: a resubmitted
    ///        bill for the same milestone reverts even while budget
    ///        remains, while a different milestone with the same amount
    ///        is fine.
    /// @return invoiceId Id of the new invoice.
    function createInvoice(
        address payer,
        uint256 amount,
        uint256 dueDate,
        string calldata memo,
        bytes32 poRef,
        bytes32 milestoneRef
    ) external returns (uint256 invoiceId) {
        if (payer == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (dueDate <= block.timestamp) revert DueDateInPast();
        if (poRef == bytes32(0)) revert ZeroPurchaseOrder();
        if (milestoneRef == bytes32(0)) revert ZeroMilestone();

        PurchaseOrder storage po = _purchaseOrders[_poKey(payer, poRef)];
        if (!po.exists) revert PurchaseOrderNotApproved();
        if (po.merchant != msg.sender) revert WrongMerchant();
        if (block.timestamp > po.expiry) revert PurchaseOrderExpired();
        if (po.settled == po.amount) revert DuplicatePurchaseOrder();
        if (_milestoneInvoice[_milestoneKey(payer, poRef, milestoneRef)] != 0) revert DuplicateMilestone();
        if (amount > po.amount - po.settled - po.live) revert AmountExceedsApproval();

        po.live += amount;

        invoiceId = invoices.length;
        _milestoneInvoice[_milestoneKey(payer, poRef, milestoneRef)] = invoiceId + 1;
        invoices.push(
            Invoice({
                merchant: msg.sender,
                payer: payer,
                amount: amount,
                dueDate: dueDate,
                paidAt: 0,
                memo: memo,
                poRef: poRef,
                milestoneRef: milestoneRef,
                status: Status.Open
            })
        );

        emit InvoiceCreated(invoiceId, msg.sender, payer, amount, dueDate, memo, poRef, milestoneRef);
    }

    /// @notice Settle an invoice in full. The payer must first approve this
    ///         contract to spend at least the invoice amount of tUSD8.
    ///         Funds go directly to the merchant; nothing is custodied here.
    ///         The payment moves the invoice amount from the reserved total
    ///         to the settled total of its purchase order. The milestone
    ///         stays claimed after payment, so the same milestone can
    ///         never be billed again.
    function payInvoice(uint256 invoiceId) external nonReentrant {
        if (invoiceId >= invoices.length) revert InvoiceNotFound();
        Invoice storage inv = invoices[invoiceId];
        if (inv.status != Status.Open) revert InvoiceNotOpen();
        if (msg.sender != inv.payer) revert NotPayer();

        // Effects before interaction: a reentrant token cannot double-pay.
        inv.status = Status.Paid;
        inv.paidAt = block.timestamp;

        PurchaseOrder storage po = _purchaseOrders[_poKey(inv.payer, inv.poRef)];
        po.live -= inv.amount;
        po.settled += inv.amount;

        bool ok = token.transferFrom(msg.sender, inv.merchant, inv.amount);
        if (!ok) revert TransferFailed();

        emit InvoicePaid(invoiceId, msg.sender, inv.merchant, inv.amount, inv.paidAt);
    }

    /// @notice Cancel an unpaid invoice. Only the merchant can cancel.
    ///         Cancelling releases the amount the invoice reserved against
    ///         its purchase order and frees its milestone reference, so a
    ///         corrected invoice can be created.
    function cancelInvoice(uint256 invoiceId) external {
        if (invoiceId >= invoices.length) revert InvoiceNotFound();
        Invoice storage inv = invoices[invoiceId];
        if (msg.sender != inv.merchant) revert NotMerchant();
        if (inv.status != Status.Open) revert InvoiceNotOpen();

        inv.status = Status.Cancelled;
        _purchaseOrders[_poKey(inv.payer, inv.poRef)].live -= inv.amount;
        _milestoneInvoice[_milestoneKey(inv.payer, inv.poRef, inv.milestoneRef)] = 0;
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

    /// @notice Read the purchase order a payer approved for a reference.
    ///         Returns a record with exists set to false when the payer
    ///         has not approved that reference.
    function getPurchaseOrder(address payer, bytes32 poRef) external view returns (PurchaseOrder memory) {
        return _purchaseOrders[_poKey(payer, poRef)];
    }

    /// @notice Amount still available under an approved purchase order:
    ///         the approved cap minus what is settled and what open
    ///         invoices reserve. Zero when there is no approval.
    function purchaseOrderRemaining(address payer, bytes32 poRef) external view returns (uint256) {
        PurchaseOrder storage po = _purchaseOrders[_poKey(payer, poRef)];
        if (!po.exists) return 0;
        return po.amount - po.settled - po.live;
    }

    /// @notice Whether a milestone reference is claimed under a purchase
    ///         order approval, and by which invoice. `used` is false when
    ///         the milestone is free (never billed, or its invoice was
    ///         cancelled). When used, `invoiceId` and `status` describe
    ///         the claiming invoice: Open while unpaid, Paid once settled
    ///         (a paid milestone stays claimed forever).
    function milestoneStatus(address payer, bytes32 poRef, bytes32 milestoneRef)
        external
        view
        returns (bool used, uint256 invoiceId, Status status)
    {
        uint256 stored = _milestoneInvoice[_milestoneKey(payer, poRef, milestoneRef)];
        if (stored == 0) return (false, 0, Status.Open);
        invoiceId = stored - 1;
        return (true, invoiceId, invoices[invoiceId].status);
    }

    function _poKey(address payer, bytes32 poRef) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(payer, poRef));
    }

    function _milestoneKey(address payer, bytes32 poRef, bytes32 milestoneRef) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(payer, poRef, milestoneRef));
    }
}
