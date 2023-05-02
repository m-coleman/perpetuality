#[test_only]
module perp::market_tests {

    use std::string;
    use sui::bag;
    use sui::clock;
    use sui::coin;
    use sui::test_utils;
    use sui::test_scenario::{Self, Scenario};

    use perp::market_manager::{Self, OwnerCap, GlobalMarkets};
    use perp::market;
    use perp::market_test_utils;
    use perp::vault_test_utils;
    // use sui::coin;
    // use sui::sui::SUI;
    // use sui::table;

    const ONE_UNIT: u64 = 1_000_000_000;
    const ONE_HOUR_MS: u64 = 60 * 60 * 1000;
    const OWNER: address = @0xcafe;
    const TRADER_1: address = @0xdead;
    const TRADER_2: address = @0xbeef;

    struct ETH has store {}
    struct USDC has store {}

    #[test]
    fun test_add_margin() {
        let scenario = test_scenario::begin(OWNER);
        let scenario_mut = &mut scenario;
        init_modules(scenario_mut);
        test_scenario::next_tx(scenario_mut, OWNER);
        let oc = test_scenario::take_from_sender<OwnerCap>(scenario_mut);
        let gm = test_scenario::take_shared<GlobalMarkets>(scenario_mut);
        create_market<ETH, USDC>(&oc, &mut gm, scenario_mut);

        // add margin as a Trader
        test_scenario::next_tx(scenario_mut, TRADER_1);
        let ctx = test_scenario::ctx(scenario_mut);
        // create a clock
        let clock = clock::create_for_testing(ctx);
        let margin_value = 100 * ONE_UNIT;
        let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
        market::modify_position<ETH, USDC>(0, true, 0, trader_margin, &mut gm, &clock, ctx);
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let (pos_lfi, pos_margin, _, pos_size, pos_direction) = market_manager::get_position_data<ETH, USDC>(market, TRADER_1);
        test_utils::assert_eq(pos_lfi, 1);
        test_utils::assert_eq(pos_margin, margin_value);
        test_utils::assert_eq(pos_size, 0);
        test_utils::assert_eq(pos_direction, true);

        clock::destroy_for_testing(clock);

        end_scenario(scenario, oc, gm);
    }

