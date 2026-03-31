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
use tracing::{error, info, warn};

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt::init();

    let config = Config::load();
    info!("starting filler — executor: {}", config.executor_address);

    let provider = ProviderBuilder::new().on_http(config.rpc_url.parse()?);

    // Channel between watcher and evaluator — bounded to avoid unbounded buffering
    let (tx, mut rx) = mpsc::channel::<Order>(256);

    // Spawn the order watcher as an independent task
    tokio::spawn(async move {
        if let Err(e) = watchers::watch(tx).await {
            error!("watcher exited: {e}");
        }
    });

    // Seen order hashes — prevents the same order being evaluated multiple times
    // across consecutive 166ms polling ticks
    let mut seen: HashSet<String> = HashSet::new();

    // Main evaluation loop
    while let Some(order) = rx.recv().await {
        if !seen.insert(order.order_hash.clone()) {
            continue;
        }

        let config = config.clone();
        let provider = provider.clone();

        tokio::spawn(async move {
            match engine::evaluate(&order, &config, &provider).await {
                Ok(Some(intent)) => {
                    info!(hash = %order.order_hash, "order is profitable, filling");
                    if let Err(e) = executor::fill(intent, &config).await {
                        error!(hash = %order.order_hash, "fill failed: {e}");
                    }
                }
                Ok(None) => {
                    // Not profitable — nothing to do
                }
                Err(e) => {
                    warn!(hash = %order.order_hash, "evaluation error: {e}");
                }
            }
        });
    }

    Ok(())
}
