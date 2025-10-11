// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.18;

/**
 * @title IYearnVaultFactory
 * @notice Interface for Yearn Vault Factory (0x770D0d1Fb036483Ed4AbB6d53c1C88fb277D812F)
 */
interface IYearnVaultFactory {
    /**
     * @notice Deploy a new Yearn V3 Vault
     * @param asset The underlying asset for the vault
     * @param name The vault name
     * @param symbol The vault symbol
     * @param role_manager The address that will manage roles
     * @param profit_max_unlock_time Maximum time for profit unlocking
     * @return The address of the deployed vault
     */
    function deploy_new_vault(
        address asset,
        string memory name,
        string memory symbol,
        address role_manager,
        uint256 profit_max_unlock_time
    ) external returns (address);
}
