// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IReactor} from "UniswapX/src/interfaces/IReactor.sol";
import {IReactorCallback} from "UniswapX/src/interfaces/IReactorCallback.sol";
import {ResolvedOrder, SignedOrder} from "UniswapX/src/base/ReactorStructs.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @title ISwapRouter02
interface ISwapRouter02 {
    struct ExactInputParams {
        /// @dev abi.encodePacked(tokenIn, fee, [mid, fee,] tokenOut)
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams`
    /// @return amountOut The amount of the received token
    function exactInput(
        ExactInputParams calldata params
    ) external payable returns (uint256 amountOut);
}

/// @title FillerExecutor
/// @notice Permissioned executor contract for UniswapX DutchV3 orders on Arbitrum
/// @dev Implements IReactorCallback to participate in the UniswapX fill flow.
///
///      Fill flow:
///        - Whitelisted caller invokes execute() / executeBatch()
///        - Reactor pulls input tokens from the swapper via Permit2 and sends them here
///        - Reactor calls reactorCallback() on this contract
///        - Contract fills each order: from inventory if possible, otherwise via V3 swap
///        - Reactor pulls approved output tokens and delivers them to the swapper
///
///      callbackData encoding: abi.encode(bytes[] swapPaths)
///        One entry per order. Empty bytes = inventory fill. Non-empty = V3 path.
contract FillerExecutor is IReactorCallback {
    using SafeTransferLib for ERC20;

    IReactor public immutable reactor;
    ISwapRouter02 public immutable swapRouter;
    address public immutable owner;

    mapping(address => bool) public whitelistedCallers;

    error CallerNotWhitelisted();
    error CallerNotReactor();
    error CallerNotOwner();

    modifier onlyWhitelistedCaller() {
        _onlyWhitelistedCaller();
        _;
    }
    modifier onlyReactor() {
        _onlyReactor();
        _;
    }
    modifier onlyOwner() {
        _onlyOwner();
        _;
    }

    function _onlyWhitelistedCaller() internal view {
        if (!whitelistedCallers[msg.sender]) revert CallerNotWhitelisted();
    }

    function _onlyReactor() internal view {
        if (msg.sender != address(reactor)) revert CallerNotReactor();
    }

    function _onlyOwner() internal view {
        if (msg.sender != owner) revert CallerNotOwner();
    }

    /// @param _reactor   Address of the UniswapX DutchV3 reactor
    /// @param _swapRouter Address of Uniswap SwapRouter02
    constructor(IReactor _reactor, ISwapRouter02 _swapRouter) {
        reactor = _reactor;
        swapRouter = _swapRouter;
        owner = msg.sender;
        whitelistedCallers[msg.sender] = true;
    }

    /// @notice Fill a single order
    /// @dev supposed to be called by the backend
    /// @param order The signed UniswapX order
    /// @param callbackData abi.encode(bytes[] swapPaths
    function execute(
        SignedOrder calldata order,
        bytes calldata callbackData
    ) external onlyWhitelistedCaller {
        reactor.executeWithCallback(order, callbackData);
    }

    /// @notice Fill multiple orders atomically
    /// @dev supposed to be called by the backend
    /// @param orders       Array of signed UniswapX orders
    /// @param callbackData abi.encode(bytes[] swapPaths) — one path per order
    function executeBatch(
        SignedOrder[] calldata orders,
        bytes calldata callbackData
    ) external onlyWhitelistedCaller {
        reactor.executeBatchWithCallback(orders, callbackData);
    }

    /// @inheritdoc IReactorCallback
    /// @dev Decodes swapPaths from callbackData and fills each order.
    ///      Forwards any ETH balance to the reactor after all fills complete.
    function reactorCallback(
        ResolvedOrder[] memory resolvedOrders,
        bytes memory callbackData
    ) external override onlyReactor {
        bytes[] memory swapPaths = abi.decode(callbackData, (bytes[]));

        for (uint256 i = 0; i < resolvedOrders.length; ) {
            _fillOrder(resolvedOrders[i], swapPaths[i]);
            unchecked {
                ++i;
            }
        }

        if (address(this).balance > 0) {
            SafeTransferLib.safeTransferETH(
                address(reactor),
                address(this).balance
            );
        }
    }

    /// @dev Fills a single resolved order. Attempts an inventory fill first;
    ///      falls back to a V3 swap if the balance is insufficient.
    ///      Assumes all outputs share the same token, which is standard for
    ///      DutchV3 orders (primary output + optional same-token protocol fee).
    /// @param order    The resolved order to fill
    /// @param swapPath V3 encoded path used if a swap is required; ignored on inventory fill
    function _fillOrder(
        ResolvedOrder memory order,
        bytes memory swapPath
    ) internal {
        address outputToken = order.outputs[0].token;
        uint256 totalRequired;

        for (uint256 i = 0; i < order.outputs.length; ) {
            totalRequired += order.outputs[i].amount;
            unchecked {
                ++i;
            }
        }

        // fill fro minventory if possible
        if (_tryInventoryFill(outputToken, totalRequired)) return;

        // else swap from uniswapV3
        _swapAndApprove(
            address(order.input.token),
            order.input.amount,
            outputToken,
            totalRequired,
            swapPath
        );
    }

    /// @dev Checks whether this contract holds enough `token` to cover `amount`.
    ///      If so, approves the reactor for exactly `amount` and returns true.
    ///      Returns false without any state change if balance is insufficient.
    /// @param token  ERC20 token address
    /// @param amount Required token amount
    /// @return filled True if inventory was sufficient and approval was set
    function _tryInventoryFill(
        address token,
        uint256 amount
    ) internal returns (bool filled) {
        if (ERC20(token).balanceOf(address(this)) < amount) return false;
        ERC20(token).safeApprove(address(reactor), amount);
        return true;
    }

    /// @dev Swaps `amountIn` of `tokenIn` for `tokenOut` via SwapRouter02.exactInput.
    ///      `amountOutMin` is set to the order's required output, acting as an on-chain
    ///      price check — the call reverts if the pool cannot satisfy the required price.
    ///      After the swap, approves the reactor for the full resulting tokenOut balance.
    /// @param tokenIn     Token received from the reactor (swapper's input)
    /// @param amountIn    Amount of tokenIn to swap
    /// @param tokenOut    Token the swapper expects to receive
    /// @param amountOutMin Minimum acceptable output; equals the order's required amount
    /// @param path        ABI-packed V3 swap path: abi.encodePacked(tokenIn, fee, tokenOut)
    function _swapAndApprove(
        address tokenIn,
        uint256 amountIn,
        address tokenOut,
        uint256 amountOutMin,
        bytes memory path
    ) internal {
        ERC20(tokenIn).safeApprove(address(swapRouter), amountIn);

        swapRouter.exactInput(
            ISwapRouter02.ExactInputParams({
                path: path,
                recipient: address(this),
                amountIn: amountIn,
                amountOutMinimum: amountOutMin
            })
        );

        ERC20(tokenOut).safeApprove(
            address(reactor),
            ERC20(tokenOut).balanceOf(address(this))
        );
    }

    /// @notice Grant or revoke fill permissions for a caller address
    /// @param caller  Address to update
    /// @param allowed True to whitelist, false to remove
    function setWhitelistedCaller(
        address caller,
        bool allowed
    ) external onlyOwner {
        whitelistedCallers[caller] = allowed;
    }

    /// @notice Withdraw the entire balance of an ERC20 token held by this contract
    /// @param token Token to withdraw
    /// @param to    Recipient address
    function withdrawERC20(ERC20 token, address to) external onlyOwner {
        token.safeTransfer(to, token.balanceOf(address(this)));
    }

    /// @notice Withdraw all ETH held by this contract
    /// @param to Recipient address
    function withdrawEth(address payable to) external onlyOwner {
        SafeTransferLib.safeTransferETH(to, address(this).balance);
    }

    receive() external payable {}
}
