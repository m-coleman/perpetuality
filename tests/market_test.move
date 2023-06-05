#[test_only]
module perp::market_tests {

    use std::string;
    //use std::debug;
    use sui::bag;
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::test_utils;
    use sui::test_scenario::{Self, Scenario};

    use perp::market_manager::{Self, OwnerCap, GlobalMarkets};
    use perp::market;
    use perp::market_test_utils;
    use perp::vault_test_utils;

    const ONE_UNIT: u64 = 1_000_000_000;
    const ONE_HOUR_MS: u64 = 60 * 60 * 1000;
    const OWNER: address = @0xcafe;
    const STAKER: address = @0x51ace; // need a staker so users can open positions
    const TRADER_1: address = @0xdead;
    const TRADER_2: address = @0xbeef;
    const TRADER_3: address = @0xbabe;
    const DEFAULT_STAKE_AMOUNT: u64 = 100 * 1_000_000_000; // $100 initial USDC
    const DEFAULT_PRICE_IMPACT_DELTA: u64 = 1_000_000_000 / 10; // .1%

    struct ETH has store {}
    struct USDC has store {}

    #[test]
    fun test_add_margin() {
        let scenario = test_scenario::begin(OWNER);
        let scenario_mut = &mut scenario;
        let (oc, gm, clock) = init_modules(scenario_mut);

        test_scenario::next_tx(scenario_mut, OWNER);
        create_market_and_stake<ETH, USDC>(&oc, &mut gm, scenario_mut, &clock);

        // add margin as a Trader
        test_scenario::next_tx(scenario_mut, TRADER_1);
        let ctx = test_scenario::ctx(scenario_mut);
        let margin_value = 100 * ONE_UNIT;
        let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
        market::modify_position<ETH, USDC>(0, true, 0, trader_margin, &mut gm, &clock, ctx);
        market_test_utils::assert_market_debt<ETH, USDC>(&gm, &clock, margin_value); // market debt should be $100

        test_scenario::next_tx(scenario_mut, TRADER_1);
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let (pos_lfi, pos_margin, _, pos_size, pos_direction) = market_manager::get_position_data<ETH, USDC>(market, TRADER_1);
        test_utils::assert_eq(pos_lfi, 1);
        test_utils::assert_eq(pos_margin, margin_value);
        test_utils::assert_eq(pos_size, 0);
        test_utils::assert_eq(pos_direction, true);

        end_scenario(scenario, oc, gm, clock);
    }

