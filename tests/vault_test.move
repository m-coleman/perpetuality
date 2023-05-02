#[test_only]
module perp::vault_tests {

    //use sui::tx_context;
    use perp::market_manager::{Self, OwnerCap, GlobalMarkets};
    use perp::vault::{Self};
    use sui::test_scenario::{Self, Scenario};
    use sui::coin::{Self};
    use sui::test_utils;
    //use sui::sui::SUI;
    use sui::table::{Self};
    use std::string;
    //use std::debug;
    //use sui::table::{Self};

    const Staker1 : address = @0x1;
    const Staker2 : address = @0x2;
    const Owner : address = @0x3;

    struct ETH has store {}
    struct USDC has store {}


    #[test]
    fun simple_test_toggle_can_stake() {
        //Create the initial scenarios and init
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        init_modules(scenario);
        test_scenario::next_tx(scenario, Owner);
        let o = test_scenario::take_from_sender<OwnerCap>(scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(scenario);
        let ctx = test_scenario::ctx(scenario);

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

        return_staking_items(o, gm, scenario_val);
    }

    #[test]
    fun simple_test_stake_unstake() {
        //Create the initial scenarios and init
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        init_modules(scenario);

        test_scenario::next_tx(scenario, Owner);
        let o = test_scenario::take_from_sender<OwnerCap>(scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(scenario);
        let ctx = test_scenario::ctx(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for the owner
        let amount_for_owner_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_owner_to_mint, &mut gm, scenario);

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

        // //Unstake 5 shares
        let shares_to_unstake = 5;
        unstake_helper<ETH, USDC>(shares_to_unstake, &mut gm, scenario);
        
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

        //Attempt to unstake 20 shares now
        let shares_to_unstake = 20;
        unstake_helper<ETH, USDC>(shares_to_unstake, &mut gm, scenario);

        //ensure vault settings updated correctly for user trying to retrieve more shares than they have... should default to all shares they have left
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let vs = market_manager::get_vault<ETH, USDC>(market);
        test_utils::assert_eq(market_manager::get_vault_funds<USDC>(vs), 0);
        test_utils::assert_eq(market_manager::get_vault_shares<USDC>(vs), 0);
        let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
        let row_exists = table::contains(stakes_table, Owner);
        test_utils::assert_eq(row_exists, false);

        return_staking_items(o, gm, scenario_val);
    }

    #[test]
    fun test_stake_reinvest() {
        //Create the initial scenarios and init
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        init_modules(scenario);

        test_scenario::next_tx(scenario, Owner);
        let o = test_scenario::take_from_sender<OwnerCap>(scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(scenario);
        let ctx = test_scenario::ctx(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for staker1
        test_scenario::next_tx(scenario, Staker1);
        let amount_for_staker1_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker1_to_mint, &mut gm, scenario);

        //Stake 10 coins for staker2
        test_scenario::next_tx(scenario, Staker2);
        let amount_for_staker2_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker2_to_mint, &mut gm, scenario);

        //ensure no claimable reward is available
        let claimable_reward = vault::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);

        //pass in 20 sui of fees to the contract (say someone paid a large fee)
        let amount_fees = 20;
        add_to_cumulative_rewards_helper<ETH, USDC>(amount_fees, &mut gm, scenario);

        //Check that staker1's claimable reward is 1/2 or the fees - 10 in this case
        test_scenario::next_tx(scenario, Staker1);
        let claimable_reward = vault::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, amount_fees / 2);

        //Reinvest those fees
        let ctx = test_scenario::ctx(scenario);
        vault::reinvest<ETH, USDC>(&mut gm, ctx);

        //Ensure those fees got reinvested and therefore staker1 has no more claimable rewards
        test_scenario::next_tx(scenario, Staker1);
        let claimable_reward = vault::get_claimable_reward<ETH, USDC>(&gm, Staker1);
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

        return_staking_items(o, gm, scenario_val);
    }

