// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title INK, the launch token
/// @notice A plain fixed-supply ERC-20: 1,000,000,000 INK at 18 decimals, minted once to the deployer, which
/// is IMD's launch factory. The factory then splits it (10% to the swarm's distributor, 10% into the INK/IMD
/// pool, 80% to the InkVault). Nothing can mint, burn, pause, block, tax or upgrade afterwards: the hook fee
/// lives in InkHook, and the vault's accounting only ever moves what holders send it.
contract LaunchToken is ERC20 {
    uint256 public constant SUPPLY = 1_000_000_000e18;

    constructor() ERC20("INK", "INK") {
        _mint(msg.sender, SUPPLY);
    }
}
