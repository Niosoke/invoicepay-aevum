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
    uint256 internal poCounter;

    function setUp() public {
        token = new MockUSD8();
        pay = new InvoicePay(address(token));
        dueDate = block.timestamp + 7 days;
        token.mint(payer, 1_000_000000); // 1,000 tUSD8
    }

    /// @dev Unique purchase order reference per call, so the existing
    ///      cycle tests keep working under the duplicate guard.
    function _nextPo() internal returns (bytes32) {
        poCounter++;
        return keccak256(abi.encodePacked("PO ", poCounter));
    }

    function _create() internal returns (uint256 id) {
        vm.prank(merchant);
        id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice 1042, design work", _nextPo());
    }

    function _createWithPo(bytes32 poRef) internal returns (uint256 id) {
        vm.prank(merchant);
        id = pay.createInvoice(payer, AMOUNT, dueDate, "Invoice for purchase order", poRef);
    }

    function _pay(uint256 id) internal {
        vm.startPrank(payer);
        token.approve(address(pay), AMOUNT);
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
    // Purchase order binding
    // ------------------------------------------------------------------

    function testCreateRejectsZeroPurchaseOrder() public {
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.ZeroPurchaseOrder.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "x", bytes32(0));
    }

    function testDuplicatePurchaseOrderReverts() public {
        bytes32 poRef = keccak256("PO 1042");
        _createWithPo(poRef);

        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicatePurchaseOrder.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "second invoice, same PO", poRef);

        assertEq(pay.invoiceCount(), 1);
    }

    function testDifferentPurchaseOrdersSameAmount() public {
        bytes32 poA = keccak256("PO 1042");
        bytes32 poB = keccak256("PO 1043");
        uint256 a = _createWithPo(poA);
        uint256 b = _createWithPo(poB);
        assertEq(a, 0);
        assertEq(b, 1);

        // Both invoices carry the same amount and both can be settled.
        _pay(a);
        _pay(b);
        assertTrue(pay.getInvoice(a).status == InvoicePay.Status.Paid);
        assertTrue(pay.getInvoice(b).status == InvoicePay.Status.Paid);
        assertEq(token.balanceOf(merchant), AMOUNT * 2);
    }

    function testCancelFreesPurchaseOrder() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 first = _createWithPo(poRef);

        vm.prank(merchant);
        pay.cancelInvoice(first);

        // The reference is free again: a fresh invoice can take it.
        uint256 second = _createWithPo(poRef);
        assertEq(second, 1);
        _pay(second);
        assertTrue(pay.getInvoice(second).status == InvoicePay.Status.Paid);
        assertEq(token.balanceOf(merchant), AMOUNT);
    }

    function testPaidPurchaseOrderStaysLocked() public {
        bytes32 poRef = keccak256("PO 1042");
        uint256 id = _createWithPo(poRef);
        _pay(id);

        // A settled purchase order can never be invoiced again.
        vm.prank(merchant);
        vm.expectRevert(InvoicePay.DuplicatePurchaseOrder.selector);
        pay.createInvoice(payer, AMOUNT, dueDate, "again", poRef);
    }

    function testSamePurchaseOrderDifferentMerchant() public {
        bytes32 poRef = keccak256("PO 1042");
        address otherMerchant = makeAddr("otherMerchant");
        _createWithPo(poRef);

        // The binding is per merchant, so another merchant can use the
        // same reference for their own invoice.
        vm.prank(otherMerchant);
        uint256 id = pay.createInvoice(payer, AMOUNT, dueDate, "other merchant", poRef);
        assertEq(id, 1);
        assertEq(pay.getInvoice(id).merchant, otherMerchant);
    }

    function testPurchaseOrderStatusView() public {
        bytes32 poRef = keccak256("PO 1042");

        (bool activeBefore, uint256 idBefore) = pay.purchaseOrderStatus(merchant, poRef);
        assertFalse(activeBefore);
        assertEq(idBefore, 0);

        uint256 id = _createWithPo(poRef);
        (bool active, uint256 boundId) = pay.purchaseOrderStatus(merchant, poRef);
        assertTrue(active);
        assertEq(boundId, id);

        // A different merchant sees nothing for the same reference.
        (bool activeOther,) = pay.purchaseOrderStatus(stranger, poRef);
        assertFalse(activeOther);

        // After cancel the reference reads free again.
        vm.prank(merchant);
        pay.cancelInvoice(id);
        (bool activeAfter,) = pay.purchaseOrderStatus(merchant, poRef);
        assertFalse(activeAfter);
    }
}
