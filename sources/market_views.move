module perp::market_views {

    use std::vector;

    use perp::market_manager::{Self, GlobalMarkets};
    use perp::market_base;
    use perp::vault::{Self};
    use sui::clock::{Self, Clock};

    // TODO: remove this, it's just to play with on frontend
    public entry fun set_oracle_price<B, Q>(
        price: u64,
        gm: &mut GlobalMarkets
    ) {
        let market_mut = market_manager::get_market_mut<B, Q>(gm);
        market_manager::set_oracle_price<B, Q>(price, market_mut);
    }

    public entry fun market_size<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::market_size<B, Q>(market)
    }

    public entry fun market_skew<B, Q>(gm: &GlobalMarkets): (u64, bool) {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::market_skew<B, Q>(market)
    }

    public entry fun market_sizes<B, Q>(gm: &GlobalMarkets): (u64, u64) {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::market_sizes<B, Q>(market)
    }

    public entry fun market_debt<B, Q>(gm: &GlobalMarkets, clock: &Clock): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        market_base::market_debt<B, Q>(market, timestamp_ms)
    }

    public entry fun entry_debt_correction<B, Q>(gm: &GlobalMarkets): (u64, bool) {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::entry_debt_correction<B, Q>(market)
    }

    public entry fun funding_last_recomputed<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::funding_last_recomputed<B, Q>(market)
    }

    public entry fun latest_funding_index<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::latest_funding_index<B, Q>(market)
    }

    public entry fun funding_sequence<B, Q>(gm: &GlobalMarkets, index: u64): (u64, bool) {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::funding_sequence<B, Q>(market, index)
    }

    public entry fun funding_rate_last_recomputed<B, Q>(gm: &GlobalMarkets): (u64, bool) {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::funding_rate_last_recomputed<B, Q>(market)
    }

    public entry fun unrecorded_funding<B, Q>(gm: &GlobalMarkets, clock: &Clock): (u64, bool) {
        let market = market_manager::get_market<B, Q>(gm);
        let oracle_price = market_base::asset_price_require_system_checks<B, Q>(market);
        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        market_base::unrecorded_funding<B, Q>(market, oracle_price, timestamp_ms)
    }

    public entry fun next_funding_entry<B, Q>(gm: &GlobalMarkets, clock: &Clock): (u64, bool) {
        let market = market_manager::get_market<B, Q>(gm);
        let oracle_price = market_base::asset_price_require_system_checks<B, Q>(market);
        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        market_base::next_funding_entry<B, Q>(market, oracle_price, timestamp_ms)
    }

    public entry fun get_position_addresses_length<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        let position_addresses: &vector<address> = market_manager::get_position_addresses<B, Q>(market);
        vector::length(position_addresses)
    }

    public entry fun get_position_addresses_at_index<B, Q>(gm: &GlobalMarkets, index: u64): address {
        let market = market_manager::get_market<B, Q>(gm);
        let position_addresses: &vector<address> = market_manager::get_position_addresses<B, Q>(market);
        *vector::borrow(position_addresses, index)
    }

    public entry fun has_position<B, Q>(gm: &GlobalMarkets, account: address): bool {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::has_position<B, Q>(market, account)
    }

    /**
     * Returns all data about a position:
     * - last_funding_index, margin, last_price, size, direction
     */
    public entry fun get_position_data<B, Q>(
        gm: &GlobalMarkets,
        account: address
    ): (u64, u64, u64, u64, bool) {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::get_position_data<B, Q>(market, account)
    }

    /**
     * Returns:
        - min_keeper_fee
        - max_keeper_fee
        - liquidation_fee_ratio
        - liquidation_buffer_ratio
        - min_initial_margin
        - taker_fee
        - maker_fee
        - max_leverage
        - max_market_value
        - max_funding_velocity
        - skew_scale
        - liquidation_premium_multiplier
     */
    public entry fun market_parameters<B, Q>(gm: &GlobalMarkets):
        (u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64, u64) {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::market_parameters<B, Q>(market)
    }

    public entry fun min_keeper_fee<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::min_keeper_fee<B, Q>(market)
    }

    public entry fun max_keeper_fee<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::max_keeper_fee<B, Q>(market)
    }

    public entry fun liquidation_fee_ratio<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::liquidation_fee_ratio<B, Q>(market)
    }

    public entry fun liquidation_buffer_ratio<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::liquidation_buffer_ratio<B, Q>(market)
    }

    public entry fun min_initial_margin<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::min_initial_margin<B, Q>(market)
    }

    public entry fun taker_fee<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::taker_fee<B, Q>(market)
    }

    public entry fun maker_fee<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::maker_fee<B, Q>(market)
    }

    public entry fun max_leverage<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::max_leverage<B, Q>(market)
    }

    public entry fun max_market_value<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::max_market_value<B, Q>(market)
    }

    public entry fun max_funding_velocity<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::max_funding_velocity<B, Q>(market)
    }

    public entry fun skew_scale<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::skew_scale<B, Q>(market)
    }

    public entry fun liquidation_premium_multiplier<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::liquidation_premium_multiplier<B, Q>(market)
    }

    public entry fun oracle_price<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        market_manager::oracle_price<B, Q>(market)
    }

    public entry fun fill_price<B, Q>(gm: &GlobalMarkets, size: u64, size_direction: bool): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        let oracle_price = market_base::asset_price_require_system_checks<B, Q>(market);
        market_base::fill_price<B, Q>(market, size, size_direction, oracle_price)
    }

    public entry fun order_fee<B, Q>(gm: &GlobalMarkets, size: u64, size_direction: bool): u64 {
        let fill_price = fill_price<B, Q>(gm, size, size_direction);
        let market = market_manager::get_market<B, Q>(gm);
        let maker_fee = market_manager::maker_fee<B, Q>(market);
        let taker_fee = market_manager::taker_fee<B, Q>(market);
        let (skew, skew_direction) = market_manager::market_skew<B, Q>(market);
        market_base::order_fee(
            skew,
            skew_direction,
            size,
            size_direction,
            fill_price,
            taker_fee,
            maker_fee
        )
    }

    public entry fun remaining_margin<B, Q>(gm: &GlobalMarkets, clock: &Clock, account: address): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        let oracle_price = market_base::asset_price_require_system_checks<B, Q>(market);
        market_base::margin_plus_profit_funding<B, Q>(market, oracle_price, account, timestamp_ms)
    }

    public entry fun profit_loss<B, Q>(gm: &GlobalMarkets, account: address): (u64, bool) {
        let market = market_manager::get_market<B, Q>(gm);
        let oracle_price = market_base::asset_price_require_system_checks<B, Q>(market);
        market_base::profit_loss<B, Q>(market, oracle_price, account)
    }

    public entry fun current_leverage<B, Q>(gm: &GlobalMarkets, clock: &Clock, account: address): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        let (_, _, _, position_size, _) = market_manager::get_position_data<B, Q>(market, account);
        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        let oracle_price = market_base::asset_price_require_system_checks<B, Q>(market);
        let remaining_margin = market_base::margin_plus_profit_funding<B, Q>(market, oracle_price, account, timestamp_ms);
        market_base::current_leverage(position_size, oracle_price, remaining_margin)
    }

    // Vault views

    public entry fun user_shares_from_stakes<B, Q>(gm: &GlobalMarkets, addr: address) : u64 {
        let market = market_manager::get_market<B, Q>(gm);
        let vault = market_manager::get_vault<B, Q>(market);
        let stakes = market_manager::get_vault_stakes<Q>(vault);
        market_manager::get_user_shares_from_stakes(stakes, addr)
    }

    public entry fun vault_max_capacity<B, Q>(gm: &GlobalMarkets): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        let vault = market_manager::get_vault<B, Q>(market);
        market_manager::get_vault_max_capacity<Q>(vault)
    }

    public entry fun vault_parameters<B, Q>(gm: &GlobalMarkets): 
        (u64, u64, u64, u64, bool, u64, u64, u64) {
        let market = market_manager::get_market<B, Q>(gm);
        let vault = market_manager::get_vault<B, Q>(market);
        market_manager::vault_parameters<Q>(vault)
    }

    public entry fun vault_net_balance<B, Q>(gm: &GlobalMarkets, clock: &Clock): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        vault::get_vault_net_balance<B, Q>(market, clock)
    }

    //Get the real-time claimable rewards for this user
    public entry fun get_claimable_reward<B, Q>(gm: &GlobalMarkets, addr: address): u64 {
        let market = market_manager::get_market<B, Q>(gm);
        let vault = market_manager::get_vault<B, Q>(market);
        vault::get_claimable_reward<Q>(vault, addr)
    }

    public entry fun can_user_stake<B, Q>(gm: &GlobalMarkets) : bool {
        let market = market_manager::get_market<B, Q>(gm);
        let vault = market_manager::get_vault<B, Q>(market);
        market_manager::can_user_stake<Q>(vault)
    }

}
