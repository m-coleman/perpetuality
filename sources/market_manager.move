module perp::market_manager {

    use std::ascii::into_bytes;
    use std::string::{Self, String};
    use std::type_name::{get, into_string};
    use std::vector;

    use sui::object::{Self, UID};
    use sui::bag::{Self, Bag};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::table::{Self, Table};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};

    use perp::utils;

    friend perp::market;
    friend perp::market_base;
    friend perp::vault;
    friend perp::exchange_rates;
    friend perp::market_views; // TODO: remove this

    const EMarketAlreadyExists: u64 = 0;
    const EMarketDoesNotExist: u64 = 1;
    const ONE_UNIT: u64 = 1_000_000_000;

    // owner capability
    struct OwnerCap has key, store {
        id: UID
    }

    struct GlobalMarkets has key {
        id: UID,
        markets: Bag
    }

    // Todo - double check on drop here
    struct Stake has store, drop {
        owner: address,
        amount: u64,
        shares: u64,
        timestamp: u64
    }

    struct RewardInfo has store {
        claimable_reward : u64,
        previous_reward_per_share : u64
    }

    struct Vault<phantom Q> has store {
        funds: Balance<Q>, // Total amount of funds in the vault. Includes trader's margin, staker's balance, and fees collected
        shares: u64, // Total ownership shares
        cumulative_reward_per_share: u64,
        fees_outstanding: u64,
        stakes : Table<address, Stake>,
        rewards: Table<address, RewardInfo>,
        can_user_stake: bool,
        utilization_mutliplier: u64,
        max_capacity: u64, // Maximum capacity
        staking_period: u64 // Time required to lock stake (seconds)
    }

    struct Market<phantom B, phantom Q> has store {
        market_settings: MarketSettings,
        market_state: MarketState<B, Q>,
        vault: Vault<Q>,
        oracle: Oracle<B>
    }

    struct MarketSettings has store {
        // global settings
        min_keeper_fee: u64,
        max_keeper_fee: u64,
        liquidation_fee_ratio: u64,
        liquidation_buffer_ratio: u64,
        min_initial_margin: u64,
        // market-specific settings
        taker_fee: u64,
        maker_fee: u64,
        max_leverage: u64,
        max_market_value: u64,
        max_funding_velocity: u64,
        skew_scale: u64,
        liquidation_premium_multiplier: u64
    }

    struct MarketState<phantom B, phantom Q> has store {
        market_size: u64,
        market_skew: u64,
        skew_direction: bool,
        /*
        * This holds the value: sum_{p in positions}{p.margin - p.size * (p.lastPrice + fundingSequence[p.lastFundingIndex])}
        * Then marketSkew * (price + _nextFundingEntry()) + _entryDebtCorrection yields the total system debt,
        * which is equivalent to the sum of remaining margins in all positions.
        */
        entry_debt_correction: u64,
        entry_debt_correction_direction: bool,
        funding_last_recomputed: u64, //timestamp
        funding_sequence: vector<FundingEntry>,
        funding_rate_last_recomputed: FundingEntry,
        positions: Table<address, Position<Q>>,
        position_addresses: vector<address>
    }

    struct FundingEntry has store, drop, copy {
        funding: u64,
        direction: bool
    }

    struct Position<phantom Q> has store {
        last_funding_index: u64,
        margin: u64,
        last_price: u64,
        size: u64,
        direction: bool
    }

    struct Oracle<phantom B> has store {
        price: u64
    }

    fun init(ctx: &mut TxContext) {
        init_helper(ctx);
    }

    fun init_helper(ctx: &mut TxContext) {
        let ownershipCapability = OwnerCap {
            id: object::new(ctx)
        };

        transfer::public_transfer(ownershipCapability,
            tx_context::sender(ctx));

        let gm = GlobalMarkets {
            id: object::new(ctx),
            markets: bag::new(ctx)
        };

        transfer::share_object(gm);
    }

    /* //////////////////////////////////////////////////////////////
                PUBLIC FUNCTIONS (NON-MUT REREFENCES)
    ////////////////////////////////////////////////////////////// */

    // returns the unique market name for the given base and quote asset
    public entry fun get_market_name<B, Q>(): String {
        let market_name = string::utf8(b"");
        string::append_utf8(&mut market_name, into_bytes(into_string(get<B>())));
        string::append_utf8(&mut market_name, b"-");
        string::append_utf8(&mut market_name, into_bytes(into_string(get<Q>())));
        market_name
    }

    public fun market_exists<B, Q>(gm: &GlobalMarkets): bool {
        let market_name = get_market_name<B, Q>();
        bag::contains_with_type<String, Market<B, Q>>(&gm.markets, market_name)
    }

    public fun get_markets(gm: &GlobalMarkets): &Bag {
        &gm.markets
    }

    public fun get_market<B, Q>(gm: &GlobalMarkets): &Market<B, Q> {
        let market_name = get_market_name<B, Q>();
        let market_exists = bag::contains_with_type<String, Market<B, Q>>(&gm.markets, market_name);
        assert!(market_exists, EMarketDoesNotExist);

        let market_name = get_market_name<B, Q>();
        bag::borrow(&gm.markets, market_name)
    }

    public fun get_positions<B, Q>(market: &Market<B, Q>): &Table<address, Position<Q>> {
        &market.market_state.positions
    }

    public fun get_position<B, Q>(market: &Market<B, Q>, account: address): &Position<Q> {
        let position_table = get_positions<B, Q>(market);
        table::borrow(position_table, account)
    }

    public fun position_last_funding_index<Q>(position: &Position<Q>): u64 {
        position.last_funding_index
    }

    public fun position_margin<Q>(position: &Position<Q>): u64 {
        position.margin
    }

    public fun position_last_price<Q>(position: &Position<Q>): u64 {
        position.last_price
    }

    public fun position_size<Q>(position: &Position<Q>): (u64, bool) {
        (position.size, position.direction)
    }

    public fun position_direction<Q>(position: &Position<Q>): bool {
        position.direction
    }

    public fun market_size<B, Q>(market: &Market<B, Q>): u64 {
        market.market_state.market_size
    }

    public fun market_skew<B, Q>(market: &Market<B, Q>): (u64, bool) {
        (market.market_state.market_skew, market.market_state.skew_direction)
    }

    /**
     * Sizes of the long and short sides of the market. ex:
     * size = 10, skew = 2 false => 4 long 6 short
     * size = 10, skew = 2 true => 6 long 4 short
     */
    public fun market_sizes<B, Q>(market: &Market<B, Q>): (u64, u64) {
        let size = market_size<B, Q>(market);
        let (skew, skew_direction) = market_skew<B, Q>(market);
        let (l, _) = utils::add_signed(size, true, skew, skew_direction);
        let (s, _) = utils::subtract_signed(size, true, skew, skew_direction);
        (l / 2, s / 2)
    }

    public fun entry_debt_correction<B, Q>(market: &Market<B, Q>): (u64, bool) {
        (market.market_state.entry_debt_correction, market.market_state.entry_debt_correction_direction)
    }

    public fun funding_last_recomputed<B, Q>(market: &Market<B, Q>): u64 {
        market.market_state.funding_last_recomputed
    }

    public fun latest_funding_index<B, Q>(market: &Market<B, Q>): u64 {
        vector::length(&market.market_state.funding_sequence) - 1
    }

    public fun funding_sequence<B, Q>(market: &Market<B, Q>, index: u64): (u64, bool) {
        let funding_entry = vector::borrow(&market.market_state.funding_sequence, index);
        (funding_entry.funding, funding_entry.direction)
    }

    public fun funding_rate_last_recomputed<B, Q>(market: &Market<B, Q>): (u64, bool) {
        let funding_entry = &market.market_state.funding_rate_last_recomputed;
        (funding_entry.funding, funding_entry.direction)
    }

    // TODO: push to this array somewhere?
    public fun get_position_addresses<B, Q>(market: &Market<B, Q>): &vector<address> {
        &market.market_state.position_addresses
    }

    public fun has_position<B, Q>(market: &Market<B, Q>, account: address): bool {
        let position_table = get_positions<B, Q>(market);
        table::contains(position_table, account)
    }

    /**
     * Returns all data about a position:
     * - last_funding_index, margin, last_price, size, direction
     */
    public fun get_position_data<B, Q>(
        market: &Market<B, Q>,
        account: address
    ): (u64, u64, u64, u64, bool) {
        let has_position = has_position<B, Q>(market, account);
        if (has_position) {
            let position = get_position<B, Q>(market, account);
            (position.last_funding_index, position.margin, position.last_price, position.size, position.direction)
        } else {
            (0, 0, 0, 0, true)
        }
    }

    public fun market_parameters<B, Q>(market: &Market<B, Q>):
        (u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
        let ms = &market.market_settings;
        (
            ms.min_keeper_fee,
            ms.max_keeper_fee,
            ms.liquidation_fee_ratio,
            ms.liquidation_buffer_ratio,
            ms.min_initial_margin,
            ms.taker_fee,
            ms.maker_fee,
            ms.max_leverage,
            ms.max_market_value,
            ms.max_funding_velocity,
            ms.skew_scale,
            ms.liquidation_premium_multiplier
        )
    }

    public fun min_keeper_fee<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.min_keeper_fee
    }

    public fun max_keeper_fee<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.max_keeper_fee
    }

    public fun liquidation_fee_ratio<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.liquidation_fee_ratio
    }

    public fun liquidation_buffer_ratio<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.liquidation_buffer_ratio
    }

    public fun min_initial_margin<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.min_initial_margin
    }

    public fun taker_fee<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.taker_fee
    }

    public fun maker_fee<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.maker_fee
    }

    public fun max_leverage<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.max_leverage
    }

    public fun max_market_value<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.max_market_value
    }

    public fun max_funding_velocity<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.max_funding_velocity
    }

    public fun skew_scale<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.skew_scale
    }

    public fun liquidation_premium_multiplier<B, Q>(market: &Market<B, Q>): u64 {
        market.market_settings.liquidation_premium_multiplier
    }

    public fun oracle_price<B, Q>(market: &Market<B, Q>): u64 {
        market.oracle.price
    }

    /* //////////////////////////////////////////////////////////////
                    FRIEND FUNCTIONS (MUT REREFENCES)
    ////////////////////////////////////////////////////////////// */

    public(friend) fun get_market_mut<B, Q>(gm: &mut GlobalMarkets): &mut Market<B, Q> {
        let market_name = get_market_name<B, Q>();
        let market_exists = bag::contains_with_type<String, Market<B, Q>>(&gm.markets, market_name);
        assert!(market_exists, EMarketDoesNotExist);

        bag::borrow_mut(&mut gm.markets, market_name)
    }

    public(friend) fun get_positions_mut<B, Q>(market: &mut Market<B, Q>): &mut Table<address, Position<Q>> {
        &mut market.market_state.positions
    }

    public(friend) fun get_position_mut<B, Q>(market: &mut Market<B, Q>, account: address): &mut Position<Q> {
        let position_table = get_positions_mut<B, Q>(market);
        table::borrow_mut(position_table, account)
    }

    // TODO: remove this
    public(friend) fun create_empty_position<B, Q>(market: &mut Market<B, Q>, account: address): &mut Position<Q> {
        let position = Position<Q> {
            last_funding_index: 0,
            margin: 0,
            last_price: 0,
            size: 0,
            direction: true
        };

        let position_table = get_positions_mut<B, Q>(market);
        table::add(position_table, account, position);
        table::borrow_mut(position_table, account)
    }

    public(friend) fun push_funding_sequence<B, Q>(market: &mut Market<B, Q>, funding: u64, direction: bool) {
        let funding_entry = FundingEntry {
            funding,
            direction
        };
        vector::push_back(&mut market.market_state.funding_sequence, funding_entry);
    }

    public(friend) fun set_funding_last_recomputed<B, Q>(market: &mut Market<B, Q>, timestamp_ms: u64) {
        market.market_state.funding_last_recomputed = timestamp_ms;
    }

    public(friend) fun set_funding_rate_last_recomputed<B, Q>(market: &mut Market<B, Q>, funding: u64, direction: bool) {
        let funding_entry = FundingEntry {
            funding,
            direction
        };
        market.market_state.funding_rate_last_recomputed = funding_entry;
    }

    public(friend) fun set_entry_debt_correction<B, Q>(
        market: &mut Market<B, Q>,
        entry_debt_correction: u64,
        entry_debt_correction_direction: bool
    ) {
        market.market_state.entry_debt_correction = entry_debt_correction;
        market.market_state.entry_debt_correction_direction = entry_debt_correction_direction;
    }

    public(friend) fun set_market_skew<B, Q>(market: &mut Market<B, Q>, skew: u64, skew_direction: bool) {
        market.market_state.market_skew = skew;
        market.market_state.skew_direction = skew_direction;
    }

    public(friend) fun set_market_size<B, Q>(market: &mut Market<B, Q>, size: u64) {
        market.market_state.market_size = size;
    }

    public(friend) fun update_position<B, Q>(
        market: &mut Market<B, Q>,
        account: address,
        funding_index: u64,
        margin: u64,
        price: u64,
        size: u64,
        direction: bool
    ) {
        let has_position = has_position<B, Q>(market, account);
        if (has_position) {
            let position = get_position_mut<B, Q>(market, account);
            position.last_funding_index = funding_index;
            position.margin = margin;
            position.last_price = price;
            position.size = size;
            position.direction = direction;
        } else {
            // create the position if it doesn't exist
            let position = Position<Q> {
                last_funding_index: funding_index,
                margin,
                last_price: price,
                size,
                direction
            };

            let position_table = get_positions_mut<B, Q>(market);
            table::add(position_table, account, position);
        }
    }

    public(friend) fun add_margin_to_vault<B, Q>(market: &mut Market<B, Q>, margin: Coin<Q>) {
        coin::put<Q>(&mut market.vault.funds, margin);
    }

    public(friend) fun withdraw_margin_from_vault<B, Q>(market: &mut Market<B, Q>, margin: u64, ctx: &mut TxContext): Coin<Q> {
        coin::take<Q>(&mut market.vault.funds, margin, ctx)
    }

    public(friend) fun add_to_cumulative_rewards<Q>(coin_amount: u64, vault: &mut Vault<Q>) {
        //Get total vault shares
        let shares = get_vault_shares(vault);

        //Get vault cumulative rewards per share and use that to set updated calc for cumulative rewards per share
        let cumulative_reward_per_share = get_vault_cumulative_rewards_per_share<Q>(vault);
        set_vault_cumulative_rewards_per_share<Q>(vault, cumulative_reward_per_share + utils::divide_decimal(coin_amount, shares));

        //Get vault outstanding fees and use that to set updated calc for outstanding fees
        let fees_outstanding = get_vault_fees_outstanding<Q>(vault);
        set_vault_fees_outstanding<Q>(vault, fees_outstanding + coin_amount);
    }

    // TODO: remove this
    public(friend) fun set_oracle_price<B, Q>(
        price: u64,
        market: &mut Market<B, Q>
    ) {
        market.oracle.price = price;
    }

    /* //////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    ////////////////////////////////////////////////////////////// */

    // adds market for given base_asset (ex. ETH/BTC) and quote asset (ex. USDC)
    public entry fun add_market<B, Q>(
        oc: &OwnerCap,
        gm: &mut GlobalMarkets,
        ctx: &mut TxContext
    ) {
        let market_name = get_market_name<B, Q>();
        // make sure this market doesn't already exist
        let market_exists = bag::contains_with_type<String, Market<B, Q>>(&gm.markets, market_name);
        assert!(!market_exists, EMarketAlreadyExists);

        let market_settings = MarketSettings {
            min_keeper_fee: 0,
            max_keeper_fee: 0,
            liquidation_fee_ratio: 0,
            liquidation_buffer_ratio: 0,
            min_initial_margin: 0,
            taker_fee: 0,
            maker_fee: 0,
            max_leverage: 0,
            max_market_value: 0,
            max_funding_velocity: 0,
            skew_scale: 0,
            liquidation_premium_multiplier: 0
        };

        let initial_funding_entry = FundingEntry { funding: 0, direction: true };

        let market_state = MarketState<B, Q> {
            market_size: 0,
            market_skew: 0,
            skew_direction: true,
            entry_debt_correction: 0,
            entry_debt_correction_direction: true,
            funding_last_recomputed: 0,
            funding_sequence: vector::empty<FundingEntry>(),
            funding_rate_last_recomputed: initial_funding_entry,
            positions: table::new(ctx),
            position_addresses: vector::empty<address>()
        };

        // push the first funding entry
        // TODO: should this be a reference instead of copy?
        vector::push_back(&mut market_state.funding_sequence, copy initial_funding_entry);

        //add the vault settings
        let stakes = table::new(ctx);
        let rewards = table::new(ctx);
        let vault = Vault<Q> {
            funds: balance::zero<Q>(),
            shares: 0,
            cumulative_reward_per_share: 0,
            utilization_mutliplier: 2,
            fees_outstanding: 0,
            stakes,
            rewards,
            can_user_stake: false,
            max_capacity : 1000000 * ONE_UNIT,
            staking_period : 10000
        };

        // start the price at $2000. TODO: remove this
        let price = 2000 * 1_000_000_000;
        let oracle = Oracle<B> {
            price
        };

        let market = Market<B, Q> {
            market_settings,
            market_state,
            vault,
            oracle
        };
        bag::add(&mut gm.markets, market_name, market);

        // set some default market parameters
        // TODO delete when ready
        set_market_parameters<B, Q>(oc, gm,
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
    

    public entry fun set_market_parameters<B, Q>(
        _oc: &OwnerCap,
        gm: &mut GlobalMarkets,
        min_keeper_fee: u64,
        max_keeper_fee: u64,
        liquidation_fee_ratio: u64,
        liquidation_buffer_ratio: u64,
        min_initial_margin: u64,
        taker_fee: u64,
        maker_fee: u64,
        max_leverage: u64,
        max_market_value: u64,
        max_funding_velocity: u64,
        skew_scale: u64,
        liquidation_premium_multiplier: u64
    ) {
        let market = get_market_mut<B, Q>(gm);
        let ms = &mut market.market_settings;
        ms.min_keeper_fee = min_keeper_fee;
        ms.max_keeper_fee = max_keeper_fee;
        ms.liquidation_fee_ratio = liquidation_fee_ratio;
        ms.liquidation_buffer_ratio = liquidation_buffer_ratio;
        ms.min_initial_margin = min_initial_margin;
        ms.taker_fee = taker_fee;
        ms.maker_fee = maker_fee;
        ms.max_leverage = max_leverage;
        ms.max_market_value = max_market_value;
        ms.max_funding_velocity = max_funding_velocity;
        ms.skew_scale = skew_scale;
        ms.liquidation_premium_multiplier = liquidation_premium_multiplier;
    }

    /* //////////////////////////////////////////////////////////////
                STAKE PUBLIC FUNCTIONS (NON-MUT REREFENCES)
    ////////////////////////////////////////////////////////////// */

    public fun can_user_stake<Q>(vault: &Vault<Q>) : bool {
        vault.can_user_stake
    }

    public fun get_vault_funds<Q>(vault: &Vault<Q>): u64 {
        balance::value(&vault.funds)
    }

    public fun get_vault_max_capacity<Q>(vault: &Vault<Q>): u64 {
        vault.max_capacity
    }

    public fun get_vault_staking_period<Q>(vault: &Vault<Q>): u64 {
        vault.staking_period
    }

    public fun get_user_amount_from_stakes(stakes: &Table<address,Stake>, addr: address) : u64 {
        let user_stake = table::borrow(stakes, addr);
        user_stake.amount
    }

    public fun get_user_shares_from_stakes(stakes: &Table<address,Stake>, addr: address) : u64 {
        let user_stake = table::borrow(stakes, addr);
        user_stake.shares
    }

    public fun get_timestamp_from_user_stake(user_stake: &Stake) : u64 {
        user_stake.timestamp
    }

    public fun vault_parameters<Q>(vault: &Vault<Q>):
        (u64, u64, u64, u64, bool, u64, u64, u64) {
        (
            balance::value(&vault.funds),
            vault.shares,
            vault.cumulative_reward_per_share,
            vault.fees_outstanding,
            vault.can_user_stake,
            vault.utilization_mutliplier,
            vault.max_capacity,
            vault.staking_period
        )
    }
       
    public fun get_shares_in_user_stake(user_stake: &Stake) : u64 {
        user_stake.shares
    }

    public fun get_amount_in_user_stake(user_stake: &Stake) : u64 {
        user_stake.amount
    }

    public fun get_user_stake(stakes: &Table<address,Stake>, addr : address) : &Stake {
        let user_stake = table::borrow(stakes, addr);
        user_stake
    }

    public fun get_user_reward_info<Q>(vault: &Vault<Q>, addr : address) : &RewardInfo {
        let rewards = &vault.rewards;
        let reward_info = table::borrow(rewards, addr);
        reward_info
    }

    public fun get_user_reward_claimable_reward(reward_info: &RewardInfo) : u64 {
        reward_info.claimable_reward
    }

    public fun get_user_reward_previous_reward_per_share(reward_info: &RewardInfo) : u64 {
        reward_info.previous_reward_per_share
    }

    public fun get_vault_fees_outstanding<Q>(vault: &Vault<Q>) : u64 {
        vault.fees_outstanding
    }

    public fun get_vault_shares<Q>(
        vault: &Vault<Q>
    ): u64 {
        vault.shares
    }

    public fun get_vault_cumulative_rewards_per_share<Q>(
        vault: &Vault<Q>
    ): u64 {
        vault.cumulative_reward_per_share
    }

    public fun get_vault_stakes<Q>(
        vault: &Vault<Q>
    ): &Table<address, Stake> {
        &vault.stakes
    }

    public fun get_vault<B, Q>(market: &Market<B, Q>) : &Vault<Q> {
       &market.vault
    }

    public fun get_vault_rewards<Q>(vault: &Vault<Q>) : &Table<address, RewardInfo> {
       &vault.rewards
    }

    /* //////////////////////////////////////////////////////////////
                    STAKE FRIEND FUNCTIONS (MUT REREFENCES)
    ////////////////////////////////////////////////////////////// */

    public(friend) fun create_stake(owner: address, amount: u64, shares: u64, timestamp: u64) : Stake {
        let stake = Stake {
            owner,
            amount,
            shares,
            timestamp
        };
        stake
    }

    public(friend) fun create_reward(previous_reward_per_share: u64, claimable_reward: u64) : RewardInfo {
        let reward_info = RewardInfo {
            previous_reward_per_share,
            claimable_reward
        };
        reward_info
    }
    
    public(friend) fun get_vault_funds_mut<Q>(vault: &mut Vault<Q>): &mut Balance<Q> {
        &mut vault.funds
    }

    public fun get_vault_utilization_multiplier<Q>(vault: &Vault<Q>): u64 {
        vault.utilization_mutliplier
    }

    public fun get_user_stake_mut(stakes: &mut Table<address,Stake>, addr : address) : &mut Stake {
        let userStake = table::borrow_mut(stakes, addr);
        userStake
    }

    public fun get_user_reward_info_mut<Q>(vault: &mut Vault<Q>, addr : address) : &mut RewardInfo {
        let rewards = &mut vault.rewards;
        let rewardInfo = table::borrow_mut(rewards, addr);
        rewardInfo
    }
       
    public fun get_vault_stakes_mut<Q>(
        vault: &mut Vault<Q>
    ): &mut Table<address, Stake> {
        &mut vault.stakes
    }

    public fun get_vault_rewards_mut<Q>(vault: &mut Vault<Q>) : &mut Table<address, RewardInfo> {
       &mut vault.rewards
    }

    public fun get_vault_mut<B, Q>(market: &mut Market<B, Q>) : &mut Vault<Q> {
       &mut market.vault
    }

    public fun set_shares_in_user_stake(user_stake: &mut Stake, val: u64) {
        user_stake.shares = val;
    }

    public fun set_timestamp_in_user_stake(user_stake: &mut Stake, val: u64) {
        user_stake.timestamp = val;
    }

    public fun set_amount_in_user_stake(user_stake: &mut Stake, val: u64) {
        user_stake.amount = val;
    }

    public fun set_user_reward_claimable_reward(rewardInfo: &mut RewardInfo, val : u64) {
        rewardInfo.claimable_reward = val;
    }

    public fun set_vault_fees_outstanding<Q>(vault: &mut Vault<Q>, val : u64) {
        vault.fees_outstanding = val;
    }

    public fun set_vault_shares<Q>(vault: &mut Vault<Q>, val : u64) {
        vault.shares = val;
    }

    public fun set_user_reward_previous_reward_per_share(reward_info: &mut RewardInfo, val : u64) {
        reward_info.previous_reward_per_share = val
    }

    public fun set_vault_cumulative_rewards_per_share<Q>(vault: &mut Vault<Q>, val : u64) {
        vault.cumulative_reward_per_share = val;
    }

    public entry fun set_can_user_stake<B, Q>(_o: &OwnerCap, gm: &mut GlobalMarkets, val: bool) {
        let market = get_market_mut<B, Q>(gm);
        let vs = get_vault_mut<B, Q>(market);
        vs.can_user_stake = val;
    }

    #[test_only]
    /// Wrapper of module initializer for testing
    public fun test_init(ctx: &mut TxContext) {
        init_helper(ctx);
    }

    #[test_only]
    public fun set_oracle_price_test<B, Q>(
        price: u64,
        gm: &mut GlobalMarkets
    ) {
        let market = get_market_mut<B, Q>(gm);
        set_oracle_price(price, market);
    }

}
