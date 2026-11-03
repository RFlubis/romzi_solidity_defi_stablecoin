// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {AggregatorV3Interface} from "@chainlink/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";

/**
 * @title Oracle Library
 * @author Romzi F Lubis
 * @notice this library used to verify chainlink oracle data (price feed).
 * if it stales, the whole protocol will freeze deposits or withdrawals.
 */
library OracleLib {
    error OracleLib__StalePriceFeed();

    uint256 private constant TIMEOUT = 1 hours;

    function staleCheckLatestRoundData(AggregatorV3Interface priceFeed)
        public
        view
        returns (uint80, int256, uint256, uint256, uint80)
    {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            priceFeed.latestRoundData();

        if (block.timestamp - updatedAt > TIMEOUT) {
            revert OracleLib__StalePriceFeed();
        }
        return (roundId, answer, startedAt, updatedAt, answeredInRound);
    }
}
