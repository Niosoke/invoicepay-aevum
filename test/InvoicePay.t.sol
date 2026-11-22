// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {InvoicePay} from "../src/InvoicePay.sol";
import {MockUSD8} from "../src/MockUSD8.sol";

contract InvoicePayTest is Test {
    MockUSD8 internal token;
    InvoicePay internal pay;

    address internal merchant = makeAddr("merchant");
    address internal payer = makeAddr("payer");
    address internal stranger = makeAddr("stranger");

    uint256 internal constant AMOUNT = 25_000000; // 25 tUSD8 (6 decimals)
    uint256 internal dueDate;
    uint256 internal poExpiry;
    uint256 internal poCounter;
    uint256 internal milestoneCounter;

    function setUp() public {
        token = new MockUSD8();
        pay = new InvoicePay(address(token));
        dueDate = block.timestamp + 7 days;
        poExpiry = block.timestamp + 30 days;
        token.mint(payer, 1_000_000000); // 1,000 tUSD8
    }

    /// @dev Unique purchase order reference per call, so the cycle tests
    ///      each run against their own approved purchase order.
    function _nextPo() internal returns (bytes32) {
        poCounter++;
        return keccak256(abi.encodePacked("PO ", poCounter));
    }

    /// @dev Unique milestone reference per call, so tests that bill the
    ///      same purchase order several times never collide on the
    ///      milestone identity unless the test wants them to.
    function _nextMilestone() internal returns (bytes32) {
        milestoneCounter++;
        return keccak256(abi.encodePacked("milestone ", milestoneCounter));
    }

    /// @dev The payer approves a purchase order for the merchant.
    function _approvePo(bytes32 poRef, uint256 amount) internal {
        vm.prank(payer);
        pay.approvePurchaseOrder(merchant, poRef, amount, poExpiry);
    }

    function _create() internal returns (uint256 id) {
        bytes32 poRef = _nextPo();
        _approvePo(poRef, AMOUNT);
        vm.prank(merchant);
        id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice 1042, design work", poRef, _nextMilestone());
    }

    function _createWithPo(bytes32 poRef) internal returns (uint256 id) {
        _approvePo(poRef, AMOUNT);
        vm.prank(merchant);
        id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice for purchase order", poRef, _nextMilestone());
    }

    function _createWithPoNoApprove(bytes32 poRef) internal returns (uint256 id) {
        vm.prank(merchant);
        id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice for purchase order", poRef, _nextMilestone());
    }

    function _pay(uint256 id) internal {
        InvoicePay.Invoice memory inv = pay.getInvoice(id);
        vm.startPrank(inv.payer);
        token.approve(address(pay), inv.amount);
        pay.payInvoice(id);
        vm.stopPrank();
    }

    function testCreateInvoice() public {
        bytes32 poRef = keccak256("PO 1042");
        bytes32 milestoneRef = keccak256("PO 1042 milestone 1");
        _approvePo(poRef, AMOUNT);
        vm.prank(merchant);
        uint256 id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice for purchase order", poRef, milestoneRef);
        assertEq(id, 0);
        assertEq(pay.invoiceCount(), 1);

        InvoicePay.Invoice memory inv = pay.getInvoice(id);
        assertEq(inv.merchant, merchant);
        assertEq(inv.payer, payer);
        assertEq(inv.amount, AMOUNT);
        assertEq(inv.dueDate, dueDate);
        assertEq(inv.paidAt, 0);
        assertEq(inv.memo, "Invoice for purchase order");
        assertEq(inv.poRef, poRef);
        assertEq(inv.milestoneRef, milestoneRef);
        assertTrue(inv.status == InvoicePay.Status.Open);
        assertFalse(pay.isOverdue(id));

        // The invoice amount is reserved against the purchase order.
        InvoicePay.PurchaseOrder memory po = pay.getPurchaseOrder(payer, poRef);
        assertTrue(po.exists);
        assertEq(po.merchant, merchant);
        assertEq(po.amount, AMOUNT);
        assertEq(po.settled, 0);
        assertEq(po.live, AMOUNT);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), 0);
    }

    function testCreateRejectsZeroPayer() public {
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.ZeroAddress.selector);
        pay.createInvoice(address(0), AMOUNT, dueDate, "x", _nextPo(), _nextMilestone());
    }

    function testCreateRejectsZeroAmount() public {
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.ZeroAmount.selector);
        pay.createInvoice(payer, 0, dueDate, "x", _nextPo(), _nextMilestone());
    }

    function testCreateRejectsPastDueDate() public {
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DueDateInPast.selector);
        pay.createInvoice(payer, AMOUNT, block.timestamp, "x", _nextPo(), _nextMilestone());
    }

    function testPayInvoiceFullCycle() public {
        uint256 id = _create();

        vm.startPrank(payer);
        token.approve(address(pay), AMOUNT);
        pay.payInvoice(id);
        vm.stopPrank();

        InvoicePay.Invoice memory inv = pay.getInvoice(id);
        assertTrue(inv.status == InvoicePay.Status.Paid);
        assertEq(inv.paidAt, block.timestamp);
        assertEq(token.balanceOf(merchant), AMOUNT);
        assertEq(token.balanceOf(payer), 1_000_000000 - AMOUNT);
        assertEq(token.balanceOf(address(pay)), 0); // nothing custodied

        // The payment moved the amount from reserved to settled.
        InvoicePay.PurchaseOrder memory po = pay.getPurchaseOrder(payer, inv.poRef);
        assertEq(po.settled, AMOUNT);
        assertEq(po.live, 0);
    }

    function testPayRejectsWrongPayer() public {
        uint256 id = _create();
        token.mint(stranger, AMOUNT);
        vm.startPrank(stranger);
        token.approve(address(pay), AMOUNT);
        vm.expectRevert(InvoicePay.NotPayer.selector);
        pay.payInvoice(id);
        vm.stopPrank();
    }

    function testPayRejectsWithoutAllowance() public {
        uint256 id = _create();
        vm.prank(payer);
        vm.expectRevert(); // token allowance check
        pay.payInvoice(id);
    }

    function testPayRejectsDoublePayment() public {
        uint256 id = _create();
        vm.startPrank(payer);
        token.approve(address(pay), AMOUNT * 2);
        pay.payInvoice(id);
        vm.expectRevert(InvoicePay.InvoiceNotOpen.selector);
        pay.payInvoice(id);
        vm.stopPrank();
    }

    function testPayRejectsUnknownInvoice() public {
        vm.prank(payer);
        vm.expectRevert(InvoicePay.InvoiceNotFound.selector);
        pay.payInvoice(99);
    }

    function testCancelInvoice() public {
        uint256 id = _create();
        vm.prank(merchant);
        pay.cancelInvoice(id);

        InvoicePay.Invoice memory inv = pay.getInvoice(id);
        assertTrue(inv.status == InvoicePay.Status.Cancelled);

        // The reservation is released.
        assertEq(pay.purchaseOrderRemaining(payer, inv.poRef), AMOUNT);

        // A cancelled invoice can no longer be paid.
        vm.startPrank(payer);
        token.approve(address(pay), AMOUNT);
        vm.expectRevert(InvoicePay.InvoiceNotOpen.selector);
        pay.payInvoice(id);
        vm.stopPrank();
    }

    function testCancelRejectsNonMerchant() public {
        uint256 id = _create();
        vm.prank(payer);
        vm.expectRevert(InvoicePay.NotMerchant.selector);
        pay.cancelInvoice(id);
    }

    function testCancelRejectsPaidInvoice() public {
        uint256 id = _create();
        vm.startPrank(payer);
        token.approve(address(pay), AMOUNT);
        pay.payInvoice(id);
        vm.stopPrank();

        vm.prank(merchant);
        vm.expectRevert(InvoicePay.InvoiceNotOpen.selector);
        pay.cancelInvoice(id);
    }

    function testOverdueFlag() public {
        uint256 id = _create();
        assertFalse(pay.isOverdue(id));
        vm.warp(dueDate + 1);
        assertTrue(pay.isOverdue(id));

        // Late payment is still accepted and clears the overdue flag.
        vm.startPrank(payer);
        token.approve(address(pay), AMOUNT);
        pay.payInvoice(id);
        vm.stopPrank();
        assertFalse(pay.isOverdue(id));
    }

    function testMultipleInvoicesAreIndependent() public {
        uint256 a = _create();
        uint256 b = _create();
        assertEq(a, 0);
        assertEq(b, 1);

        vm.startPrank(payer);
        token.approve(address(pay), AMOUNT);
        pay.payInvoice(b);
        vm.stopPrank();

        assertTrue(pay.getInvoice(a).status == InvoicePay.Status.Open);
        assertTrue(pay.getInvoice(b).status == InvoicePay.Status.Paid);
    }

    // ------------------------------------------------------------------
    // Purchase order approval
    // ------------------------------------------------------------------

    function testApprovePurchaseOrder() public {
        bytes32 poRef = keccak256("PO 1042");

        vm.expectEmit(true, true, true, true);
        emit InvoicePay.PurchaseOrderApproved(payer, merchant, poRef, AMOUNT, poExpiry);
        vm.prank(payer);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT, poExpiry);

        InvoicePay.PurchaseOrder memory po = pay.getPurchaseOrder(payer, poRef);
        assertTrue(po.exists);
        assertEq(po.merchant, merchant);
        assertEq(po.amount, AMOUNT);
        assertEq(po.expiry, poExpiry);
        assertEq(po.settled, 0);
        assertEq(po.live, 0);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), AMOUNT);
    }

    function testApproveRejectsBadInputs() public {
        bytes32 poRef = keccak256("PO 1042");

        vm.prank(payer);
        vm.expectRevert(InvoicePay.ZeroAddress.selector);
        pay.approvePurchaseOrder(address(0), poRef, AMOUNT, poExpiry);

        vm.prank(payer);
        vm.expectRevert(InvoicePay.ZeroPurchaseOrder.selector);
        pay.approvePurchaseOrder(merchant, bytes32(0), AMOUNT, poExpiry);

        vm.prank(payer);
        vm.expectRevert(InvoicePay.ZeroAmount.selector);
        pay.approvePurchaseOrder(merchant, poRef, 0, poExpiry);

        vm.prank(payer);
        vm.expectRevert(InvoicePay.ExpiryInPast.selector);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT, block.timestamp);
    }

    function testCreateRejectsZeroPurchaseOrder() public {
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.ZeroPurchaseOrder.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "x", bytes32(0), _nextMilestone());
    }

    function testCreateRejectsWithoutApproval() public {
        bytes32 poRef = keccak256("PO 9999");

        // The payer never approved this reference.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.PurchaseOrderNotApproved.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "no approval", poRef, _nextMilestone());

        assertEq(pay.invoiceCount(), 0);
        assertFalse(pay.getPurchaseOrder(payer, poRef).exists);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), 0);
    }

    function testCreateRejectsWrongMerchant() public {
        bytes32 poRef = keccak256("PO 1042");
        address otherMerchant = makeAddr("otherMerchant");
        _approvePo(poRef, AMOUNT);

        // The approval names the merchant, so anyone else is rejected.
        vm.prank(otherMerchant);
        vm.expectRevert(InvoicePay.WrongMerchant.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "wrong merchant", poRef, _nextMilestone());

        // The named merchant can still bill against it.
        uint256 id = _createWithPoNoApprove(poRef);
        assertEq(pay.getInvoice(id).merchant, merchant);
    }

    function testCreateRejectsAmountAboveApproval() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT);

        vm.prank(merchant);
        vm.expectRevert(InvoicePay.AmountExceedsApproval.selector);
        pay.createInvoice(payer, AMOUNT + 1, dueDate, "over the cap", poRef, _nextMilestone());
    }

    function testCreateRejectsExpiredApproval() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 shortExpiry = block.timestamp + 1 days;
        vm.prank(payer);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT, shortExpiry);

        vm.warp(shortExpiry + 1);
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.PurchaseOrderExpired.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "too late", poRef, _nextMilestone());
    }

    function testPayAfterApprovalExpiry() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 shortExpiry = block.timestamp + 1 days;
        vm.prank(payer);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT, shortExpiry);

        uint256 id = _createWithPoNoApprove(poRef);

        // Expiry gates new invoices only. An invoice created in time can
        // still be settled after the approval expiry passes.
        vm.warp(shortExpiry + 1);
        _pay(id);
        assertTrue(pay.getInvoice(id).status == InvoicePay.Status.Paid);
    }

    function testReapproveUnusedPurchaseOrder() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT);

        // Nothing has been billed yet, so the payer can correct the terms.
        _approvePo(poRef, AMOUNT * 2);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), AMOUNT * 2);

        vm.prank(merchant);
        uint256 id = pay.createInvoice(payer, AMOUNT * 2, dueDate, "corrected amount", poRef, _nextMilestone());
        assertEq(pay.getInvoice(id).amount, AMOUNT * 2);
    }

    function testApprovalLockedOnceInUse() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 id = _createWithPo(poRef);

        // An open invoice reserves against the approval, so its terms
        // can no longer be rewritten.
        vm.prank(payer);
        vm.expectRevert(InvoicePay.PurchaseOrderAlreadyApproved.selector);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT * 2, poExpiry);

        // Same after settlement.
        _pay(id);
        vm.prank(payer);
        vm.expectRevert(InvoicePay.PurchaseOrderAlreadyApproved.selector);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT * 2, poExpiry);
    }

    // ------------------------------------------------------------------
    // Settlement against the approved cap
    // ------------------------------------------------------------------

    function testSecondInvoiceBeyondApprovalReverts() public {
        bytes32 poRef = keccak256("PO 1042");
        _createWithPo(poRef);

        // The open invoice already reserves the full approved total.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.AmountExceedsApproval.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "second invoice, same PO", poRef, _nextMilestone());

        assertEq(pay.invoiceCount(), 1);
    }

    function testPaidPurchaseOrderStaysLocked() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 id = _createWithPo(poRef);
        _pay(id);

        // A fully settled purchase order can never be invoiced again.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicatePurchaseOrder.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "again", poRef, _nextMilestone());
    }

    function testPartialInvoicesUpToTotal() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT * 2);

        // Two invoices of half the approved total each, like staged
        // deliveries against one purchase order.
        vm.prank(merchant);
        uint256 a = pay.createInvoice(payer, AMOUNT, dueDate, "first delivery", poRef, _nextMilestone());
        vm.prank(merchant);
        uint256 b = pay.createInvoice(payer, AMOUNT, dueDate, "second delivery", poRef, _nextMilestone());

        _pay(a);
        _pay(b);

        InvoicePay.PurchaseOrder memory po = pay.getPurchaseOrder(payer, poRef);
        assertEq(po.settled, AMOUNT * 2);
        assertEq(po.live, 0);
        assertEq(token.balanceOf(merchant), AMOUNT * 2);

        // The cap is now fully settled, so nothing more can be billed.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicatePurchaseOrder.selector);
        pay.createInvoice(payer, 1, dueDate, "one unit more", poRef, _nextMilestone());
    }

    function testPartialOverrunReverts() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT * 2);

        vm.prank(merchant);
        pay.createInvoice(payer, AMOUNT, dueDate, "first part", poRef, _nextMilestone());

        // AMOUNT + 1 would push the reserved total past the cap.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.AmountExceedsApproval.selector);
        pay.createInvoice(payer, AMOUNT + 1, dueDate, "too much", poRef, _nextMilestone());

        // Exactly the remaining headroom is fine.
        vm.prank(merchant);
        uint256 b = pay.createInvoice(payer, AMOUNT, dueDate, "second part", poRef, _nextMilestone());
        assertEq(pay.purchaseOrderRemaining(payer, poRef), 0);
        _pay(b);
    }

    function testCancelFreesPurchaseOrder() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 first = _createWithPo(poRef);

        vm.prank(merchant);
        pay.cancelInvoice(first);

        // The reservation is free again: a fresh invoice can take it.
        uint256 second = _createWithPoNoApprove(poRef);
        assertEq(second, 1);
        _pay(second);
        assertTrue(pay.getInvoice(second).status == InvoicePay.Status.Paid);
        assertEq(token.balanceOf(merchant), AMOUNT);
    }

    function testCancelReleasesPartialReservation() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT * 2);

        vm.prank(merchant);
        uint256 a = pay.createInvoice(payer, AMOUNT, dueDate, "first part", poRef, _nextMilestone());
        vm.prank(merchant);
        pay.createInvoice(payer, AMOUNT, dueDate, "second part", poRef, _nextMilestone());
        assertEq(pay.purchaseOrderRemaining(payer, poRef), 0);

        // Cancelling one part frees exactly its amount again.
        vm.prank(merchant);
        pay.cancelInvoice(a);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), AMOUNT);

        vm.prank(merchant);
        uint256 c = pay.createInvoice(payer, AMOUNT, dueDate, "replacement part", poRef, _nextMilestone());
        _pay(c);
        assertTrue(pay.getInvoice(c).status == InvoicePay.Status.Paid);
    }

    function testDifferentPurchaseOrdersSameAmount() public {
        bytes32 poA = keccak256("PO 1042");
        bytes32 poB = keccak256("PO 1043");
        uint256 a = _createWithPo(poA);
        uint256 b = _createWithPo(poB);
        assertEq(a, 0);
        assertEq(b, 1);

        // Both purchase orders carry the same amount and both settle.
        _pay(a);
        _pay(b);
        assertTrue(pay.getInvoice(a).status == InvoicePay.Status.Paid);
        assertTrue(pay.getInvoice(b).status == InvoicePay.Status.Paid);
        assertEq(token.balanceOf(merchant), AMOUNT * 2);
    }

    function testSameReferenceDifferentPayers() public {
        bytes32 poRef = keccak256("PO 1042");
        address otherPayer = makeAddr("otherPayer");
        address otherMerchant = makeAddr("otherMerchant");
        token.mint(otherPayer, AMOUNT);

        // The approval is keyed by payer, so the same reference approved
        // by another payer for another merchant is independent.
        uint256 a = _createWithPo(poRef);

        vm.prank(otherPayer);
        pay.approvePurchaseOrder(otherMerchant, poRef, AMOUNT, poExpiry);
        vm.prank(otherMerchant);
        uint256 b = pay.createInvoice(otherPayer, AMOUNT, dueDate, "other pair", poRef, _nextMilestone());

        _pay(a);
        _pay(b);
        assertEq(token.balanceOf(merchant), AMOUNT);
        assertEq(token.balanceOf(otherMerchant), AMOUNT);
        assertEq(pay.getPurchaseOrder(payer, poRef).settled, AMOUNT);
        assertEq(pay.getPurchaseOrder(otherPayer, poRef).settled, AMOUNT);
    }

    function testGetPurchaseOrderView() public {
        bytes32 poRef = keccak256("PO 1042");

        // No approval yet.
        InvoicePay.PurchaseOrder memory before = pay.getPurchaseOrder(payer, poRef);
        assertFalse(before.exists);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), 0);

        _approvePo(poRef, AMOUNT * 2);
        InvoicePay.PurchaseOrder memory approved = pay.getPurchaseOrder(payer, poRef);
        assertTrue(approved.exists);
        assertEq(approved.merchant, merchant);
        assertEq(approved.amount, AMOUNT * 2);
        assertEq(approved.expiry, poExpiry);

        // Another payer sees nothing for the same reference.
        assertFalse(pay.getPurchaseOrder(stranger, poRef).exists);

        // Create, pay, and watch settled and live move.
        vm.prank(merchant);
        uint256 id = pay.createInvoice(payer, AMOUNT, dueDate, "part", poRef, _nextMilestone());
        InvoicePay.PurchaseOrder memory live = pay.getPurchaseOrder(payer, poRef);
        assertEq(live.live, AMOUNT);
        assertEq(live.settled, 0);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), AMOUNT);

        _pay(id);
        InvoicePay.PurchaseOrder memory settled = pay.getPurchaseOrder(payer, poRef);
        assertEq(settled.live, 0);
        assertEq(settled.settled, AMOUNT);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), AMOUNT);
    }

    // ------------------------------------------------------------------
    // Milestone identity
    // ------------------------------------------------------------------

    function testCreateRejectsZeroMilestone() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT);

        vm.prank(merchant);
        vm.expectRevert(InvoicePay.ZeroMilestone.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "no milestone", poRef, bytes32(0));
    }

    function testResubmittedMilestoneRevertsWhileBudgetRemains() public {
        bytes32 poRef = keccak256("PO 1042");
        bytes32 milestone1 = keccak256("PO 1042 milestone 1");
        _approvePo(poRef, AMOUNT * 3);

        vm.prank(merchant);
        uint256 first = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1", poRef, milestone1);

        // The same milestone cannot be billed twice while the first
        // invoice is still open, even though budget remains.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicateMilestone.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1 again", poRef, milestone1);

        // And not after it is paid either: half the budget is still
        // free, but the milestone identity is spent.
        _pay(first);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), AMOUNT * 2);
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicateMilestone.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1 resubmitted", poRef, milestone1);

        assertEq(pay.invoiceCount(), 1);
    }

    function testTwoMilestonesSameAmountBothSettle() public {
        bytes32 poRef = keccak256("PO 1042");
        bytes32 milestone1 = keccak256("PO 1042 milestone 1");
        bytes32 milestone2 = keccak256("PO 1042 milestone 2");
        _approvePo(poRef, AMOUNT * 2);

        // Two legitimate installments with the identical amount: the
        // milestone references are what tell them apart.
        vm.prank(merchant);
        uint256 a = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1", poRef, milestone1);
        vm.prank(merchant);
        uint256 b = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 2", poRef, milestone2);

        _pay(a);
        _pay(b);

        assertTrue(pay.getInvoice(a).status == InvoicePay.Status.Paid);
        assertTrue(pay.getInvoice(b).status == InvoicePay.Status.Paid);
        assertEq(pay.getPurchaseOrder(payer, poRef).settled, AMOUNT * 2);
        assertEq(token.balanceOf(merchant), AMOUNT * 2);
    }

    function testCancelFreesMilestone() public {
        bytes32 poRef = keccak256("PO 1042");
        bytes32 milestone1 = keccak256("PO 1042 milestone 1");
        _approvePo(poRef, AMOUNT * 2);

        vm.prank(merchant);
        uint256 first = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1, wrong memo", poRef, milestone1);

        // Cancelling frees the milestone so a corrected invoice can be
        // issued for the same milestone.
        vm.prank(merchant);
        pay.cancelInvoice(first);

        vm.prank(merchant);
        uint256 corrected = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1, corrected", poRef, milestone1);
        _pay(corrected);
        assertTrue(pay.getInvoice(corrected).status == InvoicePay.Status.Paid);
        assertEq(token.balanceOf(merchant), AMOUNT);
    }

    function testPaidMilestoneStaysLocked() public {
        bytes32 poRef = keccak256("PO 1042");
        bytes32 milestone1 = keccak256("PO 1042 milestone 1");
        _approvePo(poRef, AMOUNT * 3);

        vm.prank(merchant);
        uint256 id = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1", poRef, milestone1);
        _pay(id);

        // Two thirds of the budget remains, but the paid milestone can
        // never be billed again.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicateMilestone.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1 once more", poRef, milestone1);
    }

    function testSameMilestoneDifferentPurchaseOrders() public {
        bytes32 poA = keccak256("PO 1042");
        bytes32 poB = keccak256("PO 1043");
        bytes32 milestone1 = keccak256("milestone 1");
        _approvePo(poA, AMOUNT);
        _approvePo(poB, AMOUNT);

        // The milestone identity is scoped to its purchase order, so
        // the same milestone reference under another purchase order is
        // an independent claim.
        vm.prank(merchant);
        uint256 a = pay.createInvoice(payer, AMOUNT, dueDate, "PO A milestone 1", poA, milestone1);
        vm.prank(merchant);
        uint256 b = pay.createInvoice(payer, AMOUNT, dueDate, "PO B milestone 1", poB, milestone1);

        _pay(a);
        _pay(b);
        assertEq(token.balanceOf(merchant), AMOUNT * 2);
    }

    function _milestoneUsed(bytes32 poRef, bytes32 milestoneRef) internal view returns (bool) {
        (bool used,,) = pay.milestoneStatus(payer, poRef, milestoneRef);
        return used;
    }

    function testMilestoneStatusView() public {
        bytes32 poRef = keccak256("PO 1042");
        bytes32 milestone1 = keccak256("PO 1042 milestone 1");
        _approvePo(poRef, AMOUNT * 2);

        // Free before anything is billed.
        assertFalse(_milestoneUsed(poRef, milestone1));

        vm.prank(merchant);
        uint256 id = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1", poRef, milestone1);

        {
            (bool usedOpen, uint256 openId, InvoicePay.Status openStatus) =
                pay.milestoneStatus(payer, poRef, milestone1);
            assertTrue(usedOpen);
            assertEq(openId, id);
            assertTrue(openStatus == InvoicePay.Status.Open);
        }

        // Still claimed after payment, now reporting Paid.
        _pay(id);
        {
            (bool usedPaid, uint256 paidId, InvoicePay.Status paidStatus) =
                pay.milestoneStatus(payer, poRef, milestone1);
            assertTrue(usedPaid);
            assertEq(paidId, id);
            assertTrue(paidStatus == InvoicePay.Status.Paid);
        }

        // A cancelled milestone reports free again.
        bytes32 milestone2 = keccak256("PO 1042 milestone 2");
        vm.prank(merchant);
        uint256 second = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 2", poRef, milestone2);
        vm.prank(merchant);
        pay.cancelInvoice(second);
        assertFalse(_milestoneUsed(poRef, milestone2));

        // Another payer sees nothing for the same references.
        (bool usedStranger,,) = pay.milestoneStatus(stranger, poRef, milestone1);
        assertFalse(usedStranger);
    }

    function testExpiryEdgeBothSides() public {
        bytes32 poRef = keccak256("PO 1042");
        bytes32 milestone1 = keccak256("PO 1042 milestone 1");
        bytes32 milestone2 = keccak256("PO 1042 milestone 2");
        uint256 shortExpiry = block.timestamp + 1 days;
        vm.prank(payer);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT * 2, shortExpiry);

        // Side one: an invoice created while the approval is open can
        // still be paid after the expiry passes.
        vm.prank(merchant);
        uint256 first = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1", poRef, milestone1);
        vm.warp(shortExpiry + 1);
        _pay(first);
        assertTrue(pay.getInvoice(first).status == InvoicePay.Status.Paid);

        // Side two: no new invoice can be created after expiry, even
        // with budget left and a fresh milestone.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.PurchaseOrderExpired.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "milestone 2, too late", poRef, milestone2);
    }

    function testCancelAfterExpiryFreesMilestoneButCreationStaysGated() public {
        bytes32 poRef = keccak256("PO 1042");
        bytes32 milestone1 = keccak256("PO 1042 milestone 1");
        uint256 shortExpiry = block.timestamp + 1 days;
        vm.prank(payer);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT * 2, shortExpiry);

        vm.prank(merchant);
        uint256 id = pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1", poRef, milestone1);

        // Cancelling after expiry still works and frees the milestone
        // and the reservation...
        vm.warp(shortExpiry + 1);
        vm.prank(merchant);
        pay.cancelInvoice(id);
        (bool used,,) = pay.milestoneStatus(payer, poRef, milestone1);
        assertFalse(used);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), AMOUNT * 2);

        // ...but the freed milestone cannot be rebilled, because the
        // approval itself has expired.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.PurchaseOrderExpired.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "milestone 1, corrected", poRef, milestone1);
    }
}
