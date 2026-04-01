use crate::config::Config;
use crate::types::Order;
use alloy::primitives::{aliases::U24, Address, Uint, U256};
use alloy::providers::Provider;
use anyhow::Result;
use std::str::FromStr;
use tracing::{debug, info, warn};

alloy::sol! {
    #[sol(rpc)]
    interface IQuoterV2 {
        function quoteExactInputSingle(
            address tokenIn,
            address tokenOut,
            uint256 amountIn,
            uint24 fee,
            uint160 sqrtPriceLimitX96
        ) external returns (
            uint256 amountOut,
            uint160 sqrtPriceX96After,
            uint32 initializedTicksCrossed,
            uint256 gasEstimate
        );
    }
}

const QUOTER_V2: &str = "0x61fFE014bA17989E743c5F6cB21bF9697530B21e";

/// Passed to the executor when an order is worth filling.
pub struct FillIntent {
    pub order: Order,
    /// abi.encodePacked(tokenIn, fee_as_3_bytes, tokenOut) — V3 swap path
    pub swap_path: Vec<u8>,
    /// Resolved input amount (what we receive from the reactor)
    pub input_amount: U256,
    /// Resolved output amount (minimum we must deliver to the swapper)
    pub output_amount: U256,
}

/// Evaluates whether an order is profitable to fill.
///
/// Returns `Ok(Some(intent))` if the V3 quoted output exceeds the required output
/// by at least `config.min_profit_wei`. Returns `Ok(None)` otherwise.
pub async fn evaluate<P: Provider>(
    order: &Order,
    config: &Config,
    provider: &P,
) -> Result<Option<FillIntent>> {
    let token_in = Address::from_str(&order.input.token)?;
    let token_out = Address::from_str(&order.outputs[0].token)?;

    // Use end_amount as the resolved amount — conservative approximation.
    // Full nonlinear decay resolution against current block will replace this later.
    let input_amount = U256::from_str(&order.input.end_amount)?;
    let required_output = U256::from_str(&order.outputs[0].end_amount)?;

    info!(
        hash = %order.order_hash,
        token_in = %token_in,
        token_out = %token_out,
        input_amount = %input_amount,
        required_output = %required_output,
        "evaluating order"
    );

    // Query the V3 Quoter
    debug!(
        hash = %order.order_hash,
        pool_fee = config.pool_fee,
        "calling QuoterV2"
    );

    let quoted_output = match quote(provider, token_in, token_out, input_amount, config.pool_fee).await {
        Ok(amount) => amount,
        Err(e) => {
            warn!(hash = %order.order_hash, "quoter call failed: {e}");
            return Ok(None);
        }
    };

    let profit = quoted_output.saturating_sub(required_output);
    let min_profit = U256::from(config.min_profit_wei);

    info!(
        hash = %order.order_hash,
        quoted_output = %quoted_output,
        required_output = %required_output,
        profit = %profit,
        min_profit = %min_profit,
        profitable = %(profit >= min_profit),
        "quote result"
    );

    if profit < min_profit {
        debug!(hash = %order.order_hash, "insufficient profit, skipping");
        return Ok(None);
    }

    let swap_path = build_swap_path(token_in, config.pool_fee, token_out);

    info!(
        hash = %order.order_hash,
        profit = %profit,
        "order profitable — creating fill intent"
    );

    Ok(Some(FillIntent {
        order: order.clone(),
        swap_path,
        input_amount,
        output_amount: required_output,
    }))
}

/// Calls QuoterV2.quoteExactInputSingle on Arbitrum and returns the expected output amount.
async fn quote<P: Provider>(
    provider: &P,
    token_in: Address,
    token_out: Address,
    amount_in: U256,
    fee: u32,
) -> Result<U256> {
    let quoter = IQuoterV2::new(QUOTER_V2.parse::<Address>()?, provider);

    let result = quoter
        .quoteExactInputSingle(token_in, token_out, amount_in, U24::from(fee), Uint::ZERO)
        .call()
        .await?;

    Ok(result.amountOut)
}

/// Encodes a single-hop V3 swap path: abi.encodePacked(tokenIn, fee_as_3_bytes, tokenOut)
fn build_swap_path(token_in: Address, fee: u32, token_out: Address) -> Vec<u8> {
    let mut path = Vec::with_capacity(43); // 20 + 3 + 20 bytes
    path.extend_from_slice(token_in.as_slice());
    path.extend_from_slice(&fee.to_be_bytes()[1..]); // uint24 = 3 bytes (drop leading zero byte)
    path.extend_from_slice(token_out.as_slice());
    path
}
