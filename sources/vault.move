module perp::vault {

    //use std::string;
    use sui::tx_context::{Self, TxContext};
    use perp::events::{Self};
    use sui::table::{Self};
    use perp::market_manager::{Self, GlobalMarkets, Market, Vault};
    use sui::balance::{Self};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    use sui::clock::{Self, Clock};
    use perp::market_base;
    use perp::utils;
    //use std::debug;

    /// For when trying to destroy a non-zero balance.
    const ECannotStake: u64 = 0;
    const ECoinZero: u64 = 1;
    const ECapExceeded: u64 = 2;
    const ENotStakingLongEnough: u64 = 3;
    const EOpenInterestTooLarge: u64 = 4;

    fun init(_ctx: &mut TxContext) {
    }

    //This is an external function - called by anyone with coins
    public entry fun add_to_cumulative_rewards<B, Q>(amount: Coin<Q>, gm: &mut GlobalMarkets) {
        let market = market_manager::get_market_mut<B, Q>(gm);
        let vault = market_manager::get_vault_mut<B, Q>(market);

        //Get value of coins passed in
        let coin_amount = coin::value(&amount);

        //Update funds balance in the vault
        let vault_funds_mut = market_manager::get_vault_funds_mut<Q>(vault);
        balance::join(vault_funds_mut, coin::into_balance(amount));

        //Call add_to_cumulative_rewards in market_manager to handle bookkeeping
        market_manager::add_to_cumulative_rewards(coin_amount, vault);
    }

    //Get the real-time claimable rewards for this user
    public fun get_claimable_reward<Q>(vs: &Vault<Q>, addr: address): u64 {
        //Get rewards and stakes - all immutable references
        let rewards = market_manager::get_vault_rewards<Q>(vs);
        let stakes = market_manager::get_vault_stakes<Q>(vs);

        //Ensure the user has a stake and reward object in the tables
        if (!table::contains(stakes, addr) || !table::contains(rewards, addr)) {
            return 0
        };

        //Get the user's reward info object
        let user_reward_info = market_manager::get_user_reward_info<Q>(vs, addr); 

        //Get the user's current claimable reward and previous reward per share
        let curr_claimable_reward = market_manager::get_user_reward_claimable_reward(user_reward_info);
        let previous_reward_per_share = market_manager::get_user_reward_previous_reward_per_share(user_reward_info);

        //Get vault cumulative rewards per share
        let cumulative_rewards_per_share = market_manager::get_vault_cumulative_rewards_per_share<Q>(vs);

        //Get user shares from stake
        let user_shares = market_manager::get_user_shares_from_stakes(stakes, addr);

        //Get the updated claimable reward
        let updated_claimable_reward = curr_claimable_reward + utils::multiply_decimal(user_shares, (cumulative_rewards_per_share - previous_reward_per_share));
        updated_claimable_reward
    }

    fun update_reward_for_user<B, Q>(gm: &mut GlobalMarkets, addr: address) {
        //Get current claimable reward
        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);
        let updated_claimable_reward = get_claimable_reward<Q>(vs, addr);

        //ensure the user has a reward info to remove unnecessary checks later
        let rewards = market_manager::get_vault_rewards_mut(vs);
        if (!table::contains(rewards, addr)) {
            let user_reward_info = market_manager::create_reward(0, 0);
            table::add(rewards, addr, user_reward_info);
        };
        
        //Get current cumulative reward per share
        let cumulative_rewards_per_share = market_manager::get_vault_cumulative_rewards_per_share(vs);
        
        //Get the user reward info mutatable object
        let user_reward_info_mut = market_manager::get_user_reward_info_mut<Q>(vs, addr);

        //Set the user's claimable reward to the updated claimable reward
        market_manager::set_user_reward_claimable_reward(user_reward_info_mut, updated_claimable_reward);
        
        //Set updated cumulative reward per share
        market_manager::set_user_reward_previous_reward_per_share(user_reward_info_mut, cumulative_rewards_per_share);
    }

    public entry fun stake<B, Q>(
        gm: &mut GlobalMarkets,
        amount: Coin<Q>,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        internal_stake<B, Q>(gm, amount, false, clock, ctx);
    }

    //This is the private function - no external users can call with is_reinvest as true
    fun internal_stake<B, Q>(gm: &mut GlobalMarkets, amount: Coin<Q>, is_reinvest: bool, clock: &Clock, ctx: &mut TxContext) {
        //run initial checks and update rewards
        let msg_sender = tx_context::sender(ctx);
        let coin_amount = coin::value(&amount);

        update_reward_for_user<B, Q>(gm, msg_sender);

        let market = market_manager::get_market_mut<B, Q>(gm);
        //Get the real time vault net balance
        let vault_net_balance = get_vault_net_balance<B, Q>(market, clock);

        let vs = market_manager::get_vault_mut<B, Q>(market);

        assert!(coin_amount > 0, ECoinZero);
        assert!(market_manager::can_user_stake<Q>(vs) == true, ECannotStake);

        //Cap exceeded check
        let vault_max_capacity = market_manager::get_vault_max_capacity(vs);
        assert!(vault_max_capacity > (vault_net_balance + coin_amount), ECapExceeded);

        //get proper number of shares to be given to user. If no money has been staked, it is just the amount. Otherwise amount * (totalShares / realtimeBalance)
        //Parens represent the price per share
        let vault_shares = market_manager::get_vault_shares(vs);
        let shares = if (vault_net_balance > 0) {
            utils::multiply_decimal(coin_amount, utils::divide_decimal(vault_shares, vault_net_balance))
        } else {
            coin_amount
        };

        //Update vault settings
        balance::join(market_manager::get_vault_funds_mut(vs), coin::into_balance(amount));
        market_manager::set_vault_shares<Q>(vs, vault_shares + shares);

        let stakes = market_manager::get_vault_stakes_mut<Q>(vs);

        let curr_timestamp = clock::timestamp_ms(clock);
        //update values in stakes table for user
        if (table::contains(stakes, msg_sender)) {
            //Get the user stake and update the appropriate values
            let user_stake = market_manager::get_user_stake_mut(stakes, msg_sender);
            let user_stake_amount = market_manager::get_amount_in_user_stake(user_stake);
            let user_stake_shares = market_manager::get_shares_in_user_stake(user_stake);
            market_manager::set_amount_in_user_stake(user_stake, user_stake_amount + coin_amount);
            market_manager::set_shares_in_user_stake(user_stake, user_stake_shares + shares);
            market_manager::set_timestamp_in_user_stake(user_stake, curr_timestamp);
        } else {
            let user_stake = market_manager::create_stake(msg_sender, coin_amount, shares, curr_timestamp);
            table::add(stakes, msg_sender, user_stake);
        };

        //Emit staked event - user, shares, amount, is_reinvest
        events::staked_event(msg_sender, shares, coin_amount, is_reinvest);
    }

    public entry fun unstake<B, Q>(gm: &mut GlobalMarkets, shares: u64, clock: &Clock, ctx: &mut TxContext) {
        //Update rewards
        let msg_sender = tx_context::sender(ctx);
        update_reward_for_user<B, Q>(gm, msg_sender);

        let market = market_manager::get_market_mut<B, Q>(gm);
        //Get the real time vault net balance
        let vault_net_balance = get_vault_net_balance<B, Q>(market, clock);

        let vs = market_manager::get_vault_mut<B, Q>(market);
        //Get vault staking period
        let vault_staking_period = market_manager::get_vault_staking_period<Q>(vs);

        //Get the shares in the vault
        let vault_shares = market_manager::get_vault_shares<Q>(vs);
        
        //Initialize share_balance and is_full_redeem outside first block to avoid borrowing an active reference
        let share_balance;
        let is_full_redeem;

        {
            //Get user stake
            let stakes_table = market_manager::get_vault_stakes_mut<Q>(vs);
            let user_stake = market_manager::get_user_stake_mut(stakes_table, msg_sender);

            //Get user shares and user amount
            let user_shares = market_manager::get_shares_in_user_stake(user_stake);
            let user_amount = market_manager::get_amount_in_user_stake(user_stake);
            //Check if it is a full redeem and ensure user cannot withdraw more than their shares
            is_full_redeem = if (user_shares < shares) {
                shares = user_shares;
                true
            } else {
                false
            };

            //Make sure users cannot unstake funds unless the stake has been in the vault for more than staking_period defined in the vault
            let user_stake_timestamp = market_manager::get_timestamp_from_user_stake(user_stake);
            let curr_timestamp = clock::timestamp_ms(clock);
            let time_diff = curr_timestamp - user_stake_timestamp;
            assert!(vault_staking_period <= time_diff, ENotStakingLongEnough);

            //Run calculations to update values for the user
            share_balance = utils::multiply_decimal(shares, utils::divide_decimal(vault_net_balance, vault_shares));
            let amount = utils::multiply_decimal(shares, utils::divide_decimal(user_amount, user_shares));
            market_manager::set_amount_in_user_stake(user_stake, user_amount - amount);
            market_manager::set_shares_in_user_stake(user_stake, user_shares - shares);
            
            //If it is a full redeem remove the stake from the table
            if (is_full_redeem) {
                table::remove(stakes_table, msg_sender);
            };
        };

        //Run calculations to update values for the vault and take balance from that amount staked
        let vault_funds = market_manager::get_vault_funds_mut<Q>(vs);
        let user_balance_to_be_paid = balance::split(vault_funds, share_balance);
        market_manager::set_vault_shares<Q>(vs, vault_shares - shares);

        // ensure the open interest is less that the utilization * vault balance
        assert_open_interest_size<B, Q>(market, clock);

        //Remove coin from take balance and pay staker
        let coin_payout_to_user = coin::from_balance<Q>(user_balance_to_be_paid, ctx);
        transfer::public_transfer(coin_payout_to_user, msg_sender);

        //Emit staked event - user, shares, amount, is_full_redeem
        events::unstaked_event(msg_sender, shares, share_balance, is_full_redeem);
    }

    public entry fun reinvest<B, Q>(gm: &mut GlobalMarkets, clock: &Clock, ctx: &mut TxContext): u64 {
        //Update rewards and get claimable reward
        let msg_sender =  tx_context::sender(ctx);
        update_reward_for_user<B, Q>(gm, msg_sender);

        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);
        let reinvest_amount = get_claimable_reward<Q>(vs, msg_sender);

        if (reinvest_amount > 0) {
            //set users reward to 0
            let reward_info_mut = market_manager::get_user_reward_info_mut(vs, msg_sender);
            market_manager::set_user_reward_claimable_reward(reward_info_mut, 0);

            //take funds from the money in the contract - currently in staked balance
            //then, reduce the fees outstanding and call internal_stake with the created coins
            let vault_funds_mut = market_manager::get_vault_funds_mut(vs);
            let reinvest_coin = coin::take(vault_funds_mut, reinvest_amount, ctx);

            let curr_fees_outstanding = market_manager::get_vault_fees_outstanding(vs);
            market_manager::set_vault_fees_outstanding(vs, curr_fees_outstanding - reinvest_amount);
            internal_stake<B, Q>(gm, reinvest_coin, true, clock, ctx);
        };
        reinvest_amount
    }

    public entry fun claim_reward<B, Q>(gm: &mut GlobalMarkets, ctx: &mut TxContext) : u64 {
        //Update rewards and claim reward
        let msg_sender =  tx_context::sender(ctx);
        update_reward_for_user<B, Q>(gm, msg_sender);

        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);
        let reward_to_send = get_claimable_reward<Q>(vs, msg_sender);

        if (reward_to_send > 0) {
            //set users reward to 0
            let reward_info_mut = market_manager::get_user_reward_info_mut<Q>(vs, msg_sender);
            market_manager::set_user_reward_claimable_reward(reward_info_mut, 0);

            //take funds from the money in the contract - currently in staked balance
            //then, reduce the fees outstanding and send coins back to user
            let vault_funds_mut = market_manager::get_vault_funds_mut<Q>(vs);
            let reward_coins = coin::take(vault_funds_mut, reward_to_send, ctx);
            transfer::public_transfer(reward_coins, msg_sender);
            let fees_outstanding = market_manager::get_vault_fees_outstanding<Q>(vs);
            market_manager::set_vault_fees_outstanding<Q>(vs, fees_outstanding - reward_to_send);
            
            //Emit claim_reward event - user, reward
            events::claimed_event(msg_sender, reward_to_send);
        };
        reward_to_send
    }

    public fun get_vault_net_balance<B, Q>(market: &Market<B, Q>, clock: &Clock): u64 {
        let curr_timestamp = clock::timestamp_ms(clock);
        let market_debt = market_base::market_debt<B,Q>(market, curr_timestamp);

        let vault = market_manager::get_vault(market);
        let vault_funds = market_manager::get_vault_funds<Q>(vault);
        let vault_reward_fees = market_manager::get_vault_fees_outstanding<Q>(vault);
        //vault_net_balance = funds - marketDebt - fees - since we store fees in the funds balance and we need marketDebt to get real time pnl
        let vault_net_balance = vault_funds - market_debt - vault_reward_fees;
        vault_net_balance
    }

    public fun assert_open_interest_size<B, Q>(market: &Market<B, Q>, clock: &Clock) {
        // check the open interest is less that the utilization * vault balance
        let vault = market_manager::get_vault<B, Q>(market);
        let vault_net_balance = get_vault_net_balance<B, Q>(market, clock);
        let utilization_mutliplier = market_manager::get_vault_utilization_multiplier<Q>(vault);
        let utilization = utils::multiply_decimal(vault_net_balance, utilization_mutliplier);
        let (long, short) = market_manager::market_sizes(market);
        let open_interest = long + short;
        assert!(open_interest <= utilization, EOpenInterestTooLarge);
    }

}