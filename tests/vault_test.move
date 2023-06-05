#[test_only]
module perp::vault_tests {

    use sui::tx_context::{TxContext};
    use perp::market_manager::{Self, OwnerCap, GlobalMarkets};
    use perp::vault::{Self};
    use sui::test_scenario::{Self, Scenario};
    use sui::coin::{Self};
    use sui::test_utils;
    //use sui::sui::SUI;
    use sui::table::{Self};
    use std::string;
    use sui::clock::{Self, Clock};
    use perp::market_views;
    use perp::market;
    use std::debug;
    //use sui::table::{Self};

    const Staker1 : address = @0x1;
    const Staker2 : address = @0x2;
    const Owner : address = @0x3;
    const Trader1: address = @0x4;
    const ONE_HOUR_MS: u64 = 60 * 60 * 1000;
    const ONE_MS: u64 = 1000;
    const ONE_UNIT: u64 = 1_000_000_000;

    struct ETH has store {}
    struct USDC has store {}


    #[test]
    fun simple_test_toggle_can_stake() {
        //Create the initial scenarios and init owner items
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);
        let market_name = market_manager::get_market_name<ETH, USDC>();
        let expected_market_name = string::utf8(
            b"0000000000000000000000000000000000000000000000000000000000000000::vault_tests::ETH-0000000000000000000000000000000000000000000000000000000000000000::vault_tests::USDC"
        );
        test_utils::assert_eq(market_name, expected_market_name);

        //Confirm user cannot stake
        confirm_if_user_can_stake<ETH, USDC>(&gm, false);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Confirm user can now stake
        test_scenario::next_tx(scenario, Owner);
        confirm_if_user_can_stake<ETH, USDC>(&gm, true);