    #[test]
    fun test_modify_position() {
        let scenario = test_scenario::begin(OWNER);
        let scenario_mut = &mut scenario;
        let (oc, gm, clock) = init_modules(scenario_mut);

        test_scenario::next_tx(scenario_mut, OWNER);
        create_market_and_stake<ETH, USDC>(&oc, &mut gm, scenario_mut, &clock);

        let trader1_margin;
        let trader1_expected_fee;
        {
            // trader_1 opens 1 ETH long position with $100 margin with price at $2000
            trader1_margin = 100 * ONE_UNIT;
            market_test_utils::open_position<ETH, USDC>(
                TRADER_1,
                ONE_UNIT, // size
                true, // direction
                DEFAULT_PRICE_IMPACT_DELTA,
                trader1_margin, // margin
                scenario_mut,
                &mut gm,
                &clock
            );

            // this trade is increasing the skew, so the taker fee is charged
            // expected margin = initial margin - order_fee
            // = $100 - (size * fill_price * taker_fee)
            // = $100 - (1 * $2001 * .75%)
            // = $100 - $15.0075
            // = $84.9925
            trader1_expected_fee = 15007500000; // expected fee is ~$15
            test_scenario::next_tx(scenario_mut, TRADER_1);
            let market = market_manager::get_market<ETH, USDC>(&gm);
            market_test_utils::assert_position<ETH, USDC>(
                market,
                TRADER_1,
                1, // last funding index was 1
                trader1_margin - trader1_expected_fee, // trader_1 has ~$85 margin remaining
                2000 * ONE_UNIT, // last price was $2000
                ONE_UNIT, // size is 1 ETH
                true // direction is long
            );
            market_test_utils::assert_market_size<ETH, USDC>(market, ONE_UNIT); // market size is 1
            market_test_utils::assert_market_skew<ETH, USDC>(market, ONE_UNIT, true); // skew is 1 ETH long
            market_test_utils::assert_market_sizes<ETH, USDC>(market, ONE_UNIT, 0); // 1 ETH long, 0 ETH short
            market_test_utils::assert_last_funding_entry<ETH, USDC>(market, 0, true); // no funding yet
            market_test_utils::assert_market_debt<ETH, USDC>(&gm, &clock, trader1_margin - trader1_expected_fee); // market debt is trader1's current margin
            vault_test_utils::assert_vault_balance<ETH, USDC>(market, 200 * ONE_UNIT); // vault has $200 ($100 margin + $100 staked)
            vault_test_utils::assert_vault_fees_outstanding<ETH, USDC>(market, trader1_expected_fee); // ~$15 of fees should be in the vault
        };

        let trader2_expected_fee;
        {
            // trader_2 opens 1 ETH short position with $100 margin with price at $2000
            let trader2_margin = 100 * ONE_UNIT;
            market_test_utils::open_position<ETH, USDC>(
                TRADER_2,
                ONE_UNIT, // size
                false, // direction
                DEFAULT_PRICE_IMPACT_DELTA,
                trader2_margin, // margin
                scenario_mut,
                &mut gm,
                &clock
            );

            test_scenario::next_tx(scenario_mut, TRADER_2);
            let market = market_manager::get_market<ETH, USDC>(&gm);
            // this trade is reducing the skew, so the maker fee is charged
            // expected margin = initial margin - order_fee
            // = $100 - (size * fill_price * maker_fee)
            // = $100 - (1 * $2001 * .50%)
            // = $100 - $10.005
            // = $89.995
            trader2_expected_fee = 10005000000;
            market_test_utils::assert_position<ETH, USDC>(
                market,
                TRADER_2,
                2, // last funding index was 2
                trader2_margin - trader2_expected_fee, // trader_2 has $90 margin remaining
                2000 * ONE_UNIT, // last price was $2000
                ONE_UNIT, // size is 1 ETH
                false // direction is short
            );
            market_test_utils::assert_market_size<ETH, USDC>(market, 2 * ONE_UNIT); // market size is now 2
            market_test_utils::assert_market_skew<ETH, USDC>(market, 0, true); // skew is back to 0
            market_test_utils::assert_market_sizes<ETH, USDC>(market, ONE_UNIT, ONE_UNIT); // 1 long, 1 short
            market_test_utils::assert_last_funding_entry<ETH, USDC>(market, 0, true); // no funding, didn't increment the clock
            market_test_utils::assert_market_debt<ETH, USDC>(&gm, &clock,
                (trader1_margin - trader1_expected_fee) + (trader2_margin - trader2_expected_fee) // market debt is trader1's current margin + trader2's current margin
            );
            vault_test_utils::assert_vault_balance<ETH, USDC>(market, 300 * ONE_UNIT); // vault has $300 ($200 margin + $100 staked)
            vault_test_utils::assert_vault_fees_outstanding<ETH, USDC>(market, trader1_expected_fee + trader2_expected_fee); // both traders' fees should be in the vault
        };

        {
            // trader_1 closes the position
            test_scenario::next_tx(scenario_mut, TRADER_1);
            let ctx = test_scenario::ctx(scenario_mut);

            // closing the position is increasing the skew (it was 0), so the taker fee is charged
            // expected margin = curr margin - order_fee
            // = $84.9925 - (size * fill_price * taker_fee)
            // = $84.9925 - (1 * $2001 * .75%)
            // = $84.9925 - $15.0075
            // = $69.9850
            let trader1_close_fee = 15007500000; // expected fee is ~$15
            let trader1_expected_margin = trader1_margin - trader1_expected_fee - trader1_close_fee;

            market::close_position<ETH, USDC>(DEFAULT_PRICE_IMPACT_DELTA, &mut gm, &clock, ctx);

            test_scenario::next_tx(scenario_mut, TRADER_1);
            let market = market_manager::get_market<ETH, USDC>(&gm);
            market_test_utils::assert_position<ETH, USDC>(
                market,
                TRADER_1,
                4, // last funding index was 4 (closing a position calculates funding twice b/c it calls withdraw_all_margin)
                0, // closing the position withdraws all margin ($70)
                2000 * ONE_UNIT, // last price was $2000
                0, // size is 0 ETH
                true // direction doesn't matter
            );

            market_test_utils::assert_market_size<ETH, USDC>(market, 1 * ONE_UNIT); // market size is now 1
            market_test_utils::assert_market_skew<ETH, USDC>(market, 1 * ONE_UNIT, false); // skew is now 1 ETH short
            market_test_utils::assert_market_sizes<ETH, USDC>(market, 0, ONE_UNIT); // 0 long, 1 short
            market_test_utils::assert_last_funding_entry<ETH, USDC>(market, 0, true); // no funding, didn't increment the clock
            // vault previously had $300, and trader_1 just withdrew ~$70
            vault_test_utils::assert_vault_balance<ETH, USDC>(market, 300 * ONE_UNIT - trader1_expected_margin);
            // another $15 of fees were generated (prev fees were ~$25, so expect ~$40 now)
            vault_test_utils::assert_vault_fees_outstanding<ETH, USDC>(market, trader1_expected_fee + trader2_expected_fee + trader1_close_fee);

            // verify trader_1 now has $70 coin in their inventory
            let c = test_scenario::take_from_address<Coin<USDC>>(scenario_mut, TRADER_1);
            let trader_1_coin_value = coin::value<USDC>(&c);
            test_utils::assert_eq(trader_1_coin_value, trader1_expected_margin);
            test_scenario::return_to_sender<Coin<USDC>>(scenario_mut, c);
        };

        end_scenario(scenario, oc, gm, clock);
    }

