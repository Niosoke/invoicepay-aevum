// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";
import {InvoicePay} from "../src/InvoicePay.sol";

/// @notice Deploys InvoicePay wired to the official tUSD8 token on
///         QDay Aevum testnet (chain 44005).
///
/// Usage:
///   forge script script/Deploy.s.sol \
///     --rpc-url https://rpc-test.qday.info \
///     --keystore keystore/merchant \
///     --broadcast
contract Deploy is Script {
    /// @notice tUSD8 on QDay Aevum testnet (6 decimals).
    address internal constant TUSD8 = 0x456569838f1d43009A91ebA4263147Afd7233483;

    function run() external returns (InvoicePay pay) {
        vm.startBroadcast();
        pay = new InvoicePay(TUSD8);
        vm.stopBroadcast();
    }
}
