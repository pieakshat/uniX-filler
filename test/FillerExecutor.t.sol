// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";
import {FillerExecutor, ISwapRouter02} from "../src/fillerExecutor.sol";
import {IReactor} from "UniswapX/src/interfaces/IReactor.sol";
import {ResolvedOrder, SignedOrder, OrderInfo, InputToken, OutputToken} from "UniswapX/src/base/ReactorStructs.sol";
import {IValidationCallback} from "UniswapX/src/interfaces/IValidationCallback.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

// ─── Mocks ────────────────────────────────────────────────────────────────────

contract MockERC20 is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol, 18) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @dev Simulates SwapRouter02.exactInput by minting tokenOut to the recipient.
///      The real router would pull tokenIn (approved to it) and push tokenOut.
contract MockSwapRouter {
    MockERC20 public outputToken;

    function setOutputToken(MockERC20 token) external {
        outputToken = token;
    }

    function exactInput(ISwapRouter02.ExactInputParams calldata params)
        external payable returns (uint256 amountOut)
    {
        // Mint amountOutMinimum of output tokens to the recipient (simulates swap)
        outputToken.mint(params.recipient, params.amountOutMinimum);
        return params.amountOutMinimum;
    }
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

/// @dev Builds a minimal ResolvedOrder with one input and one output.
function makeOrder(
    address inputToken,
    uint256 inputAmount,
    address outputToken,
    uint256 outputAmount,
    address outputRecipient
) pure returns (ResolvedOrder memory order) {
    order.input = InputToken({
        token:     ERC20(inputToken),
        amount:    inputAmount,
        maxAmount: inputAmount
    });

    order.outputs = new OutputToken[](1);
    order.outputs[0] = OutputToken({
        token:     outputToken,
        amount:    outputAmount,
        recipient: outputRecipient
    });
}

// ─── Tests ────────────────────────────────────────────────────────────────────

contract FillerExecutorTest is Test {
    using SafeTransferLib for ERC20;

    FillerExecutor  executor;
    MockSwapRouter  mockRouter;
    MockERC20       tokenIn;
    MockERC20       tokenOut;

    address reactor;
    address stranger;
    address swapper;

    // V3 path: abi.encodePacked(tokenIn, fee, tokenOut) — decoded by SwapRouter02
    bytes constant DUMMY_PATH = hex"aabbcc";

    function setUp() public {
        reactor  = makeAddr("reactor");
        stranger = makeAddr("stranger");
        swapper  = makeAddr("swapper");

        mockRouter = new MockSwapRouter();
        executor   = new FillerExecutor(IReactor(reactor), ISwapRouter02(address(mockRouter)));

        tokenIn  = new MockERC20("Token In",  "TIN");
        tokenOut = new MockERC20("Token Out", "TOUT");

        mockRouter.setOutputToken(tokenOut);
    }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    /// Build callbackData for a single order with the given V3 swap path.
    function _callbackData(bytes memory swapPath) internal pure returns (bytes memory) {
        bytes[] memory paths = new bytes[](1);
        paths[0] = swapPath;
        return abi.encode(paths);
    }

    /// Build a ResolvedOrder array with one entry.
    function _singleOrder(uint256 inputAmt, uint256 outputAmt) internal view returns (ResolvedOrder[] memory) {
        ResolvedOrder[] memory orders = new ResolvedOrder[](1);
        orders[0] = makeOrder(address(tokenIn), inputAmt, address(tokenOut), outputAmt, swapper);
        return orders;
    }

    // ─── Access Control ───────────────────────────────────────────────────────

    function test_StrangerCannotCallExecute() public {
        vm.prank(stranger);
        vm.expectRevert(FillerExecutor.CallerNotWhitelisted.selector);
        executor.execute(SignedOrder({order: "", sig: ""}), "");
    }

    function test_StrangerCannotCallExecuteBatch() public {
        vm.prank(stranger);
        vm.expectRevert(FillerExecutor.CallerNotWhitelisted.selector);
        executor.executeBatch(new SignedOrder[](0), "");
    }

    function test_StrangerCannotCallReactorCallback() public {
        vm.prank(stranger);
        vm.expectRevert(FillerExecutor.CallerNotReactor.selector);
        executor.reactorCallback(new ResolvedOrder[](0), "");
    }

    function test_StrangerCannotSetWhitelistedCaller() public {
        vm.prank(stranger);
        vm.expectRevert(FillerExecutor.CallerNotOwner.selector);
        executor.setWhitelistedCaller(stranger, true);
    }

    function test_StrangerCannotWithdrawERC20() public {
        vm.prank(stranger);
        vm.expectRevert(FillerExecutor.CallerNotOwner.selector);
        executor.withdrawERC20(ERC20(address(tokenOut)), stranger);
    }

    function test_StrangerCannotWithdrawEth() public {
        vm.prank(stranger);
        vm.expectRevert(FillerExecutor.CallerNotOwner.selector);
        executor.withdrawEth(payable(stranger));
    }

    // ─── Whitelist ────────────────────────────────────────────────────────────

    function test_OwnerIsWhitelistedAtDeploy() public view {
        assertTrue(executor.whitelistedCallers(address(this)));
    }

    function test_SetWhitelistedCaller() public {
        assertFalse(executor.whitelistedCallers(stranger));
        executor.setWhitelistedCaller(stranger, true);
        assertTrue(executor.whitelistedCallers(stranger));
    }

    function test_RevokeWhitelistedCaller() public {
        executor.setWhitelistedCaller(stranger, true);
        executor.setWhitelistedCaller(stranger, false);
        assertFalse(executor.whitelistedCallers(stranger));
    }

    // ─── Inventory (OTC) Fill ─────────────────────────────────────────────────

    /// When executor already holds enough output tokens, it should fill OTC:
    /// no swap, just approve the exact required amount to the reactor.
    function test_InventoryFill_ApprovesExactAmount() public {
        uint256 outputAmount = 950e18;

        // Seed executor with output tokens (inventory)
        tokenOut.mint(address(executor), outputAmount);
        // Input tokens arrive from the reactor (we simulate that here)
        tokenIn.mint(address(executor), 1_000e18);

        ResolvedOrder[] memory orders = _singleOrder(1_000e18, outputAmount);

        // Empty swapPath → inventory fill expected, but _tryInventoryFill returns
        // true before we ever need the path, so any path (including empty) works.
        vm.prank(reactor);
        executor.reactorCallback(orders, _callbackData(""));

        // Reactor should be approved for exactly the required output amount
        assertEq(tokenOut.allowance(address(executor), reactor), outputAmount);
        // SwapRouter should NOT have been touched
        assertEq(tokenIn.allowance(address(executor), address(mockRouter)), 0);
    }

    /// Inventory fill still works when executor holds MORE than required.
    function test_InventoryFill_SurplusBalance() public {
        uint256 outputAmount = 500e18;
        uint256 surplus      = 200e18;

        tokenOut.mint(address(executor), outputAmount + surplus);
        tokenIn.mint(address(executor), 1_000e18);

        ResolvedOrder[] memory orders = _singleOrder(1_000e18, outputAmount);

        vm.prank(reactor);
        executor.reactorCallback(orders, _callbackData(""));

        // Only the required amount is approved (not the surplus)
        assertEq(tokenOut.allowance(address(executor), reactor), outputAmount);
    }

    /// With a fee output: two OutputToken entries for the same token.
    /// The contract should sum both and approve the total.
    function test_InventoryFill_WithFeeOutput() public {
        uint256 mainOutput = 900e18;
        uint256 feeOutput  = 10e18;
        uint256 total      = mainOutput + feeOutput;

        tokenOut.mint(address(executor), total);
        tokenIn.mint(address(executor), 1_000e18);

        // Build order with two outputs (main + fee)
        ResolvedOrder[] memory orders = new ResolvedOrder[](1);
        orders[0].input = InputToken({token: ERC20(address(tokenIn)), amount: 1_000e18, maxAmount: 1_000e18});
        orders[0].outputs = new OutputToken[](2);
        orders[0].outputs[0] = OutputToken({token: address(tokenOut), amount: mainOutput, recipient: swapper});
        orders[0].outputs[1] = OutputToken({token: address(tokenOut), amount: feeOutput,  recipient: makeAddr("fee")});

        bytes[] memory paths = new bytes[](1);
        paths[0] = "";

        vm.prank(reactor);
        executor.reactorCallback(orders, abi.encode(paths));

        assertEq(tokenOut.allowance(address(executor), reactor), total);
    }

    // ─── V3 Swap Fill ─────────────────────────────────────────────────────────

    /// When executor has NO output tokens, it should swap via SwapRouter02.
    function test_V3Fill_SwapsWhenNoInventory() public {
        uint256 inputAmount  = 1_000e18;
        uint256 outputAmount = 950e18;

        // Input tokens from reactor, no output tokens pre-loaded
        tokenIn.mint(address(executor), inputAmount);

        ResolvedOrder[] memory orders = _singleOrder(inputAmount, outputAmount);

        vm.prank(reactor);
        executor.reactorCallback(orders, _callbackData(DUMMY_PATH));

        // MockSwapRouter minted outputAmount to executor; executor approved reactor
        assertEq(tokenOut.allowance(address(executor), reactor), outputAmount);
        // tokenIn was approved to the swap router
        assertEq(tokenIn.allowance(address(executor), address(mockRouter)), inputAmount);
    }

    /// When executor has PARTIAL inventory (less than required), it should swap.
    function test_V3Fill_SwapsWhenPartialInventory() public {
        uint256 inputAmount  = 1_000e18;
        uint256 outputAmount = 950e18;

        tokenIn.mint(address(executor), inputAmount);
        tokenOut.mint(address(executor), outputAmount - 1); // one short

        ResolvedOrder[] memory orders = _singleOrder(inputAmount, outputAmount);

        vm.prank(reactor);
        executor.reactorCallback(orders, _callbackData(DUMMY_PATH));

        // Swap was executed (mockRouter minted outputAmount), reactor is approved
        // for the full post-swap balance: (outputAmount - 1) + outputAmount
        uint256 expectedBalance = (outputAmount - 1) + outputAmount;
        assertEq(tokenOut.allowance(address(executor), reactor), expectedBalance);
    }

    // ─── ETH Forwarding ───────────────────────────────────────────────────────

    function test_ReactorCallback_ForwardsETH() public {
        vm.deal(address(executor), 1 ether);
        tokenOut.mint(address(executor), 100e18);
        tokenIn.mint(address(executor), 100e18);

        ResolvedOrder[] memory orders = _singleOrder(100e18, 100e18);
        uint256 reactorBalanceBefore = reactor.balance;

        vm.prank(reactor);
        executor.reactorCallback(orders, _callbackData(""));

        assertEq(address(executor).balance, 0);
        assertEq(reactor.balance, reactorBalanceBefore + 1 ether);
    }

    // ─── Admin Withdrawals ────────────────────────────────────────────────────

    function test_WithdrawERC20() public {
        tokenIn.mint(address(executor), 5_000e18);
        address recipient = makeAddr("recipient");
        executor.withdrawERC20(ERC20(address(tokenIn)), recipient);
        assertEq(tokenIn.balanceOf(recipient), 5_000e18);
        assertEq(tokenIn.balanceOf(address(executor)), 0);
    }

    function test_WithdrawEth() public {
        vm.deal(address(executor), 2 ether);
        address payable recipient = payable(makeAddr("recipient"));
        executor.withdrawEth(recipient);
        assertEq(recipient.balance, 2 ether);
        assertEq(address(executor).balance, 0);
    }

    // ─── Immutables ───────────────────────────────────────────────────────────

    function test_ImmutablesSetCorrectly() public view {
        assertEq(address(executor.reactor()),    reactor);
        assertEq(address(executor.swapRouter()), address(mockRouter));
        assertEq(executor.owner(),               address(this));
    }

    // ─── Fuzz ─────────────────────────────────────────────────────────────────

    function testFuzz_WithdrawERC20(uint256 amount) public {
        tokenOut.mint(address(executor), amount);
        address recipient = makeAddr("recipient");
        executor.withdrawERC20(ERC20(address(tokenOut)), recipient);
        assertEq(tokenOut.balanceOf(recipient), amount);
        assertEq(tokenOut.balanceOf(address(executor)), 0);
    }

    /// Inventory fill should work for any output amount as long as balance covers it.
    function testFuzz_InventoryFill(uint128 outputAmount) public {
        vm.assume(outputAmount > 0);

        tokenOut.mint(address(executor), outputAmount);
        tokenIn.mint(address(executor), uint256(outputAmount) * 2);

        ResolvedOrder[] memory orders = _singleOrder(uint256(outputAmount) * 2, outputAmount);

        vm.prank(reactor);
        executor.reactorCallback(orders, _callbackData(""));

        assertEq(tokenOut.allowance(address(executor), reactor), outputAmount);
        // Router untouched
        assertEq(tokenIn.allowance(address(executor), address(mockRouter)), 0);
    }
}