    #[test]
    fun test_funding() {
        // let scenario = test_scenario::begin(OWNER);
        // let scenario_mut = &mut scenario;
        // let (oc, gm, clock) = init_modules(scenario_mut);

        // test_scenario::next_tx(scenario_mut, OWNER);
        // create_market_and_stake<ETH, USDC>(&oc, &mut gm, scenario_mut, &clock);

        // market_manager::set_oracle_price_test<ETH, USDC>(100 * ONE_UNIT, &mut gm);

        // clock::increment_for_testing(&mut clock, 1000 * 1000);
        // market_test_utils::open_position<ETH, USDC>(
        //     TRADER_1,
        //     100 * ONE_UNIT, // size
        //     true, // direction
        //     DEFAULT_PRICE_IMPACT_DELTA,
        //     1000000 * ONE_UNIT, // margin
        //     scenario_mut,
        //     &mut gm,
        //     &clock
        // );

        // {
        //     let market = market_manager::get_market<ETH, USDC>(&gm);
        //     market_test_utils::assert_last_funding_entry(market, 0, true);
        // };

        // clock::increment_for_testing(&mut clock, 29000 * 1000);
        // market_test_utils::open_position<ETH, USDC>(
        //     TRADER_2,
        //     200 * ONE_UNIT, // size
        //     true, // direction
        //     DEFAULT_PRICE_IMPACT_DELTA,
        //     1000000 * ONE_UNIT, // margin
        //     scenario_mut,
        //     &mut gm,
        //     &clock
        // );

        // {
        //     let market = market_manager::get_market<ETH, USDC>(&gm);
        //     market_test_utils::assert_last_funding_entry(market, 0, true);
        // };

        // clock::increment_for_testing(&mut clock, 20000 * 1000);
        // market_test_utils::open_position<ETH, USDC>(
        //     TRADER_3,
        //     300 * ONE_UNIT, // size
        //     false, // direction
        //     DEFAULT_PRICE_IMPACT_DELTA,
        //     1000000 * ONE_UNIT, // margin
        //     scenario_mut,
        //     &mut gm,
        //     &clock
        // );

        // {
        //     let market = market_manager::get_market<ETH, USDC>(&gm);
        //     market_test_utils::assert_last_funding_entry(market, 0, true);
        // };

        // end_scenario(scenario, oc, gm, clock);
    }

