// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title Clock
/// @notice The timepoint used for balance snapshots (record blocks and vote snapshots).
/// @dev On Arbitrum chains, including Robinhood Chain, `block.number` returns an approximation of the L1 block number,
///      which advances far more slowly than L2 blocks. Snapshots therefore use the L2 block number from the ArbSys
///      precompile. Nitro installs a one-byte stub at every precompile address, so a code-size check tells us whether
///      we are on Arbitrum. Elsewhere (local Anvil, Foundry tests) the clock falls back to `block.number`.
///
///      The call is a gas-capped staticcall with a fallback because local EVMs that fork an Arbitrum chain (Foundry
///      simulations, which run before every `forge script` broadcast) see the stub but do not implement the
///      precompile, so the call fails there.
library Clock {
    address internal constant ARB_SYS = address(100);
    uint256 private constant CALL_GAS = 20_000;

    function now48() internal view returns (uint48) {
        if (ARB_SYS.code.length > 0) {
            (bool ok, bytes memory ret) = ARB_SYS.staticcall{gas: CALL_GAS}(abi.encodeCall(IArbSys.arbBlockNumber, ()));
            if (ok && ret.length == 32) return uint48(abi.decode(ret, (uint256)));
        }
        return uint48(block.number);
    }
}
