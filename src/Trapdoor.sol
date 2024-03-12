// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {PriceConverter} from "./PriceConverter.sol";
import {AggregatorV3Interface} from "@chainlink/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol";
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract Trapdoor is VRFConsumerBaseV2, Ownable {
    using PriceConverter for uint256;

    ///////////////////
    // Type declarations
    ///////////////////

    enum TrapdoorState {
        Open,
        Closed
    }

    enum TrapdoorChoice {
        Left,
        Right
    }

    struct TrapdoorConfig {
        address vrfCoordinator;
        address priceFeed;
        bytes32 gasLane;
        uint64 subscriptionId;
        uint32 callbackGasLimit;
    }

    struct ChainlinkVRFConfig {
        uint16 requestConfirmations;
        uint32 numWords;
        VRFCoordinatorV2Interface vrfCoordinator;
        bytes32 gasLane;
        uint64 subscriptionId;
        uint32 callbackGasLimit;
    }

    ///////////////////
    // State variables
    ///////////////////

    ChainlinkVRFConfig private vrfConfig;
    AggregatorV3Interface private s_priceFeed;

    uint256 private constant MAX_PLAYERS_PER_TRAPDOOR = 100;
    uint256 private constant TICKET_FEE_PERCENTAGE = 30; // 3%
    uint256 private constant ENTRY_FEE_IN_USD = 10 * 10 ** 18; // 10 USD
    uint256 private s_gameInterval = 1 hours;
    uint256 private s_totalPrizePool;
    uint256 private s_totalFees;
    uint256 private s_lastOpenedAt;
    uint256 private s_lastPrizeValue;
    TrapdoorChoice private s_lastTrapdoorSide;

    TrapdoorState private s_GameState;
    address[] private s_leftPlayers;
    address[] private s_rightPlayers;
    address[] private s_lastWinners;

    ///////////////////
    // Events
    ///////////////////

    event TrapdoorStateChanged(TrapdoorState indexed newState);
    event PlayerChose(address indexed player, TrapdoorChoice indexed choice);
    event RandomTrapdoorRequested(uint256 indexed requestId);
    event WinnerChosen(address[] indexed winners);
    event TrapdoorOpened(uint256 indexed trapdoorChoice);

    ///////////////////
    // Errors
    ///////////////////

    error Trapdoor__InvalidEntryFee();
    error Trapdoor__GameIsClosed();
    error Trapdoor__InvalidChoice();
    error Trapdoor__MaxPlayersReached();
    error Trapdoor__TransferFailed();
    error Trapdoor__NotEnoughTimePassed();
    error Trapdoor__TrapdoorsAreEmpty();

    ///////////////////
    // Functions
    ///////////////////

    constructor(
        TrapdoorConfig memory config
    ) VRFConsumerBaseV2(config.vrfCoordinator) Ownable(msg.sender) {
        vrfConfig = ChainlinkVRFConfig({
            requestConfirmations: 3,
            numWords: 1,
            vrfCoordinator: VRFCoordinatorV2Interface(config.vrfCoordinator),
            gasLane: config.gasLane,
            subscriptionId: config.subscriptionId,
            callbackGasLimit: config.callbackGasLimit
        });
        s_priceFeed = AggregatorV3Interface(config.priceFeed);
    }

    ////////////////////
    // External / Public
    ////////////////////

    function chooseTrapdoor(TrapdoorChoice _choice) external payable {
        if (getPriceInUsd(msg.value) < ENTRY_FEE_IN_USD) {
            revert Trapdoor__InvalidEntryFee();
        }
        if (s_GameState != TrapdoorState.Open) {
            revert Trapdoor__GameIsClosed();
        }
        if (_choice != TrapdoorChoice.Left && _choice != TrapdoorChoice.Right) {
            revert Trapdoor__InvalidChoice();
        }

        _ensureTrapdoorIsNotFull(_choice);
        _handlePrizeAndFees(msg.value);
        _registerChoice(msg.sender, _choice);
    }

    /**
     * @notice Called by Chainlink Automation
     */
    function revealTrapdoor() external {
        if (s_GameState == TrapdoorState.Closed) {
            revert Trapdoor__GameIsClosed();
        }
        if (!_hasEnoughTimePassed()) {
            revert Trapdoor__NotEnoughTimePassed();
        }
        _ensureTrapdoorIsNotEmpty();
        _setTrapdoorState(TrapdoorState.Closed);
        _requestRandomTrapdoor();
    }

    function withdrawFees() external onlyOwner {
        (bool success, ) = owner().call{value: s_totalFees}("");
        if (!success) {
            revert Trapdoor__TransferFailed();
        }
        s_totalFees = 0;
    }

    ////////////////////
    // Internal
    ////////////////////

    function _registerChoice(address _player, TrapdoorChoice choice) internal {
        if (choice == TrapdoorChoice.Left) {
            s_leftPlayers.push(_player);
        } else {
            s_rightPlayers.push(_player);
        }
        emit PlayerChose(_player, choice);
    }

    function _handlePrizeAndFees(uint256 _paidAmount) internal {
        uint256 fees = _computeFees(_paidAmount);
        s_totalPrizePool += _paidAmount - fees;
        s_totalFees += fees;
    }

    function _computeFees(uint256 _paidAmount) internal pure returns (uint256) {
        return (_paidAmount * TICKET_FEE_PERCENTAGE) / 1000;
    }

    function _ensureTrapdoorIsNotFull(TrapdoorChoice _choice) internal view {
        if (
            (_choice == TrapdoorChoice.Left &&
                s_leftPlayers.length >= MAX_PLAYERS_PER_TRAPDOOR) ||
            (_choice == TrapdoorChoice.Right &&
                s_rightPlayers.length >= MAX_PLAYERS_PER_TRAPDOOR)
        ) {
            revert Trapdoor__MaxPlayersReached();
        }
    }

    function _ensureTrapdoorIsNotEmpty() internal view {
        if (s_leftPlayers.length == 0 && s_rightPlayers.length == 0) {
            revert Trapdoor__TrapdoorsAreEmpty();
        }
    }

    function _hasEnoughTimePassed() internal view returns (bool) {
        return s_lastOpenedAt + s_gameInterval < block.timestamp;
    }

    function _setTrapdoorState(TrapdoorState _newTrapdoorState) internal {
        s_GameState = _newTrapdoorState;
        emit TrapdoorStateChanged(_newTrapdoorState);
    }

    function _requestRandomTrapdoor() internal {
        uint256 requestId = vrfConfig.vrfCoordinator.requestRandomWords(
            vrfConfig.gasLane,
            vrfConfig.subscriptionId,
            vrfConfig.requestConfirmations,
            vrfConfig.callbackGasLimit,
            vrfConfig.numWords
        );
        emit RandomTrapdoorRequested(requestId);
    }

    function fulfillRandomWords(
        uint256 /*requestId*/,
        uint256[] memory randomWords
    ) internal override {
        uint256 randomValue = randomWords[0];
        uint256 trapdoorChoice = randomValue % 2;

        emit TrapdoorOpened(trapdoorChoice);

        if (trapdoorChoice == 0) {
            s_lastWinners = s_leftPlayers;
            s_lastTrapdoorSide = TrapdoorChoice.Left;
            _distributePrizes(s_leftPlayers);
        } else {
            _distributePrizes(s_rightPlayers);
            s_lastTrapdoorSide = TrapdoorChoice.Right;
            s_lastWinners = s_rightPlayers;
        }
        _setTrapdoorState(TrapdoorState.Open);
        _updateLastOpenedAt();
        _resetTrapdoorPlayers();

        emit WinnerChosen(s_lastWinners);
    }

    function _distributePrizes(address[] memory winners) internal {
        uint256 prize = s_totalPrizePool / winners.length;
        s_lastPrizeValue = prize;
        for (uint256 i = 0; i < winners.length; i++) {
            (bool success, ) = winners[i].call{value: prize}("");
            if (!success) {
                revert Trapdoor__TransferFailed();
            }
        }
    }

    function _updateLastOpenedAt() internal {
        s_lastOpenedAt = block.timestamp;
    }

    function _resetTrapdoorPlayers() internal {
        delete s_leftPlayers;
        delete s_rightPlayers;
    }

    ////////////////////
    // External / View
    ////////////////////

    function getCurrentPrizePool() external view returns (uint256) {
        return s_totalPrizePool;
    }

    function getTrapdoorState() external view returns (TrapdoorState) {
        return s_GameState;
    }

    function getPlayersCount() external view returns (uint256, uint256) {
        return (s_leftPlayers.length, s_rightPlayers.length);
    }

    function getLeftPlayers() external view returns (address[] memory) {
        return s_leftPlayers;
    }

    function getRightPlayers() external view returns (address[] memory) {
        return s_rightPlayers;
    }

    function getPriceInUsd(uint256 _ethAmount) public view returns (uint256) {
        return _ethAmount.getConversionRate(s_priceFeed);
    }

    function getEthPrice() public view returns (uint256) {
        (, int256 price, , , ) = s_priceFeed.latestRoundData();
        return uint256(price) * 10 ** 10;
    }

    function getLastWinners() external view returns (address[] memory) {
        return s_lastWinners;
    }

    function getFeesAmount() external view returns (uint256) {
        return s_totalFees;
    }

    function getLastPrizeValue() external view returns (uint256) {
        return s_lastPrizeValue;
    }

    function getLastTrapdoorSide() external view returns (TrapdoorChoice) {
        return s_lastTrapdoorSide;
    }

    function getLastOpenedAt() external view returns (uint256) {
        return s_lastOpenedAt;
    }

    function getTicketPriceInEth() external view returns (uint256) {
        uint256 ethPriceInUsd = getEthPrice();
        return (ENTRY_FEE_IN_USD * 10 ** 18) / ethPriceInUsd;
    }

    // @audit Should be onlyOwner prior to prod deployment
    function updateInterval(uint256 _newInterval) external {
        s_gameInterval = _newInterval;
    }
}
