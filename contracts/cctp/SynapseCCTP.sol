// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {SynapseCCTPEvents} from "./events/SynapseCCTPEvents.sol";
import {IMessageTransmitter} from "./interfaces/IMessageTransmitter.sol";
import {ISynapseCCTP} from "./interfaces/ISynapseCCTP.sol";
import {ITokenMessenger} from "./interfaces/ITokenMessenger.sol";
import {Request, RequestLib} from "./libs/Request.sol";
import {MinimalForwarderLib} from "./libs/MinimalForwarder.sol";
import {TypeCasts} from "./libs/TypeCasts.sol";

contract SynapseCCTP is SynapseCCTPEvents, ISynapseCCTP {
    using MinimalForwarderLib for address;
    using TypeCasts for address;
    using TypeCasts for bytes32;

    // TODO: add setters for these (or make them immutable)
    uint32 public localDomain;
    IMessageTransmitter public messageTransmitter;
    ITokenMessenger public tokenMessenger;
    mapping(uint32 => bytes32) public remoteSynapseCCTP;

    /// @inheritdoc ISynapseCCTP
    function sendCircleToken(
        address recipient,
        uint32 destinationDomain,
        address burnToken,
        uint256 amount,
        uint32 requestVersion,
        bytes memory swapParams
    ) external {
        uint64 nonce = messageTransmitter.nextAvailableNonce();
        // This will revert if the request version is not supported, or swap params are not properly formatted.
        bytes memory formattedRequest = RequestLib.formatRequest(
            requestVersion,
            RequestLib.formatBaseRequest(localDomain, nonce, burnToken, amount, recipient),
            swapParams
        );
        // Construct the request identifier to be used as salt later.
        // Origin domain and nonce are already part of the request, so we only need to add the destination domain.
        bytes32 dstSynapseCCTP = remoteSynapseCCTP[destinationDomain];
        bytes32 kappa = _kappa(destinationDomain, requestVersion, formattedRequest);
        tokenMessenger.depositForBurnWithCaller(
            amount,
            destinationDomain,
            dstSynapseCCTP,
            burnToken,
            _destinationCaller(dstSynapseCCTP.bytes32ToAddress(), kappa)
        );
        emit CircleRequestSent(destinationDomain, nonce, requestVersion, formattedRequest, kappa);
    }

    // TODO: guard this to be only callable by the validators?
    /// @inheritdoc ISynapseCCTP
    function receiveCircleToken(
        bytes calldata message,
        bytes calldata signature,
        uint32 requestVersion,
        bytes memory formattedRequest
    ) external {
        // This will revert if the request version is not supported, or request is not properly formatted.
        Request request = RequestLib.wrapRequest(requestVersion, formattedRequest);
        bytes32 kappa = _kappa(localDomain, requestVersion, formattedRequest);
        // Kindly ask the Circle Bridge to mint the tokens for us.
        _mintCircleToken(message, signature, kappa);
        (address token, uint256 amount) = _getMintedToken(request);
        uint256 fee;
        // Apply the bridging fee. This will revert if amount <= fee.
        (amount, fee) = _applyFee(token, amount);
        // Fulfill the request: perform an optional swap and send the end tokens to the recipient.
        address recipient = _fulfillRequest(token, amount, request);
        emit CircleRequestFulfilled(recipient, token, amount, fee, kappa);
    }

    // ══════════════════════════════════════════════ INTERNAL LOGIC ═══════════════════════════════════════════════════

    /// @dev Applies the bridging fee. Will revert if amount <= fee.
    function _applyFee(address token, uint256 amount) internal returns (uint256 amountAfterFee, uint256 fee) {
        // TODO: implement
    }

    /// @dev Mints the Circle token by sending the message and signature to the Circle Bridge.
    function _mintCircleToken(
        bytes calldata message,
        bytes calldata signature,
        bytes32 kappa
    ) internal {
        // Deploy a forwarder specific to this request. Will revert if the kappa has been used before.
        address forwarder = MinimalForwarderLib.deploy(kappa);
        // Form the payload for the Circle Bridge.
        bytes memory payload = abi.encodeWithSelector(IMessageTransmitter.receiveMessage.selector, message, signature);
        // Use the deployed forwarder (who is the only one who can call the Circle Bridge for this message)
        // This will revert if the provided message is not properly formatted, or if the signatures are invalid.
        forwarder.forwardCall(address(messageTransmitter), payload);
    }

    /// @dev Performs a swap, if was requested back on origin chain, and transfers the tokens to the recipient.
    /// Should the swap fail, will transfer `token` to the recipient instead.
    function _fulfillRequest(
        address token,
        uint256 amount,
        Request request
    ) internal returns (address recipient) {
        // TODO: implement
    }

    // ══════════════════════════════════════════════ INTERNAL VIEWS ═══════════════════════════════════════════════════

    /// @dev Fetches the address and the amount of the minted Circle token.
    function _getMintedToken(Request request) internal view returns (address token, uint256 amount) {
        // TODO: implement
    }

    /// @dev Predicts the address of the destination caller.
    function _destinationCaller(address synapseCCTP, bytes32 kappa) internal pure returns (bytes32) {
        return synapseCCTP.predictAddress(kappa).addressToBytes32();
    }

    /// @dev Calculates the unique identifier of the request.
    function _kappa(
        uint32 destinationDomain,
        uint32 requestVersion,
        bytes memory request
    ) internal pure returns (bytes32 kappa) {
        // Merge the destination domain and the request version into a single uint256.
        uint256 prefix = (uint256(destinationDomain) << 32) | requestVersion;
        bytes32 requestHash = keccak256(request);
        // Use assembly to return hash of the prefix and the request hash.
        // We are using scratch space to avoid unnecessary memory expansion.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Store prefix in memory at 0x00, and requestHash at 0x20.
            mstore(0x00, prefix)
            mstore(0x20, requestHash)
            // Return hash of first 64 bytes of memory.
            kappa := keccak256(0, 64)
        }
    }
}
