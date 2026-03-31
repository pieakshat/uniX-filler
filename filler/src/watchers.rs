use crate::types::{Order, OrdersResponse};
use anyhow::Result;
use reqwest::Client;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc::Sender;
use tokio::time::{interval, Duration};
use tracing::{error, info, warn};

const UNISWAPX_API: &str = "https://api.uniswap.org/v2/orders";
const ARBITRUM_CHAIN_ID: u64 = 42161;
const POLL_INTERVAL_MS: u64 = 166;

pub async fn watch(tx: Sender<Order>) -> Result<()> {
    let client = Client::new();
    let mut ticker = interval(Duration::from_millis(POLL_INTERVAL_MS));

    loop {
        ticker.tick().await;

        match fetch_orders(&client).await {
            Ok(orders) => {
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_secs();

                for order in orders {
                    if order.deadline < now {
                        warn!(hash = %order.order_hash, "skipping expired order");
                        continue;
                    }

                    info!(hash = %order.order_hash, "sending order to engine");

                    if tx.send(order).await.is_err() {
                        return Ok(());
                    }
                }
            }
            Err(e) => error!("fetch failed {e}"),
        }
    }
}

async fn fetch_orders(client: &Client) -> Result<Vec<Order>> {
    let response = client
        .get(UNISWAPX_API)
        .query(&[
            ("orderStatus", "open"),
            ("chainId", &ARBITRUM_CHAIN_ID.to_string()),
            ("limit", "50"),
            ("orderType", "Dutch_V3"),
        ])
        .send()
        .await?
        .error_for_status()?
        .json::<OrdersResponse>()
        .await?;

    Ok(response.orders)
}