    #[test]
    #[expected_failure(abort_code = market_manager::EMarketDoesNotExist)]
    fun test_get_nonexistent_market() {
        let scenario = test_scenario::begin(OWNER);
        let scenario_mut = &mut scenario;
        let (oc, gm, clock) = init_modules(scenario_mut);
        test_scenario::next_tx(scenario_mut, OWNER);
        // this should fail, market does not exist
        market_manager::get_market<ETH, USDC>(&gm);
        end_scenario(scenario, oc, gm, clock);
    }

    #[test]
    #[expected_failure(abort_code = market_manager::EMarketDoesNotExist)]
    fun test_modify_position_nonexistent_market() {
        let scenario = test_scenario::begin(OWNER);
        let scenario_mut = &mut scenario;
        let (oc, gm, clock) = init_modules(scenario_mut);

        test_scenario::next_tx(scenario_mut, TRADER_1);
        let ctx = test_scenario::ctx(scenario_mut);
        let margin_value = 100 * ONE_UNIT;
        let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
        // this should fail, market does not exist
        market::modify_position<ETH, USDC>(0, true, 0, trader_margin, &mut gm, &clock, ctx);
        end_scenario(scenario, oc, gm, clock);
    }

    #[test]
    #[expected_failure(abort_code = market_manager::EMarketAlreadyExists)]
    fun test_cannot_add_duplicate_market() {
        let scenario = test_scenario::begin(OWNER);
        let scenario_mut = &mut scenario;
        let (oc, gm, clock) = init_modules(scenario_mut);

        test_scenario::next_tx(scenario_mut, OWNER);
        let ctx = test_scenario::ctx(scenario_mut);
        market_manager::add_market<ETH, USDC>(&oc, &mut gm, ctx);
        // this should fail, cannot add another market with the same type
        market_manager::add_market<ETH, USDC>(&oc, &mut gm, ctx);
        end_scenario(scenario, oc, gm, clock);
    }

    #[test]
    fun test_add_market() {
        let scenario = test_scenario::begin(OWNER);
        let scenario_mut = &mut scenario;
        let (oc, gm, clock) = init_modules(scenario_mut);

        test_scenario::next_tx(scenario_mut, OWNER);
        let ctx = test_scenario::ctx(scenario_mut);
        market_manager::add_market<ETH, USDC>(&oc, &mut gm, ctx);
        let market_name = market_manager::get_market_name<ETH, USDC>();
        let expected_market_name = string::utf8(
            b"0000000000000000000000000000000000000000000000000000000000000000::market_tests::ETH-0000000000000000000000000000000000000000000000000000000000000000::market_tests::USDC"
        );
        test_utils::assert_eq(market_name, expected_market_name);
        let markets = market_manager::get_markets(&gm);
        let num_markets = bag::length(markets);
        test_utils::assert_eq(num_markets, 1);
        // set the market parameters
        let min_keeper_fee = 1;
        let max_keeper_fee = 2;
        let liquidation_fee_ratio = 3;
        let liquidation_buffer_ratio = 4;
        let min_initial_margin = 5;
        let taker_fee = 6;
        let maker_fee = 7;
        let max_leverage = 8;
        let max_market_value = 9;
        let max_funding_velocity = 10;
        let skew_scale = 11;
        let liquidation_premium_multiplier = 12;
        market_manager::set_market_parameters<ETH, USDC>(&oc, &mut gm, min_keeper_fee, max_keeper_fee, liquidation_fee_ratio, liquidation_buffer_ratio,
            min_initial_margin, taker_fee, maker_fee, max_leverage, max_market_value, max_funding_velocity, skew_scale, liquidation_premium_multiplier);
        // make sure market parameters were set correctly
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let (mnkf, mxkf, lfr, lbr, mim, tf, mf, ml, mmv, mfv, ss, lpm) = market_manager::market_parameters<ETH, USDC>(market);
        test_utils::assert_eq(min_keeper_fee, mnkf);
        test_utils::assert_eq(max_keeper_fee, mxkf);
        test_utils::assert_eq(liquidation_fee_ratio, lfr);
        test_utils::assert_eq(liquidation_buffer_ratio, lbr);
        test_utils::assert_eq(min_initial_margin, mim);
        test_utils::assert_eq(taker_fee, tf);
        test_utils::assert_eq(maker_fee, mf);
        test_utils::assert_eq(max_leverage, ml);
        test_utils::assert_eq(max_market_value, mmv);
        test_utils::assert_eq(max_funding_velocity, mfv);
        test_utils::assert_eq(skew_scale, ss);
        test_utils::assert_eq(liquidation_premium_multiplier, lpm);

        let (pos_lfi, pos_margin, pos_last_price, pos_size, pos_direction) = market_manager::get_position_data<ETH, USDC>(market, TRADER_1);
        test_utils::assert_eq(pos_lfi, 0);
        test_utils::assert_eq(pos_margin, 0);
        test_utils::assert_eq(pos_last_price, 0);
        test_utils::assert_eq(pos_size, 0);
        test_utils::assert_eq(pos_direction, true);
        market_test_utils::assert_market_size<ETH, USDC>(market, 0);
        market_test_utils::assert_market_sizes<ETH, USDC>(market, 0, 0);
        market_test_utils::assert_market_skew<ETH, USDC>(market, 0, true);
        market_test_utils::assert_last_funding_entry<ETH, USDC>(market, 0, true);
        market_test_utils::assert_market_debt<ETH, USDC>(&gm, &clock, 0); // no market debt yet
        vault_test_utils::assert_vault_balance<ETH, USDC>(market, 0); // no funds in vault
        vault_test_utils::assert_vault_fees_outstanding<ETH, USDC>(market, 0); // no fees in the vault yet
        end_scenario(scenario, oc, gm, clock);
    }

