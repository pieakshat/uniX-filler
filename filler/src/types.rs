use serde::{Deserialize, Serialize};

/// Top-level response from GET /v2/orders
#[derive(Debug, Deserialize)]
pub struct OrdersResponse {
    pub orders: Vec<Order>,
    /// Pagination cursor — pass as `?cursor=` in the next request
    pub cursor: Option<String>,
}

/// A single UniswapX order as returned by the API
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Order {
    /// Always "Dutch" for DutchV3 orders
    #[serde(rename = "type")]
    pub order_type: String,

    /// ABI-encoded order bytes (hex string). Decoded and passed directly to the reactor.
    pub encoded_order: String,

    /// Swapper's EIP-712 signature over the order
    pub signature: String,

    pub nonce: String,
    pub order_hash: String,
    pub order_status: OrderStatus,
    pub chain_id: u64,

    /// Address of the swapper who created the order
    pub swapper: String,

    /// Address of the reactor contract this order targets
    pub reactor: String,

    /// Unix timestamp when Dutch decay begins (V1/V2) or block number (V3)
    pub decay_start_time: u64,

    /// Unix timestamp / block when decay ends and price becomes static
    pub decay_end_time: u64,

    /// Unix timestamp after which the order is invalid
    pub deadline: u64,

    pub input: OrderInput,
    pub outputs: Vec<OrderOutput>,

    // Fields populated after a fill — None on open orders
    pub filler: Option<String>,
    pub quote_id: Option<String>,
    pub tx_hash: Option<String>,
    pub fill_block: Option<u64>,
    pub settled_amounts: Option<Vec<SettledAmount>>,
}

#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum OrderStatus {
    #[serde(rename = "open")]
    Open,
    #[serde(rename = "expired")]
    Expired,
    #[serde(rename = "filled")]
    Filled,
    #[serde(rename = "cancelled")]
    Cancelled,
    #[serde(rename = "error")]
    Error,
    #[serde(rename = "insufficient-funds")]
    InsufficientFunds,
}

/// The token the swapper is selling (input to the reactor)
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderInput {
    /// ERC20 token address
    pub token: String,
    /// Amount at decay start (as decimal string)
    pub start_amount: String,
    /// Amount at decay end (as decimal string)
    pub end_amount: String,
}

/// A token the filler must deliver
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OrderOutput {
    /// ERC20 token address
    pub token: String,
    /// Amount at decay start (as decimal string)
    pub start_amount: String,
    /// Amount at decay end (as decimal string)
    pub end_amount: String,
    /// Address that must receive this output
    pub recipient: String,
}

/// Populated by the API once an order is filled
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SettledAmount {
    pub token_out: String,
    pub amount_out: String,
    pub token_in: String,
    pub amount_in: String,
}
