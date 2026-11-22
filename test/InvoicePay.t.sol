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

    /// @dev The payer approves a purchase order for the merchant.
    function _approvePo(bytes32 poRef, uint256 amount) internal {
        vm.prank(payer);
        pay.approvePurchaseOrder(merchant, poRef, amount, poExpiry);
    }

    function _create() internal returns (uint256 id) {
        bytes32 poRef = _nextPo();
        _approvePo(poRef, AMOUNT);
        vm.prank(merchant);
        id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice 1042, design work", poRef);
    }

    function _createWithPo(bytes32 poRef) internal returns (uint256 id) {
        _approvePo(poRef, AMOUNT);
        vm.prank(merchant);
        id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice for purchase order", poRef);
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
        uint256 id = _createWithPo(poRef);
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
        pay.createInvoice(address(0), AMOUNT, dueDate, "x", _nextPo());
    }

    function testCreateRejectsZeroAmount() public {
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.ZeroAmount.selector);
        pay.createInvoice(payer, 0, dueDate, "x", _nextPo());
    }

    function testCreateRejectsPastDueDate() public {
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DueDateInPast.selector);
        pay.createInvoice(payer, AMOUNT, block.timestamp, "x", _nextPo());
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
        pay.createInvoice(payer, AMOUNT, dueDate, "x", bytes32(0));
    }

    function testCreateRejectsWithoutApproval() public {
        bytes32 poRef = keccak256("PO 9999");

        // The payer never approved this reference.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.PurchaseOrderNotApproved.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "no approval", poRef);

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
        pay.createInvoice(payer, AMOUNT, dueDate, "wrong merchant", poRef);

        // The named merchant can still bill against it.
        uint256 id = _createWithPoNoApprove(poRef);
        assertEq(pay.getInvoice(id).merchant, merchant);
    }

    function _createWithPoNoApprove(bytes32 poRef) internal returns (uint256 id) {
        vm.prank(merchant);
        id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice for purchase order", poRef);
    }

    function testCreateRejectsAmountAboveApproval() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT);

        vm.prank(merchant);
        vm.expectRevert(InvoicePay.AmountExceedsApproval.selector);
        pay.createInvoice(payer, AMOUNT + 1, dueDate, "over the cap", poRef);
    }

    function testCreateRejectsExpiredApproval() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 shortExpiry = block.timestamp + 1 days;
        vm.prank(payer);
        pay.approvePurchaseOrder(merchant, poRef, AMOUNT, shortExpiry);

        vm.warp(shortExpiry + 1);
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.PurchaseOrderExpired.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "too late", poRef);
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
        uint256 id = pay.createInvoice(payer, AMOUNT * 2, dueDate, "corrected amount", poRef);
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
        pay.createInvoice(payer, AMOUNT, dueDate, "second invoice, same PO", poRef);

        assertEq(pay.invoiceCount(), 1);
    }

    function testPaidPurchaseOrderStaysLocked() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 id = _createWithPo(poRef);
        _pay(id);

        // A fully settled purchase order can never be invoiced again.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicatePurchaseOrder.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "again", poRef);
    }

    function testPartialInvoicesUpToTotal() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT * 2);

        // Two invoices of half the approved total each, like staged
        // deliveries against one purchase order.
        vm.prank(merchant);
        uint256 a = pay.createInvoice(payer, AMOUNT, dueDate, "first delivery", poRef);
        vm.prank(merchant);
        uint256 b = pay.createInvoice(payer, AMOUNT, dueDate, "second delivery", poRef);

        _pay(a);
        _pay(b);

        InvoicePay.PurchaseOrder memory po = pay.getPurchaseOrder(payer, poRef);
        assertEq(po.settled, AMOUNT * 2);
        assertEq(po.live, 0);
        assertEq(token.balanceOf(merchant), AMOUNT * 2);

        // The cap is now fully settled, so nothing more can be billed.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicatePurchaseOrder.selector);
        pay.createInvoice(payer, 1, dueDate, "one unit more", poRef);
    }

    function testPartialOverrunReverts() public {
        bytes32 poRef = keccak256("PO 1042");
        _approvePo(poRef, AMOUNT * 2);

        vm.prank(merchant);
        pay.createInvoice(payer, AMOUNT, dueDate, "first part", poRef);

        // AMOUNT + 1 would push the reserved total past the cap.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.AmountExceedsApproval.selector);
        pay.createInvoice(payer, AMOUNT + 1, dueDate, "too much", poRef);

        // Exactly the remaining headroom is fine.
        vm.prank(merchant);
        uint256 b = pay.createInvoice(payer, AMOUNT, dueDate, "second part", poRef);
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
        uint256 a = pay.createInvoice(payer, AMOUNT, dueDate, "first part", poRef);
        vm.prank(merchant);
        pay.createInvoice(payer, AMOUNT, dueDate, "second part", poRef);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), 0);

        // Cancelling one part frees exactly its amount again.
        vm.prank(merchant);
        pay.cancelInvoice(a);
        assertEq(pay.purchaseOrderRemaining(payer, poRef), AMOUNT);

        vm.prank(merchant);
        uint256 c = pay.createInvoice(payer, AMOUNT, dueDate, "replacement part", poRef);
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
        uint256 b = pay.createInvoice(otherPayer, AMOUNT, dueDate, "other pair", poRef);

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
        uint256 id = pay.createInvoice(payer, AMOUNT, dueDate, "part", poRef);
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
}
