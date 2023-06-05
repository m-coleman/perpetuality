module perp::vault_test_utils {

    use sui::test_scenario::{Self, Scenario};
    use sui::test_utils;
    use sui::coin;
    use sui::clock::{Clock};
    use perp::market_manager::{Self, GlobalMarkets, Market};
    use perp::vault;

    public fun assert_vault_balance<B, Q>(market: &Market<B, Q>, expected_balance: u64) {
        let vault = market_manager::get_vault<B, Q>(market);
        test_utils::assert_eq(market_manager::get_vault_funds<Q>(vault), expected_balance);
    }

    public fun assert_vault_fees_outstanding<B, Q>(market: &Market<B, Q>, expected_fees_outstanding: u64) {
        let vault = market_manager::get_vault<B, Q>(market);
        test_utils::assert_eq(market_manager::get_vault_fees_outstanding<Q>(vault), expected_fees_outstanding);
    }

    public fun stake<B, Q>(
        staker: address,
        amount: u64,
        scenario: &mut Scenario,
        gm: &mut GlobalMarkets,
        clock: &Clock
    ) {
        test_scenario::next_tx(scenario, staker);
        let ctx = test_scenario::ctx(scenario);
        let coin = coin::mint_for_testing<Q>(amount, ctx);
        vault::stake<B, Q>(gm, coin, clock, ctx);   
    }

}
