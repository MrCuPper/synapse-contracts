// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

interface ITokenMinter {
    /**
     * @notice Mints `amount` of local tokens corresponding to the
     * given (`sourceDomain`, `burnToken`) pair, to `to` address.
     * @dev reverts if the (`sourceDomain`, `burnToken`) pair does not
     * map to a nonzero local token address. This mapping can be queried using
     * getLocalToken().
     * @param sourceDomain Source domain where `burnToken` was burned.
     * @param burnToken Burned token address as bytes32.
     * @param to Address to receive minted tokens, corresponding to `burnToken`,
     * on this domain.
     * @param amount Amount of tokens to mint. Must be less than or equal
     * to the minterAllowance of this TokenMinter for given `_mintToken`.
     * @return mintToken token minted.
     */
    function mint(
        uint32 sourceDomain,
        bytes32 burnToken,
        address to,
        uint256 amount
    ) external returns (address mintToken);

    /**
     * @notice Burn tokens owned by this ITokenMinter.
     * @param burnToken burnable token.
     * @param amount amount of tokens to burn. Must be less than or equal to this ITokenMinter's
     * account balance of the given `_burnToken`.
     */
    function burn(address burnToken, uint256 amount) external;

    /**
     * @notice Get the local token associated with the given remote domain and token.
     * @param remoteDomain Remote domain
     * @param remoteToken Remote token
     * @return local token address
     */
    function getLocalToken(uint32 remoteDomain, bytes32 remoteToken) external view returns (address);

    // local token (address) => maximum burn amounts per message
    function burnLimitsPerMessage(address token) external view returns (uint256);
}
