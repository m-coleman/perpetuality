module perp::market {

    use sui::tx_context::{Self, TxContext};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};

    use perp::market_manager::{Self, GlobalMarkets};
    use perp::market_base;

    // public entry fun withdraw_margin(
    //     margin: u64,
    //     ctx: &mut TxnContext
    // ) {

    // }

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
}
