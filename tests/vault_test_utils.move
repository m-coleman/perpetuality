module perp::vault_test_utils {

    use perp::market_manager::{Self, Market};
    use sui::test_utils;

    public fun assert_vault_balance<B, Q>(market: &Market<B, Q>, expected_balance: u64) {
        let vault = market_manager::get_vault<B, Q>(market);
        test_utils::assert_eq(market_manager::get_vault_funds<Q>(vault), expected_balance);
    }

    public fun assert_vault_fees_outstanding<B, Q>(market: &Market<B, Q>, expected_fees_outstanding: u64) {
        let vault = market_manager::get_vault<B, Q>(market);
        test_utils::assert_eq(market_manager::get_vault_fees_outstanding<Q>(vault), expected_fees_outstanding);
    }

}
