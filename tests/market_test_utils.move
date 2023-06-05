module perp::market_test_utils {

    use sui::clock::{Clock};
    use sui::coin;
    use sui::test_scenario::{Self, Scenario};
    use sui::test_utils;
    use perp::market_manager::{Self, Market, GlobalMarkets};
    use perp::market_views;
    use perp::market;
    use perp::utils;

    const ONE_UNIT: u64 = 1_000_000_000;

    public fun assert_position<B, Q>(
        market: &Market<B, Q>,
        msg_sender: address,
        expected_pos_lfi: u64,
        expected_pos_margin: u64,
        _expected_pos_last_price: u64,
        expected_pos_size: u64,
        expected_pos_direction: bool
    ) {
        let (pos_lfi, pos_margin, _pos_last_price, pos_size, pos_direction) = market_manager::get_position_data<B, Q>(market, msg_sender);
        test_utils::assert_eq(pos_lfi, expected_pos_lfi);
        test_utils::assert_eq(pos_margin, expected_pos_margin);
        // TODO: test_utils::assert_eq(pos_last_price, expected_pos_last_price); // TODO: need to take into account fill price not oracle price
        test_utils::assert_eq(pos_size, expected_pos_size);
        test_utils::assert_eq(pos_direction, expected_pos_direction);
    }

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

    public fun assert_market_debt<B, Q>(gm: &GlobalMarkets, clock: &Clock, expected_market_debt: u64) {
        let market_debt = market_views::market_debt<B, Q>(gm, clock);
        test_utils::assert_eq(market_debt, expected_market_debt);
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

    public fun open_position<B, Q>(
        trader: address,
        size: u64,
        direction: bool,
        price_impact_delta: u64,
        margin: u64,
        scenario: &mut Scenario,
        gm: &mut GlobalMarkets,
        clock: &Clock
    ) {
        test_scenario::next_tx(scenario, trader);
        let ctx = test_scenario::ctx(scenario);

        let trader_margin = coin::mint_for_testing<Q>(margin, ctx);
        market::modify_position<B, Q>(size, direction, price_impact_delta, trader_margin, gm, clock, ctx);
    }

    public fun set_oracle_price<B, Q>(
        price: u64,
        gm: &mut GlobalMarkets
    ) {
        market_manager::set_oracle_price_test<B, Q>(price, gm);
    }

    public fun assert_close(actual: u64, expected: u64) {
        let variance: u64 = ONE_UNIT / 100; // .01
        let lower_bound = utils::sub(expected, variance);
        if (actual < lower_bound) {
            print(b"assert_close failed. Actual is less than lower bound");
            std::debug::print(&actual);
            print(b"actual (above) is less than lower bound (below)");
            std::debug::print(&lower_bound);
            abort(0)
        };

        let upper_bound = expected + variance;
        if (actual > upper_bound) {
            print(b"assert_close failed. Actual is greater than upper bound");
            std::debug::print(&actual);
            print(b"actual (above) is greater than upper bound (below)");
            std::debug::print(&upper_bound);
            abort(0)
        };
    }

    public fun print(str: vector<u8>) {
        std::debug::print(&std::ascii::string(str))
    }
}
