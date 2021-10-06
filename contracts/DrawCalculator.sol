// SPDX-License-Identifier: GPL-3.0

pragma solidity 0.8.6;

import "@pooltogether/owner-manager-contracts/contracts/Ownable.sol";

import "./DrawPrize.sol";

import "./interfaces/IDrawCalculator.sol";
import "./interfaces/ITicket.sol";
import "./interfaces/IDrawHistory.sol";
import "./interfaces/IPrizeDistributionHistory.sol";
import "./libraries/DrawLib.sol";
import "./libraries/DrawRingBufferLib.sol";

import "hardhat/console.sol";

/**
  * @title  PoolTogether V4 DrawCalculator
  * @author PoolTogether Inc Team
  * @notice The DrawCalculator calculates a user's prize by matching a winning random number against
            their picks. A users picks are generated deterministically based on their address and balance
            of tickets held. Prize payouts are divided into multiple tiers: grand prize, second place, etc...
            A user with a higher average weighted balance (during each draw period) will be given a large number of
            picks to choose from, and thus a higher chance to match the winning numbers.
*/
contract DrawCalculator is IDrawCalculator, Ownable {
 
    /// @notice DrawHistory address
    IDrawHistory public immutable drawHistory;

    /// @notice Ticket associated with DrawCalculator
    ITicket public immutable ticket;

    /// @notice The stored history of draw settings.  Stored as ring buffer.
    IPrizeDistributionHistory public immutable prizeDistributionHistory;

    /// @notice The tiers array length
    uint8 public constant TIERS_LENGTH = 16;

    /* ============ Constructor ============ */

    /// @notice Constructor for DrawCalculator
    /// @param _owner Address of the DrawCalculator owner
    /// @param _ticket Ticket associated with this DrawCalculator
    /// @param _drawHistory The address of the draw history to push draws to
    /// @param _prizeDistributionHistory PrizeDistributionHistory address
    constructor(
        address _owner,
        ITicket _ticket,
        IDrawHistory _drawHistory,
        IPrizeDistributionHistory _prizeDistributionHistory
    ) Ownable(_owner) {
        require(address(_ticket) != address(0), "DrawCalc/ticket-not-zero");
        require(address(_prizeDistributionHistory) != address(0), "DrawCalc/pdh-not-zero");
        require(address(_drawHistory) != address(0), "DrawCalc/dh-not-zero");

        ticket = _ticket;
        drawHistory = _drawHistory;
        prizeDistributionHistory = _prizeDistributionHistory;

        emit Deployed(_ticket, _drawHistory, _prizeDistributionHistory);
    }

    /* ============ External Functions ============ */

    /// @inheritdoc IDrawCalculator
    function calculate(
        address _user,
        uint32[] calldata _drawIds,
        bytes calldata _pickIndicesForDraws
    ) external view override returns (uint256[] memory) {
        uint64[][] memory pickIndices = abi.decode(_pickIndicesForDraws, (uint64 [][]));
        require(pickIndices.length == _drawIds.length, "DrawCalc/invalid-pick-indices-length");

        // READ list of DrawLib.Draw using the drawIds from drawHistory
        DrawLib.Draw[] memory draws = drawHistory.getDraws(_drawIds);

        // READ list of DrawLib.PrizeDistribution using the drawIds
        DrawLib.PrizeDistribution[] memory _prizeDistributions = prizeDistributionHistory
            .getPrizeDistributions(_drawIds);

        // The userBalances are fractions representing their portion of the liquidity for a draw.
        uint256[] memory userBalances = _getNormalizedBalancesAt(_user, draws, _prizeDistributions);

        // The users address is hashed once. 
        bytes32 _userRandomNumber = keccak256(abi.encodePacked(_user));

        return
            _calculatePrizesAwardable(
                userBalances,
                _userRandomNumber,
                draws,
                pickIndices,
                _prizeDistributions
            );
    }

    /// @inheritdoc IDrawCalculator
    function getDrawHistory() external view override returns (IDrawHistory) {
        return drawHistory;
    }

    /// @inheritdoc IDrawCalculator
    function getPrizeDistributionHistory()
        external
        view
        override
        returns (IPrizeDistributionHistory)
    {
        return prizeDistributionHistory;
    }

    /// @inheritdoc IDrawCalculator
    function getNormalizedBalancesForDrawIds(address _user, uint32[] calldata _drawIds)
        external
        view
        override
        returns (uint256[] memory)
    {
        DrawLib.Draw[] memory _draws = drawHistory.getDraws(_drawIds);
        DrawLib.PrizeDistribution[] memory _prizeDistributions = prizeDistributionHistory
            .getPrizeDistributions(_drawIds);

        return _getNormalizedBalancesAt(_user, _draws, _prizeDistributions);
    }

    /// @inheritdoc IDrawCalculator
    function checkPrizeTierIndexForDrawId(
        address _user,
        uint64[] calldata _pickIndices,
        uint32 _drawId
    ) external view override returns (PickPrize[] memory) {
        uint32[] memory drawIds = new uint32[](1);
        drawIds[0] = _drawId;

        DrawLib.Draw[] memory _draws = drawHistory.getDraws(drawIds);
        DrawLib.PrizeDistribution[] memory _prizeDistributions = prizeDistributionHistory
            .getPrizeDistributions(drawIds);

        uint256[] memory userBalances = _getNormalizedBalancesAt(
            _user,
            _draws,
            _prizeDistributions
        );

        uint64 totalUserPicks = _calculateNumberOfUserPicks(
            _prizeDistributions[0],
            userBalances[0]
        );

        uint256[] memory masks = _createBitMasks(_prizeDistributions[0]);
        PickPrize[] memory pickPrizes = new PickPrize[](_pickIndices.length);
        uint8 _matchCardinality = _prizeDistributions[0].matchCardinality;

        bytes32 _userRandomNumber = keccak256(abi.encodePacked(_user)); // hash the users address

        for (uint64 i = 0; i < _pickIndices.length; i++) {
            uint256 randomNumberThisPick = uint256(
                keccak256(abi.encode(_userRandomNumber, _pickIndices[i]))
            );

            require(_pickIndices[i] < totalUserPicks, "DrawCalc/insufficient-user-picks");

            uint256 tierIndex = _calculateTierIndex(
                randomNumberThisPick,
                _draws[0].winningRandomNumber,
                masks,
                _matchCardinality
            );

            pickPrizes[i] = PickPrize({
                won: tierIndex < _prizeDistributions[0].tiers.length && _prizeDistributions[0].tiers[tierIndex] > 0,
                tierIndex: uint8(tierIndex)
            });
        }

        return pickPrizes;
    }

    /* ============ Internal Functions ============ */

    /**
     * @notice Calculates the prizes awardable for each Draw passed.
     * @param _normalizedUserBalances Fractions representing the user's portion of the liquidity for each draw.
     * @param _userRandomNumber       Random number of the user to consider over draws
     * @param _draws                  List of Draws
     * @param _pickIndicesForDraws    Pick indices for each Draw
     * @param _prizeDistributions     PrizeDistribution for each Draw
     * @return List of prizes for each Draw
     */
    function _calculatePrizesAwardable(
        uint256[] memory _normalizedUserBalances,
        bytes32 _userRandomNumber,
        DrawLib.Draw[] memory _draws,
        uint64[][] memory _pickIndicesForDraws,
        DrawLib.PrizeDistribution[] memory _prizeDistributions
    ) internal view returns (uint256[] memory) {
        uint256[] memory prizesAwardable = new uint256[](_normalizedUserBalances.length);

        // calculate prizes awardable for each Draw passed
        for (uint32 drawIndex = 0; drawIndex < _draws.length; drawIndex++) {
            uint64 totalUserPicks = _calculateNumberOfUserPicks(
                _prizeDistributions[drawIndex],
                _normalizedUserBalances[drawIndex]
            );

            prizesAwardable[drawIndex] = _calculate(
                _draws[drawIndex].winningRandomNumber,
                totalUserPicks,
                _userRandomNumber,
                _pickIndicesForDraws[drawIndex],
                _prizeDistributions[drawIndex]
            );
        }

        return prizesAwardable;
    }

    /**
     * @notice Calculates the number of picks a user gets for a Draw, considering the normalized user balance and the PrizeDistribution.
     * @dev Divided by 1e18 since the normalized user balance is stored as a fixed point 18 number
     * @param _prizeDistribution The PrizeDistribution to consider
     * @param _normalizedUserBalance The normalized user balances to consider
     * @return The number of picks a user gets for a Draw
     */
    function _calculateNumberOfUserPicks(
        DrawLib.PrizeDistribution memory _prizeDistribution,
        uint256 _normalizedUserBalance
    ) internal view returns (uint64) {
        return uint64((_normalizedUserBalance * _prizeDistribution.numberOfPicks) / 1 ether);
    }

    /**
     * @notice Calculates the normalized balance of a user against the total supply for timestamps
     * @param _user The user to consider
     * @param _draws The draws we are looking at
     * @param _prizeDistributions The prize tiers to consider (needed for draw timestamp offsets)
     * @return An array of normalized balances
     */
    function _getNormalizedBalancesAt(
        address _user,
        DrawLib.Draw[] memory _draws,
        DrawLib.PrizeDistribution[] memory _prizeDistributions
    ) internal view returns (uint256[] memory) {
        uint32[] memory _timestampsWithStartCutoffTimes = new uint32[](_draws.length);
        uint32[] memory _timestampsWithEndCutoffTimes = new uint32[](_draws.length);

        // generate timestamps with draw cutoff offsets included
        for (uint32 i = 0; i < _draws.length; i++) {
            unchecked {
                _timestampsWithStartCutoffTimes[i] = uint32(
                    _draws[i].timestamp - _prizeDistributions[i].startTimestampOffset
                );
                _timestampsWithEndCutoffTimes[i] = uint32(
                    _draws[i].timestamp - _prizeDistributions[i].endTimestampOffset
                );
            }
        }

        uint256[] memory balances = ticket.getAverageBalancesBetween(
            _user,
            _timestampsWithStartCutoffTimes,
            _timestampsWithEndCutoffTimes
        );

        uint256[] memory totalSupplies = ticket.getAverageTotalSuppliesBetween(
            _timestampsWithStartCutoffTimes,
            _timestampsWithEndCutoffTimes
        );

        uint256[] memory normalizedBalances = new uint256[](_draws.length);

        // divide balances by total supplies (normalize)
        for (uint256 i = 0; i < _draws.length; i++) {
            require(totalSupplies[i] > 0, "DrawCalc/total-supply-zero");
            normalizedBalances[i] = (balances[i] * 1 ether) / totalSupplies[i];
        }

        return normalizedBalances;
    }

    /**
     * @notice Calculates the prize amount for a PrizeDistribution over given picks
     * @param _winningRandomNumber Draw's winningRandomNumber
     * @param _totalUserPicks      number of picks the user gets for the Draw
     * @param _userRandomNumber    users randomNumber for that draw
     * @param _picks               users picks for that draw
     * @param _prizeDistribution   PrizeDistribution for that draw
     * @return prize (if any)
     */
    function _calculate(
        uint256 _winningRandomNumber,
        uint256 _totalUserPicks,
        bytes32 _userRandomNumber,
        uint64[] memory _picks,
        DrawLib.PrizeDistribution memory _prizeDistribution
    ) internal view returns (uint256) {
        // prizeCounts stores the number of wins at a distribution index
        uint256[] memory prizeCounts = new uint256[](_prizeDistribution.tiers.length);
        
        // create bitmasks for the PrizeDistribution
        uint256[] memory masks = _createBitMasks(_prizeDistribution);
        uint32 picksLength = uint32(_picks.length);

        uint8 maxWinningTierIndex = 0;
        uint8 _matchCardinality = _prizeDistribution.matchCardinality;

        require(
            picksLength <= _prizeDistribution.maxPicksPerUser,
            "DrawCalc/exceeds-max-user-picks"
        );

        // for each pick, find number of matching numbers and calculate prize distributions index
        for (uint32 index = 0; index < picksLength; index++) {
            require(_picks[index] < _totalUserPicks, "DrawCalc/insufficient-user-picks");

            if (index > 0) {
                require(_picks[index] > _picks[index - 1], "DrawCalc/picks-ascending");
            }

            // hash the user random number with the pick value
            uint256 randomNumberThisPick = uint256(
                keccak256(abi.encode(_userRandomNumber, _picks[index]))
            );

            // attempt to match the numbers
            uint8 tiersIndex = _calculateTierIndex(
                randomNumberThisPick,
                _winningRandomNumber,
                masks,
                _matchCardinality
            );

            // there is prize for this tier index
            if (tiersIndex < TIERS_LENGTH) {
                if (tiersIndex > maxWinningTierIndex) {
                    maxWinningTierIndex = tiersIndex;
                }
                prizeCounts[tiersIndex]++;
            }
        }

        // now calculate prizeFraction given prizeCounts
        uint256 prizeFraction = 0;
        uint256[] memory prizeTiersFractions = _calculatePrizeTierFractions(
            _prizeDistribution,
            maxWinningTierIndex
        );

        // multiple the fractions by the prizeCounts and add them up
        for (
            uint256 prizeCountIndex = 0;
            prizeCountIndex <= maxWinningTierIndex;
            prizeCountIndex++
        ) {
            if (prizeCounts[prizeCountIndex] > 0) {
                prizeFraction +=
                    prizeTiersFractions[prizeCountIndex] *
                    prizeCounts[prizeCountIndex];
            }
        }

        // return the absolute amount of prize awardable
        return (prizeFraction * _prizeDistribution.prize) / 1e9; // div by 1e9 as prize tiers are base 1e9
    }

    ///@notice Calculates the tier index given the random numbers and masks
    ///@param _randomNumberThisPick users random number for this Pick
    ///@param _winningRandomNumber The winning number for this draw
    ///@param _masks The pre-calculate bitmasks for the prizeDistributions
    ///@param _matchCardinality The cardinality of the draw
    ///@return The position within the prize tier array (0 = top prize, 1 = runner-up prize, etc)
    function _calculateTierIndex(
        uint256 _randomNumberThisPick,
        uint256 _winningRandomNumber,
        uint256[] memory _masks,
        uint8 _matchCardinality
    ) internal view returns (uint8) {
        uint8 numberOfMatches = 0;
        uint8 masksLength = uint8(_masks.length);
        
        console.log("matchCardinality is" , _matchCardinality);

        // main number matching loop
        for (uint8 matchIndex = 0; matchIndex < _matchCardinality; matchIndex++) {
            uint256 mask = _masks[matchIndex];

            if ((_randomNumberThisPick & mask) != (_winningRandomNumber & mask)) {
                // there are no more sequential matches since this comparison is not a match
                console.log("calcTier:: early returning ",(_matchCardinality - numberOfMatches));
                return _matchCardinality - numberOfMatches;
            }

            // else there was a match
            console.log("incrementing matches");
            numberOfMatches++;
        }
        // this should always return 0
        console.log("calcTier:: end returning ",(_matchCardinality - numberOfMatches));
        return _matchCardinality - numberOfMatches;
    }

    /**
     * @notice Create an array of bitmasks equal to the greateer of non-zero tiers or matchCardinality
     * @param _prizeDistribution The PrizeDistribution to use to calculate the masks
     * @return An array of bitmasks
     */
    function _createBitMasks(DrawLib.PrizeDistribution memory _prizeDistribution)
        internal
        view
        returns (uint256[] memory)
    {
        
        // calculate the non-zero length of the prize tiers
        uint8 nonZeroPrizeTiersLength = 0;
        for(uint i = 0; i < _prizeDistribution.tiers.length; i++) {
            if(_prizeDistribution.tiers[i] > 0) {
                nonZeroPrizeTiersLength++;
            }
        }
        uint8 _matchCardinality = _prizeDistribution.matchCardinality;
        uint8 createMasksLength = nonZeroPrizeTiersLength > _matchCardinality ? nonZeroPrizeTiersLength : _matchCardinality;

        uint256[] memory masks = new uint256[](createMasksLength);
        uint256 _bitRangeMaskValue = (2**_prizeDistribution.bitRangeSize) - 1; // get a decimal representation of bitRangeSize

        // now create the masks
        for (uint8 maskIndex = 0; maskIndex < createMasksLength; maskIndex++) {
            // create mask of width bitRangeSize bits at index
            uint256 _matchIndexOffset = uint256(maskIndex) * uint256(_prizeDistribution.bitRangeSize);
            // shift mask bits to correct position and insert in result mask array
            masks[maskIndex] = _bitRangeMaskValue << _matchIndexOffset;
        }
        console.log("returning bitmasks of length", masks.length);
        return masks;
    }

    /**
     * @notice Calculates the expected prize fraction per PrizeDistributions and distributionIndex
     * @param _prizeDistribution prizeDistribution struct for Draw
     * @param _prizeTierIndex Index of the prize tiers array to calculate
     * @return returns the fraction of the total prize (base 1e18)
     */
    function _calculatePrizeTierFraction(
        DrawLib.PrizeDistribution memory _prizeDistribution,
        uint256 _prizeTierIndex
    ) internal view returns (uint256) {
         // get the prize fraction at that index
        uint256 prizeFraction = _prizeDistribution.tiers[_prizeTierIndex];
        
        // calculate number of prizes for that index
        uint256 numberOfPrizesForIndex = _numberOfPrizesForIndex(
            _prizeDistribution.bitRangeSize,
            _prizeTierIndex
        );

        return prizeFraction / numberOfPrizesForIndex;
    }

    /**
     * @notice Generates an array of prize tiers fractions
     * @param _prizeDistribution prizeDistribution struct for Draw
     * @param maxWinningTierIndex Max length of the prize tiers array
     * @return returns an array of prize tiers fractions
     */
    function _calculatePrizeTierFractions(
        DrawLib.PrizeDistribution memory _prizeDistribution,
        uint8 maxWinningTierIndex
    ) internal view returns (uint256[] memory) {
        uint256[] memory prizeDistributionFractions = new uint256[](
            maxWinningTierIndex + 1
        );

        for (uint8 i = 0; i <= maxWinningTierIndex; i++) {
            prizeDistributionFractions[i] = _calculatePrizeTierFraction(
                _prizeDistribution,
                i
            );
        }

        return prizeDistributionFractions;
    }

    /**
     * @notice Calculates the number of prizes for a given prizeDistributionIndex
     * @param _bitRangeSize Bit range size for Draw
     * @param _prizeTierIndex Index of the prize tier array to calculate
     * @return returns the fraction of the total prize (base 1e18)
     */
    function _numberOfPrizesForIndex(uint8 _bitRangeSize, uint256 _prizeTierIndex)
        internal
        view
        returns (uint256)
    {
        uint256 bitRangeDecimal = 2**uint256(_bitRangeSize);
        uint256 numberOfPrizesForIndex = bitRangeDecimal**_prizeTierIndex;

        while (_prizeTierIndex > 0) {
            numberOfPrizesForIndex -= bitRangeDecimal**(_prizeTierIndex - 1);
            _prizeTierIndex--;
        }

        return numberOfPrizesForIndex;
    }
}
