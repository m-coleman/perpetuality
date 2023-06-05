module perp::exchange_rates {

    use perp::market_manager::{Self, Market};

    public fun rate_and_valid<B, Q>(market: &Market<B, Q>): (u64, bool) {
        let rate = market_manager::oracle_price<B, Q>(market);
        (rate, true)
    }

    // returns rate, broken, valid
    public fun rate_with_safety_checks<B, Q>(market: &Market<B, Q>): (u64, bool, bool) {
        let rate = market_manager::oracle_price<B, Q>(market);
        (rate, false, true)
    }

}
