// SPDX-License-Identifier: MIT

pragma solidity 0.8.13;

interface IEndpoint {

    struct MsgInfo {
        address sender;
        address receiver;
        uint64 srcChainId;
        bytes32 srcTxHash; // src chain msg tx hash
    }

    /**
     * @notice Sends a message to a receiving contract address on another chain. 
     * Sender must make sure that the message is unique and not a duplicate message.
     * @param _receiver The bytes32 address of the destination contract to be called
     * @param _chainId The destination chain ID - typically, standard EVM chain ID, but differs on nonEVM chains
     * @param _message The arbitrary payload to pass to the destination chain receiver
     */
    function sendMessage(
        bytes32 _receiver,
        uint256 _chainId,
        bytes calldata _message
    ) external;

    /**
     * @notice Relayer executes messages through an authenticated method to the destination receiver
     based on the originating transaction on source chain
     * @param _srcChainId Originating chain ID - typically a standard EVM chain ID, but may refer to a Synapse-specific chain ID on nonEVM chains
     * @param _srcAddress Originating bytes address of the message sender on the srcChain
     * @param _dstAddress Destination address that the arbitrary message will be passed to
     * @param _gasLimit Gas limit to be passed alongside the message, depending on the fee paid on srcChain
     * @param _message Arbitrary message payload to pass to the destination chain receiver
     */
    function executeMessage(
        uint256 _srcChainId,
        bytes32 _srcAddress,
        address _dstAddress,
        uint _gasLimit,
        bytes calldata _message
    ) external payable;

    /**
     * @notice Withdraws message fee in the form of native gas token.
     * @param _account The address receiving the fee.
     */
    function withdrawFee(
        address _account
    ) external;

}
