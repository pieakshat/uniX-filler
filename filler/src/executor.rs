use crate::config::Config;
use crate::engine::FillIntent;
use alloy::hex;
use alloy::network::EthereumWallet;
use alloy::primitives::{Address, Bytes};
use alloy::providers::ProviderBuilder;
use alloy::signers::local::PrivateKeySigner;
use alloy::sol_types::SolValue;
use anyhow::Result;
use std::str::FromStr;
use tracing::info;

alloy::sol! {
    #[sol(rpc)]
    interface IFillerExecutor {
        struct SignedOrder {
            bytes order;
            bytes sig;
        }

        function execute(
            SignedOrder calldata order,
            bytes calldata callbackData
        ) external;
    }
}

/// Signs and submits a fill transaction for the given intent.
///
/// Builds `callbackData` as `abi.encode(bytes[] swapPaths)`, constructs the
/// `SignedOrder`, and calls `FillerExecutor.execute()` on-chain.
pub async fn fill(intent: FillIntent, config: &Config) -> Result<()> {
    // Build a signing provider from the configured private key
    let signer: PrivateKeySigner = config.private_key.parse()?;
    let wallet = EthereumWallet::from(signer);
    let provider = ProviderBuilder::new()
        .wallet(wallet)
        .on_http(config.rpc_url.parse()?);

    // Decode hex-encoded order bytes and signature from the API response
    let order_bytes = Bytes::from(hex::decode(
        intent.order.encoded_order.trim_start_matches("0x"),
    )?);
    let sig_bytes = Bytes::from(hex::decode(
        intent.order.signature.trim_start_matches("0x"),
    )?);

    // callbackData: abi.encode(bytes[] swapPaths) — one path, matches the single order
    let swap_paths: Vec<Bytes> = vec![Bytes::from(intent.swap_path)];
    let callback_data = Bytes::from(swap_paths.abi_encode());

    let executor_address = Address::from_str(&config.executor_address)?;
    let executor = IFillerExecutor::new(executor_address, &provider);

    let signed_order = IFillerExecutor::SignedOrder {
        order: order_bytes,
        sig: sig_bytes,
    };

    // Submit — with_recommended_fillers handles nonce, gas estimation, and chain ID
    let pending = executor
        .execute(signed_order, callback_data)
        .send()
        .await?;

    let tx_hash = *pending.tx_hash();
    info!(order = %intent.order.order_hash, tx = %tx_hash, "fill submitted");

    let receipt = pending.get_receipt().await?;
    info!(
        order = %intent.order.order_hash,
        tx = %tx_hash,
        block = ?receipt.block_number,
        status = ?receipt.status(),
        "fill confirmed"
    );

    Ok(())
}
