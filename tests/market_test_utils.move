module perp::market_test_utils {

    use perp::market_manager::{Self, Market};
    use sui::test_utils;

    public fun assert_market_skew<B, Q>(market: &Market<B, Q>, expected_skew: u64, expected_skew_direction: bool) {
        let (skew, skew_direction) = market_manager::market_skew<B, Q>(market);
        test_utils::assert_eq(skew, expected_skew);
        test_utils::assert_eq(skew_direction, expected_skew_direction);
    }

    public fun assert_market_size<B, Q>(market: &Market<B, Q>, expected_market_size: u64) {
        test_utils::assert_eq(market_manager::market_size<B, Q>(market), expected_market_size);
    }

    public fun assert_market_sizes<B, Q>(market: &Market<B, Q>, expected_long: u64, expected_short: u64) {
        let (long, short) = market_manager::market_sizes<B, Q>(market);
        test_utils::assert_eq(long, expected_long);
        test_utils::assert_eq(short, expected_short);
    }

    public fun assert_last_funding_entry<B, Q>(
        market: &Market<B, Q>,
        expected_funding: u64,
        expected_funding_direction: bool
    ) {
        let (last_funding, last_funding_direction) = market_manager::funding_rate_last_recomputed<B, Q>(market);
        test_utils::assert_eq(last_funding, expected_funding);
        test_utils::assert_eq(last_funding_direction, expected_funding_direction);
    }

}