    fun create_market_and_stake<B, Q>(oc: &OwnerCap, gm: &mut GlobalMarkets, scenario: &mut Scenario, clock: &Clock) {
        create_market<B, Q>(oc, gm, scenario);
        vault_test_utils::stake<B, Q>(STAKER, DEFAULT_STAKE_AMOUNT, scenario, gm, clock);
    }

    fun create_market<B, Q>(oc: &OwnerCap, gm: &mut GlobalMarkets, scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, OWNER);
        let ctx = test_scenario::ctx(scenario);
        market_manager::add_market<B, Q>(oc, gm, ctx);
        // set the market parameters
        market_manager::set_market_parameters<B, Q>(oc, gm,
            2 * ONE_UNIT, //min_keeper_fee (2)
            1000 * ONE_UNIT, //max_keeper_fee (1000)
            3500000, // liquidation_fee_ratio (.0035)
            10000000, // liquidation_buffer_ratio (.01)
            40 * ONE_UNIT, // min_initial_margin (40)
            7500000, // taker_fee (.0075)
            5000000, // maker_fee (.0050)
            100 * ONE_UNIT, // max_leverage (100)
            10_000 * ONE_UNIT, // max_market_value (10,000)
            ONE_UNIT / 4, // max_funding_velocity (.25)
            1000 * ONE_UNIT, // skew_scale (1,000)
            100000000, // liquidation_premium_multiplier (.10)
        );
        market_manager::set_can_user_stake<B, Q>(oc, gm, true);
    }

    fun init_modules(scenario: &mut Scenario): (OwnerCap, GlobalMarkets, Clock) {
        let ctx = test_scenario::ctx(scenario);
        market_manager::test_init(ctx);
        test_scenario::next_tx(scenario, OWNER);
        let oc = test_scenario::take_from_sender<OwnerCap>(scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(scenario);
        let ctx = test_scenario::ctx(scenario);
        let clock = clock::create_for_testing(ctx);
        (oc, gm, clock)
    }

    fun end_scenario(scenario: Scenario, oc: OwnerCap, gm: GlobalMarkets, clock: Clock) {
        test_scenario::next_tx(&mut scenario, OWNER);
        test_scenario::return_to_sender<OwnerCap>(&mut scenario, oc);
        test_scenario::return_shared<GlobalMarkets>(gm);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario);
    }

}
