use crate::types::{Order, OrdersResponse};
use anyhow::Result;
use reqwest::Client;
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::sync::mpsc::Sender;
use tokio::time::{Duration, interval};
use tracing::{debug, error, info, warn};

const UNISWAPX_API: &str = "https://api.uniswap.org/v2/orders";
const ARBITRUM_CHAIN_ID: u64 = 42161;
const POLL_INTERVAL_MS: u64 = 166;

pub async fn watch(tx: Sender<Order>) -> Result<()> {
    let client = Client::new();
    let mut ticker = interval(Duration::from_millis(POLL_INTERVAL_MS));
    let mut tick_count: u64 = 0;

    info!(
        interval_ms = POLL_INTERVAL_MS,
        chain_id = ARBITRUM_CHAIN_ID,
        "watcher started"
    );

    loop {
        ticker.tick().await;
        tick_count += 1;

        debug!(tick = tick_count, "polling UniswapX API");

        match fetch_orders(&client).await {
            Ok(orders) => {
                let total = orders.len();
                let now = SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_secs();

                info!(tick = tick_count, fetched = total, "orders fetched");

                let mut sent = 0;
                let mut expired = 0;

                for order in orders {
                    let time_left = order.deadline.saturating_sub(now);

                    if order.deadline < now {
                        expired += 1;
                        debug!(
                            hash = %order.order_hash,
                            "skipping expired order"
                        );
                        continue;
                    }

                    debug!(
                        hash = %order.order_hash,
                        input_token = %order.input.token,
                        output_token = %order.outputs[0].token,
                        deadline_in = time_left,
                        "queueing order for evaluation"
                    );

                    if tx.send(order).await.is_err() {
                        info!("evaluation channel closed, watcher shutting down");
                        return Ok(());
                    }

                    sent += 1;
                }

                if expired > 0 || sent > 0 {
                    info!(
                        tick = tick_count,
                        fetched = total,
                        queued = sent,
                        expired = expired,
                        "tick summary"
                    );
                }
            }
            Err(e) => error!(tick = tick_count, "API fetch failed: {e}"),
        }
    }
}

async fn fetch_orders(client: &Client) -> Result<Vec<Order>> {
    let chain_id = ARBITRUM_CHAIN_ID.to_string();

    let request = client.get(UNISWAPX_API).query(&[
        ("orderStatus", "open"),
        ("chainId", chain_id.as_str()),
        ("limit", "1"),
    ]);

    debug!("request url: {:?}", request);

    let raw = request.send().await?.error_for_status()?.text().await?;

    debug!("raw API response: {raw}");

    let parsed: OrdersResponse = serde_json::from_str(&raw)?;

    Ok(parsed.orders)
}
