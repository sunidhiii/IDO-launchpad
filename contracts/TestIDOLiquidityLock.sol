// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "./TokenTimelock.sol";
// import "./MemePad.sol";

contract TestIDOLiquidityLock is TokenTimelock {
    constructor(
        IERC20 _token,
        address presaleCreator,
        uint256 _releaseTime
    ) public TokenTimelock(_token, presaleCreator, _releaseTime) {}
}