    #[test]
    fun test_modify_position() {
        let scenario = test_scenario::begin(OWNER);
        let scenario_mut = &mut scenario;
        init_modules(scenario_mut);
        test_scenario::next_tx(scenario_mut, OWNER);
        let oc = test_scenario::take_from_sender<OwnerCap>(scenario_mut);
        let gm = test_scenario::take_shared<GlobalMarkets>(scenario_mut);
        create_market<ETH, USDC>(&oc, &mut gm, scenario_mut);

        {
            // assert inital market setup
            let market = market_manager::get_market<ETH, USDC>(&gm);
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
            vault_test_utils::assert_vault_balance<ETH, USDC>(market, 0); // no funds in vault
            vault_test_utils::assert_vault_fees_outstanding<ETH, USDC>(market, 0); // no fees in the vault yet
        };

        {
            // trader_1 opens 1 ETH long position with $100 margin with price at $2000
            test_scenario::next_tx(scenario_mut, TRADER_1);
            let ctx = test_scenario::ctx(scenario_mut);
            let clock = clock::create_for_testing(ctx);
            let margin_value = 100 * ONE_UNIT;
            let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
            let price_impact_delta = ONE_UNIT / 10; // .1%
            market::modify_position<ETH, USDC>(ONE_UNIT, true, price_impact_delta, trader_margin, &mut gm, &clock, ctx);
            let market = market_manager::get_market<ETH, USDC>(&gm);
            let (pos_lfi, pos_margin, pos_last_price, pos_size, pos_direction) = market_manager::get_position_data<ETH, USDC>(market, TRADER_1);

            // this trade is increasing the skew, so the taker fee is charged
            // expected margin = initial margin - order_fee
            // = $100 - (size * price * taker_fee)
            // = $100 - (1 * $2000 * .75%)
            // = $85
            test_utils::assert_eq(pos_margin, 85 * ONE_UNIT); // user has $85 margin remaining
            test_utils::assert_eq(pos_lfi, 1); // last funding index was 1
            test_utils::assert_eq(pos_last_price, 2000 * ONE_UNIT); // last price was $2000
            test_utils::assert_eq(pos_size, ONE_UNIT); // size is 1 ETH
            test_utils::assert_eq(pos_direction, true); // direction is long
            market_test_utils::assert_market_size<ETH, USDC>(market, ONE_UNIT); // market size is 1
            market_test_utils::assert_market_skew<ETH, USDC>(market, ONE_UNIT, true); // skew is 1 ETH long
            market_test_utils::assert_market_sizes<ETH, USDC>(market, ONE_UNIT, 0);
            market_test_utils::assert_last_funding_entry<ETH, USDC>(market, 0, true); // no funding yet
            vault_test_utils::assert_vault_balance<ETH, USDC>(market, 100 * ONE_UNIT); // vault has $100
            vault_test_utils::assert_vault_fees_outstanding<ETH, USDC>(market, 15 * ONE_UNIT); // $15 of fees should be in the vault
            clock::destroy_for_testing(clock);
        };

        {
            // 1 hour later, trader_2 opens 1 ETH short position with $100 margin with price at $2000
            test_scenario::next_tx(scenario_mut, TRADER_2);
            let ctx = test_scenario::ctx(scenario_mut);
            let clock = clock::create_for_testing(ctx);
            // set clock 1 hour later
            clock::increment_for_testing(&mut clock, ONE_HOUR_MS);

            let margin_value = 100 * ONE_UNIT;
            let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
            let price_impact_delta = ONE_UNIT / 10; // .1%
            market::modify_position<ETH, USDC>(ONE_UNIT, false, price_impact_delta, trader_margin, &mut gm, &clock, ctx);
            let market = market_manager::get_market<ETH, USDC>(&gm);
            let (pos_lfi, pos_margin, pos_last_price, pos_size, pos_direction) = market_manager::get_position_data<ETH, USDC>(market, TRADER_2);

            // this trade is reducing the skew, so the maker fee is charged
            // expected margin = initial margin - order_fee
            // = $100 - (size * price * maker_fee)
            // = $100 - (1 * $2000 * .50%)
            // = $90
            test_utils::assert_eq(pos_margin, 90 * ONE_UNIT); // user has $90 margin remaining
            test_utils::assert_eq(pos_lfi, 2); // last funding index was 2
            test_utils::assert_eq(pos_last_price, 2000 * ONE_UNIT); // last price was $2000
            test_utils::assert_eq(pos_size, ONE_UNIT); // size is 1 ETH
            test_utils::assert_eq(pos_direction, false); // direction is short
            market_test_utils::assert_market_size<ETH, USDC>(market, 2 * ONE_UNIT); // market size is now 2
            market_test_utils::assert_market_skew<ETH, USDC>(market, 0, true); // skew is back to 0 (direction doesn't really matter)
            market_test_utils::assert_market_sizes<ETH, USDC>(market, ONE_UNIT, ONE_UNIT); // 1 long, 1 short
            market_test_utils::assert_last_funding_entry<ETH, USDC>(market, 0, true);
            vault_test_utils::assert_vault_balance(market, 200 * ONE_UNIT); // vault has $200
            vault_test_utils::assert_vault_fees_outstanding(market, 25 * ONE_UNIT); // $25 of fees should now be in the vault
            clock::destroy_for_testing(clock);
        };

        end_scenario(scenario, oc, gm);
    }

