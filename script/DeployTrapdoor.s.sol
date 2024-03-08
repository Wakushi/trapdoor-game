// SPDX-License-Identifier: MIT

pragma solidity ^0.8.18;

import {Script} from "forge-std/Script.sol";
import {Trapdoor} from "../src/Trapdoor.sol";
import {HelperConfig} from "./HelperConfig.s.sol";
import {CreateSubscription, FundSubscription, AddConsumer} from "./Interaction.s.sol";

contract DeployTrapdoor is Script {
    function run() external returns (Trapdoor, HelperConfig) {
        HelperConfig helperConfig = new HelperConfig();
        (
            address vrfCoordinator,
            bytes32 gasLane,
            uint64 subscriptionId,
            uint32 callbackGasLimit,
            address link,
            uint256 deployerKey,
            address priceFeed
        ) = helperConfig.activeNetworkConfig();

        if (subscriptionId == 0) {
            CreateSubscription createSubscription = new CreateSubscription();
            subscriptionId = createSubscription.createSubscription(
                vrfCoordinator,
                deployerKey
            );
            FundSubscription fundSubscription = new FundSubscription();
            fundSubscription.fundSubscription(
                vrfCoordinator,
                subscriptionId,
                link,
                deployerKey
            );
        }

        Trapdoor.TrapdoorConfig memory config = Trapdoor.TrapdoorConfig({
            vrfCoordinator: vrfCoordinator,
            priceFeed: priceFeed,
            gasLane: gasLane,
            subscriptionId: subscriptionId,
            callbackGasLimit: callbackGasLimit
        });

        vm.startBroadcast();
        Trapdoor trapdoor = new Trapdoor(config);
        vm.stopBroadcast();

        AddConsumer addConsumer = new AddConsumer();
        addConsumer.addConsumer(
            address(trapdoor),
            vrfCoordinator,
            subscriptionId,
            deployerKey
        );
        return (trapdoor, helperConfig);
    }
}
