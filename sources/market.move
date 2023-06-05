module perp::market {

    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::transfer;

    use perp::market_manager::{Self, GlobalMarkets};
    use perp::market_base;

    const ENoPosition: u64 = 0;

    public entry fun withdraw_all_margin<B, Q>(
        gm: &mut GlobalMarkets,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let msg_sender = tx_context::sender(ctx);
        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        let price: u64;
        {
            // get base asset price
            let market = market_manager::get_market<B, Q>(gm);
            price = market_base::asset_price_require_system_checks<B, Q>(market);
        };

        let accessible_margin: u64;
        {
            // calculate accessible margin
            let market = market_manager::get_market<B, Q>(gm);
            accessible_margin = market_base::accessible_margin<B, Q>(market, price, msg_sender, timestamp_ms);
        };

        // withdraw all accessible margin
        withdraw_margin<B, Q>(accessible_margin, gm, clock, ctx);
    }

    public entry fun withdraw_margin<B, Q>(
        margin: u64,
        gm: &mut GlobalMarkets,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let msg_sender = tx_context::sender(ctx);
        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        let price: u64;
        {
            // get base asset price
            let market = market_manager::get_market<B, Q>(gm);
            price = market_base::asset_price_require_system_checks<B, Q>(market);
        };

        {
            // compute funding
            let market_mut = market_manager::get_market_mut<B, Q>(gm);
            market_base::recompute_funding<B, Q>(market_mut, price, timestamp_ms);
        };

        {
            // withdraw the margin from the vault
            let market_mut = market_manager::get_market_mut<B, Q>(gm);
            let margin_coin: Coin<Q> = market_manager::withdraw_margin_from_vault<B, Q>(market_mut, margin, ctx);
            // transfer the margin coin back to the user
            transfer::public_transfer(margin_coin, msg_sender);

            // remove margin from the position
            market_base::update_position_margin<B, Q>(market_mut, price, margin, false, msg_sender, timestamp_ms);
        };
    }

    public entry fun modify_position<B, Q>(
        size_delta: u64,
        size_delta_direction: bool,
        price_impact_delta: u64,
        margin: Coin<Q>,
        gm: &mut GlobalMarkets,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let msg_sender = tx_context::sender(ctx);
        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        let price: u64;
        {
            // get base asset price
            let market = market_manager::get_market<B, Q>(gm);
            price = market_base::asset_price_require_system_checks<B, Q>(market);
        };

        {
            // compute funding
            let market_mut = market_manager::get_market_mut<B, Q>(gm);
            market_base::recompute_funding<B, Q>(market_mut, price, timestamp_ms);
        };

        let margin_value = coin::value<Q>(&margin);
        {
            // transfer margin logic
            let market_mut = market_manager::get_market_mut<B, Q>(gm);
            // add the margin to the vault
            // always need to do this (even if margin_value = 0) because Coin can't be dropped
            market_manager::add_margin_to_vault<B, Q>(market_mut, margin);
            // add margin to the position
            market_base::update_position_margin<B, Q>(market_mut, price, margin_value, true, msg_sender, timestamp_ms);
        };

        // modify position logic
        if (size_delta > 0) {
            let market_mut = market_manager::get_market_mut<B, Q>(gm);
            let fill_price = market_base::fill_price<B, Q>(market_mut, size_delta, size_delta_direction, price);
            market_base::trade<B, Q>(
                market_mut,
                size_delta,
                size_delta_direction,
                price,
                fill_price,
                price_impact_delta,
                msg_sender,
                timestamp_ms
            )
        };
    }

    public entry fun close_position<B, Q>(
        price_impact_delta: u64,
        gm: &mut GlobalMarkets,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let msg_sender = tx_context::sender(ctx);
        let pos_size: u64;
        let pos_direction: bool;
        {
            // make sure the user has a position
            let market = market_manager::get_market<B, Q>(gm);
            (_, _, _, pos_size, pos_direction) = market_manager::get_position_data<B, Q>(market, msg_sender);
            assert!(pos_size > 0, ENoPosition);
        };

        let timestamp_ms: u64 = clock::timestamp_ms(clock);
        let price: u64;
        {
            // get base asset price
            let market = market_manager::get_market<B, Q>(gm);
            price = market_base::asset_price_require_system_checks<B, Q>(market);
        };

        {
            // compute funding
            let market_mut = market_manager::get_market_mut<B, Q>(gm);
            market_base::recompute_funding<B, Q>(market_mut, price, timestamp_ms);
        };

        {
            // close the position
            let market_mut = market_manager::get_market_mut<B, Q>(gm);
            // direction is opposite (to completely close the position)
            let close_direction = !pos_direction;
            let fill_price = market_base::fill_price<B, Q>(market_mut, pos_size, close_direction, price);
            market_base::trade<B, Q>(
                market_mut,
                pos_size,
                close_direction,
                price,
                fill_price,
                price_impact_delta,
                msg_sender,
                timestamp_ms
            )
        };

        {
            // withdraw all margin
            withdraw_all_margin<B, Q>(gm, clock, ctx);
        };
    }
}
