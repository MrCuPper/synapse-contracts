// SPDX-License-Identifier: MIT
pragma solidity 0.8.17;

import {CCTPMessageNotReceived, LocalCCTPTokenNotFound, RemoteCCTPDeploymentNotSet, RemoteCCTPTokenNotSet} from "./libs/Errors.sol";
import {SynapseCCTPEvents} from "./events/SynapseCCTPEvents.sol";
import {IDefaultPool} from "./interfaces/IDefaultPool.sol";
import {IMessageTransmitter} from "./interfaces/IMessageTransmitter.sol";
import {ISynapseCCTP} from "./interfaces/ISynapseCCTP.sol";
import {ITokenMinter} from "./interfaces/ITokenMinter.sol";
import {ITokenMessenger} from "./interfaces/ITokenMessenger.sol";
import {RequestLib} from "./libs/Request.sol";
import {MinimalForwarderLib} from "./libs/MinimalForwarder.sol";
import {TypeCasts} from "./libs/TypeCasts.sol";

import {SafeERC20, IERC20} from "@openzeppelin/contracts-4.5.0/token/ERC20/utils/SafeERC20.sol";

contract SynapseCCTP is SynapseCCTPEvents, ISynapseCCTP {
    using MinimalForwarderLib for address;
    using SafeERC20 for IERC20;
    using TypeCasts for address;
    using TypeCasts for bytes32;

    /// @notice Struct defining the configuration of a remote domain that has SynapseCCTP deployed.
    /// @dev CCTP uses the following convention for domain numbers:
    /// - 0: Ethereum Mainnet
    /// - 1: Avalanche Mainnet
    /// With more chains added, the convention will be extended.
    /// @param domain       Value for the remote domain used in CCTP messages.
    /// @param synapseCCTP  Address of the SynapseCCTP deployed on the remote chain.
    struct DomainConfig {
        uint32 domain;
        address synapseCCTP;
    }

    /// @notice Refers to the local domain number used in CCTP messages.
    uint32 public immutable localDomain;
    IMessageTransmitter public immutable messageTransmitter;
    ITokenMessenger public immutable tokenMessenger;

    // TODO: onlyOwner setters for these
    // (chainId => configuration of the remote chain)
    mapping(uint256 => DomainConfig) public remoteDomainConfig;
    mapping(uint256 => address) internal _remoteTokenIdToLocalToken;

    constructor(ITokenMessenger tokenMessenger_) {
        tokenMessenger = tokenMessenger_;
        messageTransmitter = IMessageTransmitter(tokenMessenger_.localMessageTransmitter());
        localDomain = messageTransmitter.localDomain();
    }

    // ═════════════════════════════════════════════ SET CONFIG LOGIC ══════════════════════════════════════════════════

    /// @notice Sets the local token associated with the given remote domain and token.
    // TODO: add ownerOnly modifier
    function setLocalToken(uint32 remoteDomain, address remoteToken) external {
        ITokenMinter minter = ITokenMinter(tokenMessenger.localMinter());
        address localToken = minter.getLocalToken(remoteDomain, remoteToken.addressToBytes32());
        if (localToken == address(0)) revert LocalCCTPTokenNotFound();
        _remoteTokenIdToLocalToken[_remoteTokenId(remoteDomain, remoteToken)] = localToken;
    }

    /// @notice Sets the remote domain and deployment of SynapseCCTP for the given remote chainId.
    // TODO: add ownerOnly modifier
    function setRemoteDomainConfig(
        uint256 remoteChainId,
        uint32 remoteDomain,
        address remoteSynapseCCTP
    ) external {
        // TODO: add zero checks
        remoteDomainConfig[remoteChainId] = DomainConfig(remoteDomain, remoteSynapseCCTP);
    }

    // ════════════════════════════════════════════════ CCTP LOGIC ═════════════════════════════════════════════════════

    /// @inheritdoc ISynapseCCTP
    function sendCircleToken(
        address recipient,
        uint256 chainId,
        address burnToken,
        uint256 amount,
        uint32 requestVersion,
        bytes memory swapParams
    ) external {
        // Pull token from user and update the amount in case of transfer fee.
        amount = _pullToken(burnToken, amount);
        uint64 nonce = messageTransmitter.nextAvailableNonce();
        // This will revert if the request version is not supported, or swap params are not properly formatted.
        bytes memory formattedRequest = RequestLib.formatRequest(
            requestVersion,
            RequestLib.formatBaseRequest(localDomain, nonce, burnToken, amount, recipient),
            swapParams
        );
        DomainConfig memory config = remoteDomainConfig[chainId];
        bytes32 dstSynapseCCTP = config.synapseCCTP.addressToBytes32();
        if (dstSynapseCCTP == 0) revert RemoteCCTPDeploymentNotSet();
        uint32 destinationDomain = config.domain;
        // Construct the request identifier to be used as salt later.
        // The identifier (kappa) is unique for every single request on all the chains.
        // This is done by including origin and destination domains as well as origin nonce in the hashed data.
        // Origin domain and nonce are included in `formattedRequest`, so we only need to add the destination domain.
        bytes32 kappa = _kappa(destinationDomain, requestVersion, formattedRequest);
        // Issue allowance if needed
        _approveToken(burnToken, address(tokenMessenger), amount);
        tokenMessenger.depositForBurnWithCaller(
            amount,
            destinationDomain,
            dstSynapseCCTP,
            burnToken,
            _destinationCaller(dstSynapseCCTP.bytes32ToAddress(), kappa)
        );
        emit CircleRequestSent(chainId, nonce, burnToken, amount, requestVersion, formattedRequest, kappa);
    }

    // TODO: guard this to be only callable by the validators?
    /// @inheritdoc ISynapseCCTP
    function receiveCircleToken(
        bytes calldata message,
        bytes calldata signature,
        uint32 requestVersion,
        bytes memory formattedRequest
    ) external {
        (bytes memory baseRequest, bytes memory swapParams) = RequestLib.decodeRequest(
            requestVersion,
            formattedRequest
        );
        (uint32 originDomain, , address originBurnToken, uint256 amount, address recipient) = RequestLib
            .decodeBaseRequest(baseRequest);
        // For kappa hashing we use origin and destination domains as well as origin nonce.
        // This ensures that kappa is unique for each request, and that it is not possible to replay requests.
        bytes32 kappa = _kappa(localDomain, requestVersion, formattedRequest);
        // Kindly ask the Circle Bridge to mint the tokens for us.
        _mintCircleToken(message, signature, kappa);
        address token = _getLocalMintedToken(originDomain, originBurnToken);
        uint256 fee;
        // Apply the bridging fee. This will revert if amount <= fee.
        (amount, fee) = _applyFee(token, amount);
        // Fulfill the request: perform an optional swap and send the end tokens to the recipient.
        (address tokenOut, uint256 amountOut) = _fulfillRequest(recipient, token, amount, swapParams);
        emit CircleRequestFulfilled(recipient, token, fee, tokenOut, amountOut, kappa);
    }

    // ═══════════════════════════════════════════════════ VIEWS ═══════════════════════════════════════════════════════

    /// @notice Get the local token associated with the given remote domain and token.
    function getLocalToken(uint32 remoteDomain, address remoteToken) external view returns (address) {
        return _remoteTokenIdToLocalToken[_remoteTokenId(remoteDomain, remoteToken)];
    }

    // ══════════════════════════════════════════════ INTERNAL LOGIC ═══════════════════════════════════════════════════

    /// @dev Applies the bridging fee. Will revert if amount <= fee.
    function _applyFee(address token, uint256 amount) internal returns (uint256 amountAfterFee, uint256 fee) {
        // TODO: implement actual fee logic
        return (amount, 0);
    }

    /// @dev Approves the token to be spent by the given spender indefinitely by giving infinite allowance.
    /// Doesn't modify the allowance if it's already enough for the given amount.
    function _approveToken(
        address token,
        address spender,
        uint256 amount
    ) internal {
        uint256 allowance = IERC20(token).allowance(address(this), spender);
        if (allowance < amount) {
            // Reset allowance to 0 before setting it to the new value.
            if (allowance != 0) IERC20(token).safeApprove(spender, 0);
            IERC20(token).safeApprove(spender, type(uint256).max);
        }
    }

    /// @dev Pulls the token from the sender.
    function _pullToken(address token, uint256 amount) internal returns (uint256 amountPulled) {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        amountPulled = IERC20(token).balanceOf(address(this)) - balanceBefore;
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
        bytes memory returnData = forwarder.forwardCall(address(messageTransmitter), payload);
        // messageTransmitter.receiveMessage is supposed to return true if the message was received.
        if (!abi.decode(returnData, (bool))) revert CCTPMessageNotReceived();
    }

    /// @dev Performs a swap, if was requested back on origin chain, and transfers the tokens to the recipient.
    /// Should the swap fail, will transfer `token` to the recipient instead.
    function _fulfillRequest(
        address recipient,
        address token,
        uint256 amount,
        bytes memory swapParams
    ) internal returns (address tokenOut, uint256 amountOut) {
        // Fallback to Base Request if no swap params are provided
        if (swapParams.length == 0) {
            IERC20(token).safeTransfer(recipient, amount);
            return (token, amount);
        }
        // We checked request version to be a valid value when wrapping into `request`,
        // so this could only be `RequestLib.REQUEST_SWAP`.
        (address pool, uint8 tokenIndexFrom, uint8 tokenIndexTo, uint256 deadline, uint256 minAmountOut) = RequestLib
            .decodeSwapParams(swapParams);
        tokenOut = _tryGetToken(pool, tokenIndexTo);
        // Fallback to Base Request if failed to get tokenOut address
        if (tokenOut == address(0)) {
            IERC20(token).safeTransfer(recipient, amount);
            return (token, amount);
        }
        // Approve the pool to spend the token, if needed.
        _approveToken(token, pool, amount);
        amountOut = _trySwap(pool, tokenIndexFrom, tokenIndexTo, amount, deadline, minAmountOut);
        // Fallback to Base Request if failed to swap
        if (amountOut == 0) {
            IERC20(token).safeTransfer(recipient, amount);
            return (token, amount);
        }
        // Transfer the swapped tokens to the recipient.
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
    }

    /// @dev Tries to swap tokens using the provided swap instructions.
    /// Instead of reverting, returns 0 if the swap failed.
    function _trySwap(
        address pool,
        uint8 tokenIndexFrom,
        uint8 tokenIndexTo,
        uint256 amount,
        uint256 deadline,
        uint256 minAmountOut
    ) internal returns (uint256 amountOut) {
        try IDefaultPool(pool).swap(tokenIndexFrom, tokenIndexTo, amount, minAmountOut, deadline) returns (
            uint256 amountOut_
        ) {
            amountOut = amountOut_;
        } catch {
            // Swapping failed, return 0
            amountOut = 0;
        }
    }

    // ══════════════════════════════════════════════ INTERNAL VIEWS ═══════════════════════════════════════════════════

    /// @dev Fetches the address and the amount of the minted Circle token.
    function _getLocalMintedToken(uint32 originDomain, address originBurnToken) internal view returns (address token) {
        // Map the remote token to the local token.
        token = _remoteTokenIdToLocalToken[_remoteTokenId(originDomain, originBurnToken)];
        if (token == address(0)) revert RemoteCCTPTokenNotSet();
    }

    /// @dev Tries to get the token address from the pool.
    /// Instead of reverting, returns 0 if the getToken failed.
    function _tryGetToken(address pool, uint8 tokenIndex) internal view returns (address token) {
        try IDefaultPool(pool).getToken(tokenIndex) returns (address _token) {
            token = _token;
        } catch {
            // Return 0 on revert
            token = address(0);
        }
    }

    /// @dev Predicts the address of the destination caller that will be used to call the Circle Message Transmitter.
    function _destinationCaller(address synapseCCTP, bytes32 kappa) internal pure returns (bytes32) {
        return synapseCCTP.predictAddress(kappa).addressToBytes32();
    }

    /// @dev Calculates the unique identifier of the request.
    function _kappa(
        uint32 destinationDomain,
        uint32 requestVersion,
        bytes memory formattedRequest
    ) internal pure returns (bytes32 kappa) {
        // Merge the destination domain and the request version into a single uint256.
        uint256 prefix = (uint256(destinationDomain) << 32) | requestVersion;
        bytes32 requestHash = keccak256(formattedRequest);
        // Use assembly to return hash of the prefix and the request hash.
        // We are using scratch space to avoid unnecessary memory expansion.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            // Store prefix in memory at 0, and requestHash at 32.
            mstore(0, prefix)
            mstore(32, requestHash)
            // Return hash of first 64 bytes of memory.
            kappa := keccak256(0, 64)
        }
    }

    /// @dev Packs the domain and the token into a single uint256 value using bitwise operations.
    function _remoteTokenId(uint32 remoteDomain, address remoteToken) internal pure returns (uint256) {
        return (uint256(remoteDomain) << 160) | uint160(remoteToken);
    }
}