use dotenvy::dotenv;
use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub rpc_url: String,
    pub private_key: String,
    pub executor_address: String,
    /// V3 pool fee tier: 500 (0.05%), 3000 (0.3%), or 10000 (1%)
    pub pool_fee: u32,
    /// Minimum profit in wei before submitting a fill
    pub min_profit_wei: u128,
}

impl Config {
    pub fn load() -> Self {
        dotenv().ok();

        Self {
            rpc_url: env::var("RPC_URL").expect("RPC_URL not set"),
            private_key: env::var("PRIVATE_KEY").expect("PRIVATE_KEY not set"),
            executor_address: env::var("EXECUTOR_ADDRESS").expect("EXECUTOR_ADDRESS not set"),
            pool_fee: env::var("POOL_FEE")
                .expect("POOL_FEE not set")
                .parse()
                .expect("POOL_FEE must be a number"),
            min_profit_wei: env::var("MIN_PROFIT_WEI")
                .expect("MIN_PROFIT_WEI not set")
                .parse()
                .expect("MIN_PROFIT_WEI must be a number"),
        }
    }
}