        return_staking_items(o, gm, clock, scenario_val);
    }

    #[test]
    fun simple_test_stake_unstake() {
        //Create the initial scenarios and init
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for the owner
        let amount_for_owner_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_owner_to_mint, &mut gm, &clock, scenario);

        {
            //ensure vault settings updated correctly
            let market = market_manager::get_market<ETH, USDC>(&gm);
            let vs = market_manager::get_vault<ETH, USDC>(market);
            test_utils::assert_eq(market_manager::get_vault_funds<USDC>(vs), amount_for_owner_to_mint);
            test_utils::assert_eq(market_manager::get_vault_shares<USDC>(vs), amount_for_owner_to_mint);
            let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
            let user_stake = market_manager::get_user_amount_from_stakes(stakes_table, Owner);
            test_utils::assert_eq(user_stake, amount_for_owner_to_mint);
            let user_share = market_manager::get_user_shares_from_stakes(stakes_table, Owner);
            test_utils::assert_eq(user_share, amount_for_owner_to_mint);
        };

        // //Unstake 5 shares and set clock 1 hour later
        test_scenario::next_tx(scenario, Owner);
        let shares_to_unstake = 5;
        clock::increment_for_testing(&mut clock, ONE_HOUR_MS);
        unstake_helper<ETH, USDC>(shares_to_unstake, &mut gm, &clock, scenario);
        
        //debug::print(&vault::get_vault_staked<SUI>(&vs));
        {
            //ensure vault settings updated correctly after unstaking half
            let market = market_manager::get_market<ETH, USDC>(&gm);
            let vs = market_manager::get_vault<ETH, USDC>(market);
            test_utils::assert_eq(market_manager::get_vault_funds<USDC>(vs), amount_for_owner_to_mint - shares_to_unstake);
            test_utils::assert_eq(market_manager::get_vault_shares<USDC>(vs), amount_for_owner_to_mint - shares_to_unstake);
            let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
            let user_stake = market_manager::get_user_amount_from_stakes(stakes_table, Owner);
            test_utils::assert_eq(user_stake, amount_for_owner_to_mint - shares_to_unstake);
            let user_share = market_manager::get_user_shares_from_stakes(stakes_table, Owner);
            test_utils::assert_eq(user_share, amount_for_owner_to_mint - shares_to_unstake);
        };

        //Attempt to unstake 20 shares now and set clock 1 hour later
        test_scenario::next_tx(scenario, Owner);
        let shares_to_unstake = 20;
        clock::increment_for_testing(&mut clock, ONE_HOUR_MS);
        unstake_helper<ETH, USDC>(shares_to_unstake, &mut gm, &clock, scenario);

        //ensure vault settings updated correctly for user trying to retrieve more shares than they have... should default to all shares they have left
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let vs = market_manager::get_vault<ETH, USDC>(market);
        test_utils::assert_eq(market_manager::get_vault_funds<USDC>(vs), 0);
        test_utils::assert_eq(market_manager::get_vault_shares<USDC>(vs), 0);
        let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
        let row_exists = table::contains(stakes_table, Owner);
        test_utils::assert_eq(row_exists, false);

        return_staking_items(o, gm, clock, scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = vault::ENotStakingLongEnough)]
    fun test_unstake_too_quickly() {
        //Create the initial scenarios and init owner items
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for Staker1
        test_scenario::next_tx(scenario, Staker1);
        let amount_for_staker1_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker1_to_mint, &mut gm, &clock, scenario);

        {
            //ensure vault settings updated correctly
            let market = market_manager::get_market<ETH, USDC>(&gm);
            let vs = market_manager::get_vault<ETH, USDC>(market);
            test_utils::assert_eq(market_manager::get_vault_funds<USDC>(vs), amount_for_staker1_to_mint);
            test_utils::assert_eq(market_manager::get_vault_shares<USDC>(vs), amount_for_staker1_to_mint);
            let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
            let user_stake = market_manager::get_user_amount_from_stakes(stakes_table, Staker1);
            test_utils::assert_eq(user_stake, amount_for_staker1_to_mint);
            let user_share = market_manager::get_user_shares_from_stakes(stakes_table, Staker1);
            test_utils::assert_eq(user_share, amount_for_staker1_to_mint);
        }; 

        //Staker1 unstakes 5 shares
        test_scenario::next_tx(scenario, Staker1);
        let shares_to_unstake = 5;
        //This will abort, not enough time has passed
        clock::increment_for_testing(&mut clock, ONE_MS);
        unstake_helper<ETH, USDC>(shares_to_unstake, &mut gm, &clock, scenario);
        
        return_staking_items(o, gm, clock, scenario_val);
    }

    #[test]
    #[expected_failure(abort_code = vault::ECapExceeded)]
    fun test_stake_more_than_capacity() {
        //Create the initial scenarios and init owner items
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Staker1);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake max_capacity + 1 coins for the owner
        test_scenario::next_tx(scenario, Staker1);
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let vs = market_manager::get_vault<ETH, USDC>(market);
        let vault_max_capacity = market_manager::get_vault_max_capacity(vs);
        let amount_for_owner_to_mint = vault_max_capacity + 1;

        //This will fail because the user is adding more to the vault than max capacity
        stake_helper<ETH, USDC>(amount_for_owner_to_mint, &mut gm, &clock, scenario);

        return_staking_items(o, gm, clock, scenario_val);
    }

    /* #[test]
    #[expected_failure(abort_code = vault::EOpenInterestTooLarge)]
    fun test_cannot_withdraw_stake_oi_too_large() {
        //Create the initial scenarios and init owner items
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 100 for staker1
        test_scenario::next_tx(scenario, Staker1);
        let amount_for_owner_to_mint = 100;
        stake_helper<ETH, USDC>(amount_for_owner_to_mint, &mut gm, &clock, scenario);


        //Modify position for Trader1
        test_scenario::next_tx(scenario, Trader1);
        market_manager::set_market_parameters<ETH, USDC>(&o, &mut gm,
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
        let ctx = test_scenario::ctx(scenario);
        let margin_value = 100 * ONE_UNIT;
        let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
        let price_impact_delta : u64 = ONE_UNIT / 10;
        market::modify_position<ETH, USDC>(ONE_UNIT, true, price_impact_delta, trader_margin, &mut gm, &clock, ctx);

        //Unstake 5 for staker1 - should fail because the open interest is too large
        let shares_to_unstake = 5;
        // set clock 1 hour later
        test_scenario::next_tx(scenario, Staker1);
        clock::increment_for_testing(&mut clock, ONE_HOUR_MS);
        unstake_helper<ETH, USDC>(shares_to_unstake, &mut gm, &clock, scenario);

        return_staking_items(o, gm, clock, scenario_val);
    } */

    #[test]
    fun test_stake_reinvest() {
        //Create the initial scenarios and init owner items
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for staker1
        test_scenario::next_tx(scenario, Staker1);
        let amount_for_staker1_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker1_to_mint, &mut gm, &clock, scenario);

        //Stake 10 coins for staker2
        test_scenario::next_tx(scenario, Staker2);
        let amount_for_staker2_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker2_to_mint, &mut gm, &clock, scenario);

        //ensure no claimable reward is available
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);

        //pass in 20 sui of fees to the contract (say someone paid a large fee)
        let amount_fees = 20;
        add_to_cumulative_rewards_helper<ETH, USDC>(amount_fees, &mut gm, scenario);

        //Check that staker1's claimable reward is 1/2 or the fees - 10 in this case
        test_scenario::next_tx(scenario, Staker1);
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, amount_fees / 2);

        //Reinvest those fees
        let ctx = test_scenario::ctx(scenario);
        vault::reinvest<ETH, USDC>(&mut gm, &clock, ctx);

        //Ensure those fees got reinvested and therefore staker1 has no more claimable rewards
        test_scenario::next_tx(scenario, Staker1);
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);

        //Make sure staker1 has the correct amount in their stake balance after reinvesting
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let vs = market_manager::get_vault<ETH, USDC>(market);
        let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
        let user_stake = market_manager::get_user_amount_from_stakes(stakes_table, Staker1);
        test_utils::assert_eq(user_stake, 20);

        //TODO - properly assert against shares but need realtime balance
        //let user_share = vault::get_user_shares_from_stakes(stakes_table, Staker1);
        //test_utils::assert_eq(user_share, 20);
        return_staking_items(o, gm, clock, scenario_val);
    }

    #[test]
    fun test_stake_claim_reward() {
        //Create the initial scenarios and init owner items
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for staker1
        test_scenario::next_tx(scenario, Staker1);
        let amount_for_staker1_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker1_to_mint, &mut gm, &clock, scenario);

        //Stake 10 coins for staker2
        test_scenario::next_tx(scenario, Staker2);
        let amount_for_staker2_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker2_to_mint, &mut gm, &clock, scenario);

        //ensure no claimable reward is available
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);

        //pass in 20 USDC of fees to the contract (say someone paid a large fee)
        let amount_fees = 20;
        add_to_cumulative_rewards_helper<ETH, USDC>(amount_fees, &mut gm, scenario);

        test_scenario::next_tx(scenario, Staker1);
        {
            let ctx = test_scenario::ctx(scenario);
            let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
            test_utils::assert_eq(claimable_reward, amount_fees / 2);
            vault::claim_reward<ETH, USDC>(&mut gm, ctx);
        };

        //Make sure user's claim reward was successful
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let vs = market_manager::get_vault<ETH, USDC>(market);
        let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
        let user_stake = market_manager::get_user_amount_from_stakes(stakes_table, Staker1);
        test_utils::assert_eq(user_stake, 10);

        //TODO - properly assert against shares but need realtime balance
        //let user_share = vault::get_user_shares_from_stakes(stakes_table, Staker1);
        //test_utils::assert_eq(user_share, 20);
        return_staking_items(o, gm, clock, scenario_val);
    }

    #[test]
    fun test_stake_claim_reward_from_open_position() {
        //Create the initial scenarios and init owner items
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for staker1
        test_scenario::next_tx(scenario, Staker1);
        let amount_for_staker1_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker1_to_mint, &mut gm, &clock, scenario);

        //Stake 10 coins for staker2
        test_scenario::next_tx(scenario, Staker2);
        let amount_for_staker2_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker2_to_mint, &mut gm, &clock, scenario);

        //ensure no claimable reward is available
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);

        //Modify position for Trader1
        test_scenario::next_tx(scenario, Trader1);
        market_manager::set_market_parameters<ETH, USDC>(&o, &mut gm,
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
        let ctx = test_scenario::ctx(scenario);
        let margin_value = 100 * ONE_UNIT;
        let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
        let price_impact_delta : u64 = ONE_UNIT / 10;
        market::modify_position<ETH, USDC>(ONE_UNIT, true, price_impact_delta, trader_margin, &mut gm, &clock, ctx);

        test_scenario::next_tx(scenario, Staker1);
        {
            let ctx = test_scenario::ctx(scenario);
            let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
            debug::print(&claimable_reward);
            test_utils::assert_eq(claimable_reward > 0, true);
            vault::claim_reward<ETH, USDC>(&mut gm, ctx);
        };

        //Make sure user's claim reward was successful
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let vs = market_manager::get_vault<ETH, USDC>(market);
        let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
        let user_stake = market_manager::get_user_amount_from_stakes(stakes_table, Staker1);
        test_utils::assert_eq(user_stake, 10);

        //TODO - properly assert against shares but need realtime balance
        //let user_share = vault::get_user_shares_from_stakes(stakes_table, Staker1);
        //test_utils::assert_eq(user_share, 20);
        return_staking_items(o, gm, clock, scenario_val);
    }

    #[test]
    fun test_stake_reinvest_from_open_position() {
        //Create the initial scenarios and init owner items
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        let (o, gm, ctx, clock) = init_modules_and_create_owner_items(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for staker1
        test_scenario::next_tx(scenario, Staker1);
        let amount_for_staker1_to_mint = 10 * ONE_UNIT;
        stake_helper<ETH, USDC>(amount_for_staker1_to_mint, &mut gm, &clock, scenario);

        //Stake 10 coins for staker2
        // test_scenario::next_tx(scenario, Staker2);
        // let amount_for_staker2_to_mint = 10* ONE_UNIT;
        // stake_helper<ETH, USDC>(amount_for_staker2_to_mint, &mut gm, &clock, scenario);

        //ensure no claimable reward is available
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);


        //Modify position for Trader1
        test_scenario::next_tx(scenario, Trader1);
        market_manager::set_market_parameters<ETH, USDC>(&o, &mut gm,
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
        let ctx = test_scenario::ctx(scenario);
        let margin_value = 80 * ONE_UNIT;
        let trader_margin = coin::mint_for_testing<USDC>(margin_value, ctx);
        let price_impact_delta : u64 = ONE_UNIT / 10;
        market::modify_position<ETH, USDC>(4*ONE_UNIT/10, true, price_impact_delta, trader_margin, &mut gm, &clock, ctx);

        {
            let market = market_manager::get_market<ETH, USDC>(&gm);
            let vs = market_manager::get_vault<ETH, USDC>(market);
            let vault_funds = market_manager::get_vault_funds(vs);
            debug::print(&999);
            debug::print(&vault_funds);
        };

        test_scenario::next_tx(scenario, Staker1);
        {
            let ctx = test_scenario::ctx(scenario);
            let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
            test_utils::assert_eq(claimable_reward > 0, true);
            vault::reinvest<ETH, USDC>(&mut gm, &clock, ctx);
        };

        //Make sure user's claim reward was successful
        let claimable_reward = market_views::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);
        // let market = market_manager::get_market<ETH, USDC>(&gm);
        // let vs = market_manager::get_vault<ETH, USDC>(market);
        // let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
        // let user_stake = market_manager::get_user_amount_from_stakes(stakes_table, Staker1);
        // test_utils::assert_eq(user_stake, 10);

        //TODO - properly assert against shares but need realtime balance
        //let user_share = vault::get_user_shares_from_stakes(stakes_table, Staker1);
        //test_utils::assert_eq(user_share, 20);
        return_staking_items(o, gm, clock, scenario_val);
    }

    fun return_staking_items(o: OwnerCap, gm: GlobalMarkets, clock: Clock, scenario_val: Scenario) {
        test_scenario::next_tx(&mut scenario_val, Owner);
        test_scenario::return_to_sender<OwnerCap>(&mut scenario_val, o);
        test_scenario::return_shared<GlobalMarkets>(gm);
        clock::destroy_for_testing(clock);
        test_scenario::end(scenario_val);
    }

    fun init_modules_and_create_owner_items(scenario: &mut Scenario) : (OwnerCap, GlobalMarkets, &mut TxContext, Clock) {
        let ctx = test_scenario::ctx(scenario);
        market_manager::test_init(ctx);
        test_scenario::next_tx(scenario, Owner);
        let o = test_scenario::take_from_sender<OwnerCap>(scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(scenario);
        let ctx = test_scenario::ctx(scenario);
        let clock = clock::create_for_testing(ctx);
        (o, gm, ctx, clock)
    }

    fun confirm_if_user_can_stake<B, Q>(gm: &GlobalMarkets, assertion_val: bool) {
        let can_user_stake = market_views::can_user_stake<B, Q>(gm);
        test_utils::assert_eq(can_user_stake, assertion_val);
    }

    fun stake_helper<B, Q>(mint_amount: u64, gm: &mut GlobalMarkets, clock: &Clock, scenario: &mut Scenario) {
        let ctx = test_scenario::ctx(scenario);
        let coin = coin::mint_for_testing<Q>(mint_amount, ctx);
        vault::stake<B, Q>(gm, coin, clock, ctx);
    }

    fun unstake_helper<B, Q>(shares_to_unstake: u64, gm: &mut GlobalMarkets, clock: &Clock, scenario: &mut Scenario) {
        let ctx = test_scenario::ctx(scenario);
        vault::unstake<B, Q>(gm, shares_to_unstake, clock, ctx);
    }

    fun add_to_cumulative_rewards_helper<B, Q>(amount_fees: u64, gm: &mut GlobalMarkets, scenario: &mut Scenario) {
        test_scenario::next_tx(scenario, Owner);
        let ctx = test_scenario::ctx(scenario);
        let coin = coin::mint_for_testing<Q>(amount_fees, ctx);
        vault::add_to_cumulative_rewards<B, Q>(coin, gm);
    }
}