mod config;
mod engine;
mod executor;
mod types;
mod watchers;

use crate::config::Config;
use crate::types::Order;
use alloy::providers::ProviderBuilder;
use std::collections::HashSet;
use tokio::sync::mpsc;
use tracing::{debug, error, info, warn};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| tracing_subscriber::EnvFilter::new("info")),
        )
        .init();

    let config = Config::load();

    info!(
        executor  = %config.executor_address,
        pool_fee  = config.pool_fee,
        min_profit_wei = config.min_profit_wei,
        "filler starting"
    );

    let provider = ProviderBuilder::new().on_http(config.rpc_url.parse()?);

    let (tx, mut rx) = mpsc::channel::<Order>(256);

    tokio::spawn(async move {
        if let Err(e) = watchers::watch(tx).await {
            error!("watcher exited unexpectedly: {e}");
        }
    });

    let mut seen: HashSet<String> = HashSet::new();

    info!("evaluation loop ready — waiting for orders");

    while let Some(order) = rx.recv().await {
        if !seen.insert(order.order_hash.clone()) {
            debug!(hash = %order.order_hash, "already seen, skipping");
            continue;
        }

        info!(
            hash  = %order.order_hash,
            input = %order.input.token,
            output = %order.outputs[0].token,
            deadline = order.deadline,
            "new order received"
        );

        let config = config.clone();
        let provider = provider.clone();

        tokio::spawn(async move {
            match engine::evaluate(&order, &config, &provider).await {
                Ok(Some(intent)) => {
                    info!(hash = %order.order_hash, "profitable — submitting fill");
                    if let Err(e) = executor::fill(intent, &config).await {
                        error!(hash = %order.order_hash, "fill failed: {e}");
                    }
                }
                Ok(None) => {
                    info!(hash = %order.order_hash, "not profitable, skipping");
                }
                Err(e) => {
                    warn!(hash = %order.order_hash, "evaluation error: {e}");
                }
            }
        });
    }

    Ok(())
}
