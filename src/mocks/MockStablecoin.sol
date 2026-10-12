// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @title MockStablecoin
/// @notice A 6-decimal test stablecoin standing in for USDG on testnet and in tests. Anyone can mint. Never deploy
///         this on mainnet.
contract MockStablecoin is ERC20 {
    constructor() ERC20("Test USDG", "tUSDG") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