    #[test]
    fun test_stake_claim_reward() {
        //Create the initial scenarios and init
        let scenario_val = test_scenario::begin(Owner);
        let scenario = &mut scenario_val;
        init_modules(scenario);

        test_scenario::next_tx(scenario, Owner);
        let o = test_scenario::take_from_sender<OwnerCap>(scenario);
        let gm = test_scenario::take_shared<GlobalMarkets>(scenario);
        let ctx = test_scenario::ctx(scenario);

        //Create the market and the vault
        market_manager::add_market<ETH, USDC>(&o, &mut gm, ctx);

        //set canUserStake to true
        test_scenario::next_tx(scenario, Owner);
        market_manager::set_can_user_stake<ETH, USDC>(&o, &mut gm, true);

        //Stake 10 coins for staker1
        test_scenario::next_tx(scenario, Staker1);
        let amount_for_staker1_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker1_to_mint, &mut gm, scenario);

        //Stake 10 coins for staker2
        test_scenario::next_tx(scenario, Staker2);
        let amount_for_staker2_to_mint = 10;
        stake_helper<ETH, USDC>(amount_for_staker2_to_mint, &mut gm, scenario);

        //ensure no claimable reward is available
        let claimable_reward = vault::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);

        //pass in 20 sui of fees to the contract (say someone paid a large fee)
        let amount_fees = 20;
        add_to_cumulative_rewards_helper<ETH, USDC>(amount_fees, &mut gm, scenario);

        test_scenario::next_tx(scenario, Staker1);
        {
            let ctx = test_scenario::ctx(scenario);
            let claimable_reward = vault::get_claimable_reward<ETH, USDC>(&gm, Staker1);
            test_utils::assert_eq(claimable_reward, amount_fees / 2);
            vault::claim_reward<ETH, USDC>(&mut gm, ctx);
        };

        let claimable_reward = vault::get_claimable_reward<ETH, USDC>(&gm, Staker1);
        test_utils::assert_eq(claimable_reward, 0);
        let market = market_manager::get_market<ETH, USDC>(&gm);
        let vs = market_manager::get_vault<ETH, USDC>(market);
        let stakes_table = market_manager::get_vault_stakes<USDC>(vs);
        let user_stake = market_manager::get_user_amount_from_stakes(stakes_table, Staker1);
        test_utils::assert_eq(user_stake, 10);

        //TODO - properly assert against shares but need realtime balance
        //let user_share = vault::get_user_shares_from_stakes(stakes_table, Staker1);
        //test_utils::assert_eq(user_share, 20);

        return_staking_items(o, gm, scenario_val);
    }

    fun return_staking_items(o : OwnerCap, gm : GlobalMarkets, scenario_val : Scenario) {
        test_scenario::next_tx(&mut scenario_val, Owner);
        test_scenario::return_to_sender<OwnerCap>(&mut scenario_val, o);
        test_scenario::return_shared<GlobalMarkets>(gm);
        test_scenario::end(scenario_val);
    }

    fun init_modules(scenario: &mut Scenario) {
        let ctx = test_scenario::ctx(scenario);
        market_manager::test_init(ctx);
    }

    fun confirm_if_user_can_stake<B, Q>(gm: &GlobalMarkets, assertion_val: bool) {
        let can_user_stake = market_manager::get_can_user_stake<B, Q>(gm);
        test_utils::assert_eq(can_user_stake, assertion_val);
    }

    fun stake_helper<B, Q>(mint_amount : u64, gm : &mut GlobalMarkets, scenario : &mut Scenario) {
        let ctx = test_scenario::ctx(scenario);
        let coin = coin::mint_for_testing<Q>(mint_amount, ctx);
        vault::stake<B, Q>(gm, coin, ctx);
    }

    fun unstake_helper<B, Q>(shares_to_unstake : u64, gm : &mut GlobalMarkets, scenario : &mut Scenario) {
        test_scenario::next_tx(scenario, Owner);
        let ctx = test_scenario::ctx(scenario);
        vault::unstake<B, Q>(gm, shares_to_unstake, ctx);
    }

    fun add_to_cumulative_rewards_helper<B, Q>(amount_fees : u64, gm : &mut GlobalMarkets, scenario : &mut Scenario) {
        test_scenario::next_tx(scenario, Owner);
        let ctx = test_scenario::ctx(scenario);
        let coin = coin::mint_for_testing<Q>(amount_fees, ctx);
        vault::add_to_cumulative_rewards<B, Q>(coin, gm);
    }

}