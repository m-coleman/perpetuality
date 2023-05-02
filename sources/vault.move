module perp::vault {

    //use std::string;
    use sui::tx_context::{Self, TxContext};
    use perp::events::{Self};
    use sui::table::{Self};
    use perp::market_manager::{Self, GlobalMarkets};
    use sui::balance::{Self};
    use sui::coin::{Self, Coin};
    use sui::transfer;
    //use std::debug;

    /// For when trying to destroy a non-zero balance.
    const ECannotStake: u64 = 999;

    fun init(_ctx: &mut TxContext) {
    }

    //This is an external function - called by market to update
    public fun add_to_cumulative_rewards<B, Q>(amount: Coin<Q>, gm: &mut GlobalMarkets) {
        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);

        //Get value of coins passed in
        let coin_amount = coin::value(&amount);

        //Get total vault shares
        let shares = market_manager::get_vault_shares(vs);

        //Get vault cumulative rewards per share and use that to set updated calc for cumulative rewards per share
        let cumulative_reward_per_share = market_manager::get_vault_cumulative_rewards_per_share<Q>(vs);
        market_manager::set_vault_cumulative_rewards_per_share<Q>(vs, cumulative_reward_per_share + (coin_amount / shares));

        //Get vault outstanding fees and use that to set updated calc for outstanding fees
        let fees_outstanding = market_manager::get_vault_fees_outstanding<Q>(vs);
        market_manager::set_vault_fees_outstanding<Q>(vs, fees_outstanding + coin_amount);

        //Update funds balance in the vault
        let vault_funds_mut = market_manager::get_vault_funds_mut<Q>(vs);
        balance::join(vault_funds_mut, coin::into_balance(amount));
    }

    //Get the real-time claimable rewards for this user
    public entry fun get_claimable_reward<B, Q>(gm: &GlobalMarkets, addr: address): u64 {
        //Get vault, rewards and stakes - all immutable references
        let market = market_manager::get_market<B, Q>(gm);
        let vs = market_manager::get_vault<B, Q>(market);
        let rewards = market_manager::get_vault_rewards(vs);
        let stakes = market_manager::get_vault_stakes<Q>(vs);

        //Ensure the user has a stake and reward object in the tables
        if (!table::contains(stakes, addr) || !table::contains(rewards, addr)) {
            return 0
        };

        //Get the user's reward info object
        let user_reward_info = market_manager::get_user_reward_info(vs, addr); 

        //Get the user's current claimable reward and previous reward per share
        let curr_claimable_reward = market_manager::get_user_reward_claimable_reward(user_reward_info);
        let previous_reward_per_share = market_manager::get_user_reward_previous_reward_per_share(user_reward_info);

        //Get vault cumulative rewards per share
        let cumulative_rewards_per_share = market_manager::get_vault_cumulative_rewards_per_share(vs);

        //Get user shares from stake
        let user_shares = market_manager::get_user_shares_from_stakes(stakes, addr);

        //Get the updated claimable reward
        let updated_claimable_reward = curr_claimable_reward + (user_shares * (cumulative_rewards_per_share - previous_reward_per_share));
        updated_claimable_reward
    }

    fun update_reward_for_user<B, Q>(gm: &mut GlobalMarkets, addr: address) {
        //Get current claimable reward
        let updated_claimable_reward = get_claimable_reward<B, Q>(gm, addr);
        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);

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
        ctx: &mut TxContext
    ) {
        internal_stake<B, Q>(gm, amount, false, ctx);
    }

    //This is the private function - no external users can call with is_reinvest as true
    fun internal_stake<B, Q>(gm: &mut GlobalMarkets, amount: Coin<Q>, is_reinvest: bool, ctx: &mut TxContext) {
        //run initial checks and update rewards
        let msg_sender = tx_context::sender(ctx);
        let coin_amount = coin::value(&amount);
        assert!(coin_amount > 0, 2);
        assert!(market_manager::get_can_user_stake<B, Q>(gm) == true, ECannotStake);
        update_reward_for_user<B, Q>(gm, msg_sender);

        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);

        //Get stakes and staked amount
        let funds_amount = market_manager::get_vault_funds<Q>(vs);
        //TODO - need to be able to get realTime Balance. For now it is just staked
        let real_time_balance = funds_amount;
        //get proper number of shares to be given to user. If no money has been staked, it is just the amount. Otherwise amount * (totalShares / realtimeBalance)
        //Parens represent the price per share
        let vault_shares = market_manager::get_vault_shares(vs);
        let shares = if (funds_amount > 0) {
            coin_amount * (vault_shares / real_time_balance)
        } else {
            coin_amount
        };

        //Update vault settings
        balance::join(market_manager::get_vault_funds_mut(vs), coin::into_balance(amount));
        market_manager::set_vault_shares<Q>(vs, vault_shares + shares);

        let stakes = market_manager::get_vault_stakes_mut<Q>(vs);

        if (is_reinvest) {
            //TODO - emit event
        };

        //TODO - add cap exceeded check
        // if (this._staked.add(amount).gt(this._cap)) {
        //     revertIfError(Status.CapExceeded);
        // }

        //update values in stakes table for user
        if (table::contains(stakes, msg_sender)) {
            //Get the user stake and update the appropriate values
            let user_stake = market_manager::get_user_stake_mut(stakes, msg_sender);
            let user_stake_amount = market_manager::get_amount_in_user_stake(user_stake);
            let user_stake_shares = market_manager::get_shares_in_user_stake(user_stake);
            market_manager::set_amount_in_user_stake(user_stake, user_stake_amount + coin_amount);
            market_manager::set_shares_in_user_stake(user_stake, user_stake_shares + shares);
            //TODO - update with real blockchain time
        } else {
            let user_stake = market_manager::create_stake(msg_sender, coin_amount, shares);
            table::add(stakes, msg_sender, user_stake);
        };

        //Emit user, shares, amount
        events::staked_event(msg_sender, shares, coin_amount);
    }

    public entry fun unstake<B, Q>(gm: &mut GlobalMarkets, shares: u64, ctx: &mut TxContext) {
        //Update rewards
        let msg_sender = tx_context::sender(ctx);
        update_reward_for_user<B, Q>(gm, msg_sender);

        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);

        //TODO - need to be able to get realTime Balance. For now it is just staked
        let real_time_balance = market_manager::get_vault_funds<Q>(vs);

        //Get the shares in the vault
        let vault_shares = market_manager::get_vault_shares<Q>(vs);
        
        //Initialize share_balance outside first block to avoid borrowing an active reference
        let share_balance;

        {
            //Get user stake
            let stakes_table = market_manager::get_vault_stakes_mut<Q>(vs);
            let user_stake = market_manager::get_user_stake_mut(stakes_table, msg_sender);

            //Get user shares and user amount
            let user_shares = market_manager::get_shares_in_user_stake(user_stake);
            let user_amount = market_manager::get_amount_in_user_stake(user_stake);
            //Check if it is a full redeem and ensure user cannot withdraw more than their shares
            let is_full_redeem = if (user_shares < shares) {
                shares = user_shares;
                true
            } else {
                false
            };

            //TODO- get actual time diff to make sure user can stop staking
            // const timeDiff: BigNumber = getBlockTimestamp().sub(stake.timestamp);
            // if (timeDiff.lt(this._stakingPeriod)) {
            //     revertIfError(Status.NotStakedLongEnough);
            // }

            //Run calculations to update values for the user
            share_balance = shares * real_time_balance / vault_shares;
            let amount = shares * user_amount / user_shares;
            market_manager::set_amount_in_user_stake(user_stake, user_amount - amount);
            market_manager::set_shares_in_user_stake(user_stake, user_shares - shares);
            
            //If it is a full redeem remove the stake from the table
            if (is_full_redeem) {
                table::remove(stakes_table, msg_sender);
            };
        };

        //Run calculations to update values for the vault and take balance from that amount staked
        let vault_staked = market_manager::get_vault_funds_mut<Q>(vs);
        let user_balance_to_be_paid = balance::split(vault_staked, share_balance);
        market_manager::set_vault_shares<Q>(vs, vault_shares - shares);

        //TODO - need to check the utilization ration and open interest to ensure everything aligns
        // const utilization = multiplyDecimal(
        //     this.getBalanceOfVault(),
        //     this.utilizationMultiplier
        // );
        // const { long, short } = this._marketViews.marketSizes();
        // const openInterest = long.add(short);
        // if (openInterest.gt(utilization)) {
        //     revertIfError(Status.Overutilized);
        // }

        //Remove coin from take balance and pay staker
        let coin_payout_to_user = coin::from_balance<Q>(user_balance_to_be_paid, ctx);
        transfer::public_transfer(coin_payout_to_user, msg_sender);

        //  emit Redeemed(
        //     user,
        //     receiver,
        //     amount,
        //     shares,
        //     share_balance,
        //     is_full_redeem
        // );
    }

    public entry fun reinvest<B, Q>(gm: &mut GlobalMarkets, ctx: &mut TxContext): u64 {
        //Update rewards and get claimable reward
        let msg_sender =  tx_context::sender(ctx);
        update_reward_for_user<B, Q>(gm, msg_sender);
        let reinvest_amount = get_claimable_reward<B, Q>(gm, msg_sender);

        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);

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
            internal_stake<B, Q>(gm, reinvest_coin, true, ctx);
            
            // emit Reinvested(
            //     msg_sender,
            //     reinvest_amount
            // );

        };
        reinvest_amount
    }

    public entry fun claim_reward<B, Q>(gm: &mut GlobalMarkets, ctx: &mut TxContext) : u64 {
        //Update rewards and claim reward
        let msg_sender =  tx_context::sender(ctx);
        update_reward_for_user<B, Q>(gm, msg_sender);
        let reward_to_send = get_claimable_reward<B, Q>(gm, msg_sender);

        let market = market_manager::get_market_mut<B, Q>(gm);
        let vs = market_manager::get_vault_mut<B, Q>(market);

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
            
            /*emit ClaimedReward(
                msg_sender,
                reward_to_send
            );*/
        };
        reward_to_send
    }

}