    #[test]
    #[expected_failure(abort_code = market_manager::EMarketDoesNotExist)]
    fun test_get_nonexistent_market() {
        let scenario = test_scenario::begin(OWNER);
        init_modules(&mut scenario);
        test_scenario::next_tx(&mut scenario, OWNER);
        let oc = test_scenario::take_from_sender<OwnerCap>(&scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(&scenario);
        // this should fail, market does not exist
        let _market = market_manager::get_market<ETH, USDC>(&gm);
        end_scenario(scenario, oc, gm);
    }

    #[test]
    #[expected_failure(abort_code = market_manager::EMarketDoesNotExist)]
    fun test_modify_position_nonexistent_market() {
        let scenario = test_scenario::begin(OWNER);
        init_modules(&mut scenario);
        test_scenario::next_tx(&mut scenario, OWNER);
        let oc = test_scenario::take_from_sender<OwnerCap>(&scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(&scenario);

        test_scenario::next_tx(&mut scenario, TRADER_1);
        let ctx = test_scenario::ctx(&mut scenario);
        let clock = clock::create_for_testing(ctx);
        let margin_value = 100 * ONE_UNIT;
        let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
        // this should fail, market does not exist
        market::modify_position<ETH, USDC>(0, true, 0, trader_margin, &mut gm, &clock, ctx);

        clock::destroy_for_testing(clock);

        end_scenario(scenario, oc, gm);
    }

    #[test]
    #[expected_failure(abort_code = market_manager::EMarketAlreadyExists)]
    fun test_cannot_add_duplicate_market() {
        let scenario = test_scenario::begin(OWNER);
        init_modules(&mut scenario);
        test_scenario::next_tx(&mut scenario, OWNER);
        let oc = test_scenario::take_from_sender<OwnerCap>(&scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
        market_manager::add_market<ETH, USDC>(&oc, &mut gm, ctx);
        // this should fail, cannot add another market with the same type
        market_manager::add_market<ETH, USDC>(&oc, &mut gm, ctx);
        end_scenario(scenario, oc, gm);
    }

    #[test]
    fun test_add_market() {
        let scenario = test_scenario::begin(OWNER);
        init_modules(&mut scenario);
        test_scenario::next_tx(&mut scenario, OWNER);
        let oc = test_scenario::take_from_sender<OwnerCap>(&scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(&scenario);
        let ctx = test_scenario::ctx(&mut scenario);
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
        end_scenario(scenario, oc, gm);
    }

    fun create_market<B, Q>(oc: &OwnerCap, gm: &mut GlobalMarkets, scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, OWNER);
        let ctx = test_scenario::ctx(scenario);
        market_manager::add_market<B, USDC>(oc, gm, ctx);
        // set the market parameters
        market_manager::set_market_parameters<ETH, USDC>(oc, gm,
            2 * ONE_UNIT, //min_keeper_fee (2)
            1000 * ONE_UNIT, //max_keeper_fee (1000)
            3500000, // liquidation_fee_ratio (.0035)
            10000000, // liquidation_buffer_ratio (.01)
            40 * ONE_UNIT, // min_initial_margin (40)
            7500000, // taker_fee (.0075)
            5000000, // maker_fee (.0050)
            100 * ONE_UNIT, // max_leverage (100)
            10_000 * ONE_UNIT, // max_market_value (10,000)
            3 * ONE_UNIT, // max_funding_velocity (3)
            1_000_000 * ONE_UNIT, // skew_scale (1,000,000)
            100000000, // liquidation_premium_multiplier (.10)
        );
    }

    fun init_modules(scenario: &mut Scenario) {
        let ctx = test_scenario::ctx(scenario);
        market_manager::test_init(ctx);
    }

    fun end_scenario(scenario: Scenario, oc: OwnerCap, gm: GlobalMarkets) {
        test_scenario::next_tx(&mut scenario, OWNER);
        test_scenario::return_to_sender<OwnerCap>(&mut scenario, oc);
        test_scenario::return_shared<GlobalMarkets>(gm);
        test_scenario::end(scenario);
    }

}
