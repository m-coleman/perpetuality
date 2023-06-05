module perp::market_base {

    use perp::market_manager::{Self, Market};
    use perp::exchange_rates;
    use perp::utils;

    friend perp::market;

    const ONE_UNIT: u64 = 1_000_000_000;
    const ONE_DAY_IN_MS: u64 = 86_400_000;

    const ECanLiquidate: u64 = 1;
    const ECannotLiquidate: u64 = 2;
    const EMaxMarketSizeExceeded: u64 = 3;
    const EMaxLeverageExceeded: u64 = 4;
    const EInsufficientMargin: u64 = 5;
    const ENotPermitted: u64 = 6;
    const ENilOrder: u64 = 7;
    const ENoPositionOpen: u64 = 8;
    const EPriceImpactToleranceExceeded: u64 = 9;

    public fun asset_price_require_system_checks<B, Q>(market: &Market<B, Q>): u64 {
        let (rate, _broken, _valid) = exchange_rates::rate_with_safety_checks<B, Q>(market);
        // TODO: check broken/valid
        rate
    }

    public(friend) fun recompute_funding<B, Q>(market: &mut Market<B, Q>, price: u64, timestamp_ms: u64) {
        let (curr_funding, curr_funding_direction) = current_funding_rate<B, Q>(market, timestamp_ms);
        let (next_funding, next_funding_direction) = next_funding_entry<B, Q>(market, price, timestamp_ms);
        market_manager::push_funding_sequence<B, Q>(market, next_funding, next_funding_direction);
        market_manager::set_funding_last_recomputed<B, Q>(market, timestamp_ms);
        market_manager::set_funding_rate_last_recomputed<B, Q>(market, curr_funding, curr_funding_direction);
    }

    public(friend) fun update_position_margin<B, Q>(
        market: &mut Market<B, Q>,
        price: u64,
        margin_delta: u64,
        margin_delta_direction: bool,
        msg_sender: address,
        timestamp_ms: u64
    ) {
        let new_margin = recompute_margin_with_delta<B, Q>(
            market,
            price,
            margin_delta,
            margin_delta_direction,
            msg_sender,
            timestamp_ms
        );

        let (pos_lfi, pos_margin, pos_last_price, pos_size, pos_direction) = market_manager::get_position_data<B, Q>(market, msg_sender);
        let funding_index = market_manager::latest_funding_index<B, Q>(market);
        apply_debt_correction<B, Q>(
            market,
            funding_index, // new position parameters
            new_margin,
            price,
            pos_size,
            pos_lfi, // old position parameters
            pos_margin,
            pos_last_price,
            pos_size
        );

        // We only need to update their funding/PnL details if they actually have a position open
        if (pos_size > 0) {
            // The user can always decrease their margin if they have no position, or as long as:
            //   * they have sufficient margin to do so
            //   * the resulting margin would not be lower than the liquidation margin or min initial margin
            //     * liq_margin accounting for the liq_premium
            //   * the resulting leverage is lower than the maximum leverage
            if (!margin_delta_direction) {
                // note: We add `liq_premium` to increase the req margin to avoid entering into liquidation
                let liq_premium = liquidation_premium<B, Q>(market, pos_size, price);
                let liq_margin = liq_premium + liquidation_margin<B, Q>(market, pos_size, price);
                let curr_leverage = current_leverage(pos_size, price, new_margin);
                let max_leverage = market_manager::max_leverage<B, Q>(market);
                let min_initial_margin = market_manager::min_initial_margin<B, Q>(market);
                let below_min_margin = new_margin < min_initial_margin;
                let at_or_below_liq_margin = new_margin <= liq_margin;
                let above_max_leverage = curr_leverage > max_leverage;
                assert!(!below_min_margin && !at_or_below_liq_margin && !above_max_leverage, EInsufficientMargin);
            };
        };

        market_manager::update_position<B, Q>(
            market,
            msg_sender,
            funding_index,
            new_margin,
            price,
            pos_size,
            pos_direction
        );
    }

    /**
     * Returns price at which a trade is executed. If the size contracts the skew, then a discount
     * is applied on the price, whereas expanding the skew incurs an additional premium.
     */
    public fun fill_price<B, Q>(market: &Market<B, Q>, size: u64, size_direction: bool, price: u64): u64 {
        let (skew, skew_direction) = market_manager::market_skew<B, Q>(market);
        let skew_scale = market_manager::skew_scale<B, Q>(market);
        // TODO: do anything with new_skew_direction here?
        let (new_skew, _) = utils::add_signed(skew, skew_direction, size, size_direction);

        let pd_before = utils::divide_decimal(skew, skew_scale);
        let pd_after = utils::divide_decimal(new_skew, skew_scale);
        let price_before = price + utils::multiply_decimal(price, pd_before);
        let price_after = price + utils::multiply_decimal(price, pd_after);

        // How is the p/d-adjusted price calculated using an example:
        //
        // price      = $1200 USD (oracle)
        // size       = 100
        // skew       = 0
        // skew_scale = 1,000,000 (1M)
        //
        // Then,
        //
        // pd_before = 0 / 1,000,000
        //           = 0
        // pd_after  = (0 + 100) / 1,000,000
        //           = 100 / 1,000,000
        //           = 0.0001
        //
        // price_before = 1200 * (1 + pd_before)
        //              = 1200 * (1 + 0)
        //              = 1200
        // price_after  = 1200 * (1 + pd_after)
        //              = 1200 * (1 + 0.0001)
        //              = 1200 * (1.0001)
        //              = 1200.12
        // Finally,
        //
        // fill_price = (price_before + price_after) / 2
        //            = (1200 + 1200.12) / 2
        //            = 1200.06

        utils::divide_decimal(price_before + price_after, ONE_UNIT * 2)
    }

    public(friend) fun trade<B, Q>(
        market: &mut Market<B, Q>,
        size_delta: u64,
        size_delta_direction: bool,
        oracle_price: u64,
        fill_price: u64,
        price_impact_delta: u64,
        msg_sender: address,
        timestamp_ms: u64
    ) {
        let (old_pos_lfi, old_pos_margin, old_pos_last_price, old_pos_size, old_pos_direction) = market_manager::get_position_data<B, Q>(market, msg_sender);
        let (new_pos_margin, new_pos_size, new_pos_direction, fee) = post_trade_details<B, Q>(market, size_delta, size_delta_direction, oracle_price, fill_price, msg_sender, timestamp_ms);
        let new_pos_lfi = market_manager::latest_funding_index<B, Q>(market);

        assert_price_impact(oracle_price, fill_price, price_impact_delta, size_delta_direction);

        // update the market skew
        let (skew, skew_direction) = market_manager::market_skew<B, Q>(market);
        let (skew_minus_old, skew_minus_old_direction) = utils::subtract_signed(skew, skew_direction, old_pos_size, old_pos_direction);
        let (new_skew, new_skew_direction) = utils::add_signed(skew_minus_old, skew_minus_old_direction, new_pos_size, new_pos_direction);
        market_manager::set_market_skew<B, Q>(market, new_skew, new_skew_direction);

        // update the market size
        let curr_market_size = market_manager::market_size<B, Q>(market);
        let new_market_size = utils::sub(curr_market_size, old_pos_size) + new_pos_size;
        market_manager::set_market_size<B, Q>(market, new_market_size);

        if (fee > 0) {
            // Send the fee to the vault
            // The fee has already been subtracted out of the user's position margin, so they can't access it anymore,
            // we are just shuffling numbers around in the vault
            let vault = market_manager::get_vault_mut<B, Q>(market);
            market_manager::add_to_cumulative_rewards<Q>(fee, vault);
            // TODO: emit event
        };

        // apply the result debt correction
        apply_debt_correction<B, Q>(
            market,
            new_pos_lfi, // new position parameters
            new_pos_margin,
            oracle_price, // TODO: why does synthetix use fill price here?
            new_pos_size,
            old_pos_lfi, // old position parameters
            old_pos_margin,
            old_pos_last_price,
            old_pos_size
        );

        // TODO: delete the position if size is 0?

        // update the position
        market_manager::update_position<B, Q>(
            market,
            msg_sender,
            new_pos_lfi,
            new_pos_margin,
            fill_price,
            new_pos_size,
            new_pos_direction
        );

        // TODO: emit the position modified event
    }

    public(friend) fun accessible_margin<B, Q>(
        market: &Market<B, Q>,
        price: u64,
        msg_sender: address,
        timestamp_ms: u64
    ): u64 {
        // Ugly solution to rounding safety: leave up to an extra tenth of a cent in the account/leverage
        // This should guarantee that the value returned here can always be withdrawn, but there may be
        // a little extra actually-accessible value left over, depending on the position size and margin.
        let milli = ONE_UNIT / 1000;
        let max_leverage = market_manager::max_leverage<B, Q>(market) - milli;
        let (_, _, _, pos_size, pos_direction) = market_manager::get_position_data<B, Q>(market, msg_sender);
        let (notional, _) = notional_value(pos_size, pos_direction, price);

        // If the user has a position open, we'll enforce a min initial margin requirement.
        let inaccessible = utils::divide_decimal(notional, max_leverage);
        if (inaccessible > 0) {
            let min_initial_margin = market_manager::min_initial_margin<B, Q>(market);
            if (inaccessible < min_initial_margin) {
                inaccessible = min_initial_margin;
            };

            inaccessible = inaccessible + milli;
        };

        let remaining = margin_plus_profit_funding<B, Q>(market, price, msg_sender, timestamp_ms);
        if (remaining <= inaccessible) {
            0
        } else {
            utils::sub(remaining, inaccessible)
        }
    }

    fun assert_price_impact(
        oracle_price: u64,
        fill_price: u64,
        price_impact_delta: u64,
        size_delta_direction: bool
    ): u64 {
        let price_impact_limit = price_impact_limit(oracle_price, price_impact_delta, size_delta_direction);
        let price_impact_exceeded = if (size_delta_direction) {
            fill_price > price_impact_limit
        } else {
            fill_price < price_impact_limit
        };

        // make sure price limit was not exceeded
        assert!(!price_impact_exceeded, EPriceImpactToleranceExceeded);
        price_impact_limit
    }

    /**
     * Given the current oracle price (not fill_price) and price_impact_delta, return the max price_impact_delta
     * price which is a price that is inclusive of the price_impact_delta tolerance.
     *
     * For instance, if price ETH is $1000 and price_impact_delta is 1% then max_price_impact is $1010. The fillPrice
     * on the trade must be below $1010 for the trade to succeed.
     *
     * For clarity when price_impact_delta is:
     *  0.1   then 10%
     *  0.01  then 1%
     *  0.001 then 0.1%
     *
     * When price is $1000, I long, and price_impact_delta is:
     *  0.1   then price * (1 + 0.1)   = 1100
     *  0.01  then price * (1 + 0.01)  = 1010
     *  0.001 then price * (1 + 0.001) = 1001
     *
     * When same but short then,
     *  0.1   then price * (1 - 0.1)   = 900
     *  0.01  then price * (1 - 0.01)  = 990
     *  0.001 then price * (1 - 0.001) = 999
     *
     * This forms the limit at which the fill_price can reach before we revert the trade.
     */
    fun price_impact_limit(
        oracle_price: u64,
        price_impact_delta: u64,
        size_delta_direction: bool
    ): u64 {
        // A lower price would be less desirable for shorts and a higher price is less desirable for longs. As such
        // we derive the maxPriceImpact based on whether the position is going long/short.
        if (size_delta_direction) {
            utils::multiply_decimal(oracle_price, ONE_UNIT + price_impact_delta)
        } else {
            utils::multiply_decimal(oracle_price, utils::sub(ONE_UNIT, price_impact_delta))
        }
    }

    // returns new_pos_margin, new position size, new position direction, fee
    fun post_trade_details<B, Q>(
        market: &mut Market<B, Q>,
        size_delta: u64,
        size_delta_direction: bool,
        oracle_price: u64,
        fill_price: u64,
        msg_sender: address,
        timestamp_ms: u64
    ): (u64, u64, bool, u64) {
        let (_, _, _, old_pos_size, old_pos_direction) = market_manager::get_position_data<B, Q>(market, msg_sender);
        // cannot submit a size-zero order
        assert!(size_delta > 0, ENilOrder);
        let can_liquidate = can_liquidate<B, Q>(market, oracle_price, msg_sender, timestamp_ms);
        // order not submitted if user's existing position needs to be liquidated
        assert!(!can_liquidate, ECanLiquidate);
        // TODO: check price too volatile?? (SIP-184)
        let (skew, skew_direction) = market_manager::market_skew<B, Q>(market);
        let taker_fee = market_manager::taker_fee<B, Q>(market);
        let maker_fee = market_manager::maker_fee<B, Q>(market);
        let fee = order_fee(skew, skew_direction, size_delta, size_delta_direction, fill_price, taker_fee, maker_fee);
        // Deduct the fee. It will revert if the realized margin minus the fee is negative or subject to liquidation
        let new_pos_margin = recompute_margin_with_delta<B, Q>(
            market,
            fill_price,
            fee, // margin delta is the fee
            false, // fee is always subtracted from margin
            msg_sender,
            timestamp_ms
        );

        // construct new position
        let (new_pos_size, new_pos_direction) = utils::add_signed(old_pos_size, old_pos_direction, size_delta, size_delta_direction);

        // always allow to decrease a position, otherwise a margin of minInitialMargin can never
        // decrease a position as the price goes against them.
        // we also add the paid out fee for the minInitialMargin because otherwise minInitialMargin
        // is never the actual minMargin, because the first trade will always deduct
        // a fee (so the margin that otherwise would need to be transferred would have to include the future
        // fee as well, making the UX and definition of min-margin confusing).
        let is_position_decreasing = utils::same_side(old_pos_size, old_pos_direction, new_pos_size, new_pos_direction)
            && new_pos_size < old_pos_size;
        if (!is_position_decreasing) {
            // minMargin + fee <= margin is equivalent to minMargin <= margin - fee
            // except that we get a nicer error message if fee > margin, rather than arithmetic overflow.
            let min_initial_margin = market_manager::min_initial_margin<B, Q>(market);
            let is_insufficient_margin = new_pos_margin + fee < min_initial_margin;
            assert!(!is_insufficient_margin, EInsufficientMargin);
        };

        // check that new position margin is above liquidation margin
        // (above, in _recomputeMarginWithDelta() we checked the old position, here we check the new one)
        //
        // Liquidation margin is considered without a fee (but including premium), because it wouldn't make sense to allow
        // a trade that will make the position liquidatable.
        //
        // note: we use `oraclePrice` here as `liquidationPremium` calcs premium based not current skew.
        let liq_premium = liquidation_premium<B, Q>(market, new_pos_size, oracle_price);
        let liq_margin = liq_premium + liquidation_margin<B, Q>(market, new_pos_size, oracle_price);
        assert!(new_pos_margin > liq_margin, ECanLiquidate);

        // Check that the maximum leverage is not exceeded when considering new margin including the paid fee.
        // The paid fee is considered for the benefit of UX of allowed max leverage, otherwise, the actual
        // max leverage is always below the max leverage parameter since the fee paid for a trade reduces the margin.
        // We'll allow a little extra headroom for rounding errors.
        let leverage = utils::divide_decimal(
            utils::multiply_decimal(new_pos_size, fill_price),
            new_pos_margin + fee
        );
        let market_max_leverage = market_manager::max_leverage<B, Q>(market);
        // TODO: verify this calculation
        let max_leverage = market_max_leverage + (ONE_UNIT / 100);
        assert!(leverage <= max_leverage, EMaxLeverageExceeded);

        // Check that the order isn't too large for the markets.
        let max_market_value = market_manager::max_market_value<B, Q>(market);
        let order_too_large = order_size_too_large<B, Q>(market, max_market_value, old_pos_size, old_pos_direction, new_pos_size, new_pos_direction);
        assert!(!order_too_large, EMaxMarketSizeExceeded);

        // return new position information and the order fee
        (new_pos_margin, new_pos_size, new_pos_direction, fee)
    }

    fun order_size_too_large<B, Q>(
        market: &mut Market<B, Q>,
        max_size: u64,
        old_size: u64,
        old_direction: bool,
        new_size: u64,
        new_direction: bool
    ): bool {
        // Allow users to reduce an order no matter the market conditions.
        let is_reduce_order = utils::same_side(old_size, old_direction, new_size, new_direction)
            && new_size < old_size;
        if (is_reduce_order) {
            return false
        };

        let (skew, skew_direction) = market_manager::market_skew<B, Q>(market);
        let (skew_minus_old, skew_minus_old_direction) = utils::subtract_signed(skew, skew_direction, old_size, old_direction);
        let (new_skew, new_skew_direction) = utils::add_signed(skew_minus_old, skew_minus_old_direction, new_size, new_direction);
        let curr_market_size = market_manager::market_size<B, Q>(market);
        let new_market_size = utils::sub(curr_market_size, old_size) + new_size;

        // TODO: verify this calculation
        let (new_side_size, _) = if (new_direction) {
            // long case: marketSize + skew
            //            = (|longSize| + |shortSize|) + (longSize + shortSize)
            //            = 2 * longSize
            utils::add_signed(new_market_size, true, new_skew, new_skew_direction)
        } else {
            // short case: marketSize - skew
            //            = (|longSize| + |shortSize|) - (longSize + shortSize)
            //            = 2 * -shortSize
            utils::subtract_signed(new_market_size, true, new_skew, new_skew_direction)
        };

        // newSideSize still includes an extra factor of 2 here, so we will divide by 2 in the actual condition
        new_side_size = new_side_size / 2;
        if (new_side_size > max_size) {
            return true
        };

        false
    }

    public fun order_fee(
        skew: u64,
        skew_direction: bool,
        size_delta: u64,
        size_delta_direction: bool,
        fill_price: u64,
        taker_fee: u64,
        maker_fee: u64
    ): u64 {
        let notional_diff = utils::multiply_decimal(size_delta, fill_price);
        let (new_skew, new_skew_direction) = utils::add_signed(skew, skew_direction, size_delta, size_delta_direction);
        let is_same_side = utils::same_side(new_skew, new_skew_direction, skew, skew_direction);
        if (is_same_side) {
            // use a flat maker/taker fee for the entire size depending on whether the skew is increased or reduced.
            //
            // if the order is submitted on the same side as the skew (increasing it) - the taker fee is charged.
            // otherwise if the order is opposite to the skew, the maker fee is charged.
            let static_rate = if (new_skew > skew) {
                taker_fee
            } else {
                maker_fee
            };

            return utils::multiply_decimal(notional_diff, static_rate)
        };

        // This trade flips the skew.
        // The proportion of size that moves in the direction after the flip should not be considered
        // as a maker (reducing skew) as it's now taking (increasing skew) in the opposite direction. hence,
        // a different fee is applied on the proportion increasing the skew.

        // proportion of size that's on the other direction
        let taker_size = utils::divide_decimal(skew + size_delta, size_delta);
        let maker_size = utils::sub(ONE_UNIT, taker_size);
        let taker_fee = utils::multiply_decimal(
            utils::multiply_decimal(notional_diff, taker_size),
            taker_fee
        );
        let maker_fee = utils::multiply_decimal(
            utils::multiply_decimal(notional_diff, maker_size),
            maker_fee
        );

        taker_fee + maker_fee
    }

    fun can_liquidate<B, Q>(market: &Market<B, Q>, price: u64, msg_sender: address, timestamp_ms: u64): bool {
        let (_, _, _, position_size, _) = market_manager::get_position_data<B, Q>(market, msg_sender);
        // No liquidating empty positions.
        if (position_size == 0) {
            return false
        };

        let remaining_margin = remaining_liquidatable_margin<B, Q>(market, price, position_size, msg_sender, timestamp_ms);
        let liq_margin = liquidation_margin<B, Q>(market, position_size, price);
        remaining_margin <= liq_margin
    }

    fun remaining_liquidatable_margin<B, Q>(market: &Market<B, Q>, price: u64, position_size: u64, msg_sender: address, timestamp_ms: u64): u64 {
        let margin = margin_plus_profit_funding<B, Q>(market, price, msg_sender, timestamp_ms);
        let liq_premium = liquidation_premium<B, Q>(market, position_size, price);
        utils::sub(margin, liq_premium)
    }

    /**
     * This is the additional premium we charge upon liquidation.
     *
     * Similar to fillPrice, but we disregard the skew (by assuming it's zero). Which is basically the calculation
     * when we compute as if taking the position from 0 to x. In practice, the premium component of the
     * liquidation will just be (size / skewScale) * (size * price).
     *
     * It adds a configurable multiplier that can be used to increase the margin that goes to feePool.
     *
     * For instance, if size of the liquidation position is 100, oracle price is 1200 and skewScale is 1M then,
     *
     *  size    = abs(-100)
     *          = 100
     *  premium = 100 / 1000000 * (100 * 1200) * multiplier
     *          = 12 * multiplier
     *  if multiplier is set to 1
     *          = 12 * 1 = 12
     *
     * @param positionSize Size of the position we want to liquidate
     * @param currentPrice The current oracle price (not fillPrice)
     * @return The premium to be paid upon liquidation in sUSD
     */
    fun liquidation_premium<B, Q>(market: &Market<B, Q>, position_size: u64, price: u64): u64 {
        if (position_size == 0) {
            return 0
        };

        // we don't care about notional value direction
        let (notional_value, _) = notional_value(position_size, true, price);
        let skew_scale = market_manager::skew_scale<B, Q>(market);
        let liq_premium_multiplier = market_manager::liquidation_premium_multiplier<B, Q>(market);
        utils::multiply_decimal(
            utils::multiply_decimal(
                utils::divide_decimal(position_size, skew_scale),
                notional_value
            ),
            liq_premium_multiplier
        )
    }

    fun notional_value(position_size: u64, position_direction: bool, price: u64): (u64, bool) {
        let value = utils::multiply_decimal(position_size, price);
        (value, position_direction)
    }

    fun current_funding_rate<B, Q>(market: &Market<B, Q>, timestamp_ms: u64): (u64, bool) {
        let (last_funding_rate, last_funding_direction) = market_manager::funding_rate_last_recomputed<B, Q>(market);
        let (current_funding_velocity, curr_velocity_direction) = current_funding_velocity<B, Q>(market);
        let proportional_elapsed = proportional_elapsed<B, Q>(market, timestamp_ms);
        let velocity = utils::multiply_decimal(current_funding_velocity, proportional_elapsed);
        let (funding_rate, direction) = utils::add_signed(last_funding_rate, last_funding_direction, velocity, curr_velocity_direction);
        (funding_rate, direction)
    }

    fun current_funding_velocity<B, Q>(market: &Market<B, Q>): (u64, bool) {
        let max_funding_velocity = market_manager::max_funding_velocity<B, Q>(market);
        let (proportional_skew, skew_direction) = proportional_skew<B, Q>(market);
        let funding_velocity = utils::multiply_decimal(proportional_skew, max_funding_velocity);
        (funding_velocity, skew_direction)
    }

    /**
     * Returns the pSkew = skew / skewScale capping the pSkew between [-1, 1].
     */
    fun proportional_skew<B, Q>(market: &Market<B, Q>): (u64, bool) {
        let (skew, skew_direction) = market_manager::market_skew<B, Q>(market);
        let skew_scale = market_manager::skew_scale<B, Q>(market);
        let p_skew = utils::divide_decimal(skew, skew_scale);
        // Ensures the proportional skew is between -1 and 1
        if (p_skew > ONE_UNIT) {
            p_skew = ONE_UNIT;
        };

        (p_skew, skew_direction)
    }

    fun proportional_elapsed<B, Q>(market: &Market<B, Q>, timestamp_ms: u64): u64 {
        let funding_last_recomputed = market_manager::funding_last_recomputed<B, Q>(market);
        // TODO: is this correct?
        let proportional_elapsed = utils::divide_decimal(
            utils::sub(timestamp_ms, funding_last_recomputed),
            ONE_DAY_IN_MS
        );
        proportional_elapsed
    }

    public fun next_funding_entry<B, Q>(market: &Market<B, Q>, price: u64, timestamp_ms: u64): (u64, bool) {
        let latest_funding_index = market_manager::latest_funding_index<B, Q>(market);
        let (latest_funding, latest_funding_direction) = market_manager::funding_sequence<B, Q>(market, latest_funding_index);
        let (unrecorded_funding, unrecorded_funding_direction) = unrecorded_funding<B, Q>(market, price, timestamp_ms);
        // latest_funding + unrecorded_funding
        utils::add_signed(latest_funding, latest_funding_direction, unrecorded_funding, unrecorded_funding_direction)
    }

    public fun unrecorded_funding<B, Q>(market: &Market<B, Q>, price: u64, timestamp_ms: u64): (u64, bool) {
        let (next_funding, next_funding_direction) = current_funding_rate<B, Q>(market, timestamp_ms);
        let (last_funding, last_funding_direction) = market_manager::funding_rate_last_recomputed<B, Q>(market);
        let (funding, funding_direction) = utils::add_signed(next_funding, next_funding_direction, last_funding, last_funding_direction);
        let avg_funding_rate = utils::divide_decimal(funding, ONE_UNIT * 2);
        let proportional_elapsed = proportional_elapsed<B, Q>(market, timestamp_ms);
        let unrecorded_funding = utils::multiply_decimal(utils::multiply_decimal(avg_funding_rate, proportional_elapsed), price);
        // note the inversion: funding flows in the opposite direction to the skew
        (unrecorded_funding, !funding_direction)
    }

    fun apply_debt_correction<B, Q>(
        market: &mut Market<B, Q>,
        new_last_funding_index: u64,
        new_margin: u64,
        new_last_price: u64,
        new_size: u64,
        old_last_funding_index: u64,
        old_margin: u64,
        old_last_price: u64,
        old_size: u64,
    ) {
        let (new_correction, new_correction_direction) = position_debt_correction<B, Q>(market, new_last_funding_index, new_margin, new_last_price, new_size);
        let (old_correction, old_correction_direction) = position_debt_correction<B, Q>(market, old_last_funding_index, old_margin, old_last_price, old_size);
        let (current_edc, current_edc_direction) = market_manager::entry_debt_correction<B, Q>(market);
        let (current_plus_new_edc, current_plus_new_edc_direction) = utils::add_signed(current_edc, current_edc_direction, new_correction, new_correction_direction);
        let (entry_debt_correction, edc_direction) = utils::subtract_signed(
            current_plus_new_edc,
            current_plus_new_edc_direction,
            old_correction,
            old_correction_direction
        );
        market_manager::set_entry_debt_correction<B, Q>(market, entry_debt_correction, edc_direction);
    }

    /*
     * The impact of a given position on the debt correction.
     */
    fun position_debt_correction<B, Q>(
        market: &Market<B, Q>,
        position_last_funding_index: u64,
        position_margin: u64,
        position_last_price: u64,
        position_size: u64,
    ): (u64, bool) {
        /*
            The overall market debt is the sum of the remaining margin in all positions. The intuition is that
            the debt of a single position is the value withdrawn upon closing that position.
    
            single position remaining margin = initial-margin + profit-loss + accrued-funding =
                = initial-margin + q * (price - last-price) + q * funding-accrued-per-unit
                = initial-margin + q * price - q * last-price + q * (funding - initial-funding)
    
            Total debt = sum ( position remaining margins )
                = sum ( initial-margin + q * price - q * last-price + q * (funding - initial-funding) )
                = sum( q * price ) + sum( q * funding ) + sum( initial-margin - q * last-price - q * initial-funding )
                = skew * price + skew * funding + sum( initial-margin - q * ( last-price + initial-funding ) )
                = skew (price + funding) + sum( initial-margin - q * ( last-price + initial-funding ) )
    
            The last term: sum( initial-margin - q * ( last-price + initial-funding ) ) being the position debt correction
                that is tracked with each position change using this method. 

            The first term and the full debt calculation using current skew, price, and funding is calculated globally in marketDebt().
        */
        let (funding, funding_direction) = market_manager::funding_sequence<B, Q>(market, position_last_funding_index);
        // price always positive
        let (price_plus_funding, ppf_direction) = utils::add_signed(position_last_price, true, funding, funding_direction);
        let (position_debt_correction, pdc_direction) = utils::subtract_signed(
            position_margin,
            true, // margin always positive
            utils::multiply_decimal(position_size, price_plus_funding),
            ppf_direction
        );
        (position_debt_correction, pdc_direction)
    }

    fun recompute_margin_with_delta<B, Q>(
        market: &Market<B, Q>,
        price: u64,
        margin_delta: u64,
        margin_delta_direction: bool,
        msg_sender: address,
        timestamp_ms: u64
    ): u64 {
        let curr_margin = margin_plus_profit_funding<B, Q>(market, price, msg_sender, timestamp_ms);
        // 2nd argument true. margin always positive (or 0)
        let (new_margin, new_position_direction) = utils::add_signed(curr_margin, true, margin_delta, margin_delta_direction);

        // make sure new margin is not negative
        assert!(new_margin >= 0 && new_position_direction, EInsufficientMargin);
        let (_, _, _, position_size, _) = market_manager::get_position_data<B, Q>(market, msg_sender);
        let liq_margin = liquidation_margin<B, Q>(market, position_size, price);
        // make sure new position can't be liquidated (size 0 can't be liquidated)
        assert!(new_margin > liq_margin || position_size == 0, ECanLiquidate);
        // will always be positive
        new_margin
    }

    // return position margin and direction
    public fun margin_plus_profit_funding<B, Q>(
        market: &Market<B, Q>,
        price: u64,
        msg_sender: address,
        timestamp_ms: u64
    ): u64 {
        let (_, position_margin, _, _, position_direction) = market_manager::get_position_data<B, Q>(market, msg_sender);
        let (funding, funding_direction) = accrued_funding<B, Q>(market, price, msg_sender, timestamp_ms);
        let (pnl, pnl_direction) = profit_loss<B, Q>(market, price, msg_sender);
        // margin + funding
        let (pos_plus_funding, pos_plus_funding_direction) = utils::add_signed(position_margin, position_direction, funding, funding_direction);
        // margin + funding + pnl
        let (margin, margin_direction) = utils::add_signed(pos_plus_funding, pos_plus_funding_direction, pnl, pnl_direction);
        if (margin_direction) {
            margin
        } else {
            // margin can't go negative, return 0
            0
        }
    }

    /**
     * Returns pnl for given position and price: (profit, pnl_direction)
     * - if long and price is higher, pnl increases, so return (pnl, true)
     * - if long and price is lower, pnl decreases so return (pnl, false)
     * - if short and price is higher, pnl decreases so return (pnl, false)
     * - if short and price is lower, pnl increases so return (pnl, true)
     */
    public fun profit_loss<B, Q>(
        market: &Market<B, Q>,
        price: u64,
        msg_sender: address
    ): (u64, bool) {
        let (_, _, position_last_price, position_size, position_direction) = market_manager::get_position_data<B, Q>(market, msg_sender);
        if (price > position_last_price) {
            // price has increased
            let price_shift = utils::sub(price, position_last_price);
            let pnl = utils::multiply_decimal(position_size, price_shift);
            // pnl increased if long, or decreased if short
            if (position_direction) {
                (pnl, true)
            } else {
                (pnl, false)
            }
        } else {
            // price has decreased
            let price_shift = utils::sub(position_last_price, price);
            let pnl = utils::multiply_decimal(position_size, price_shift);
            // pnl decreased if long, or increased if short
            if (position_direction) {
                (pnl, false)
            } else {
                (pnl, true)
            }
        }
    }

    /**
     * Returns accrued funding for given position, price, timestamp: (funding, funding_direction)
     * - if long and funding diff is positive, position is paid funding, so return (funding, true)
     * - if long and funding diff is negative, position pays funding, so return (funding, false)
     * - if short and funding diff is positive, position pays funding, so return (funding, true)
     * - if short and funding diff is negative, position is paid funding, so return (funding, false)
     */
    fun accrued_funding<B, Q>(
        market: &Market<B, Q>,
        price: u64,
        msg_sender: address,
        timestamp_ms: u64
    ): (u64, bool) {
        let (position_last_funding_index, _, _, position_size, _) = market_manager::get_position_data<B, Q>(market, msg_sender);
        if (position_last_funding_index == 0) {
            return (0, true)
        };

        let (net_funding_per_unit, funding_direction) = net_funding_per_unit<B, Q>(market, position_last_funding_index, price, timestamp_ms);
        let accrued_funding = utils::multiply_decimal(position_size, net_funding_per_unit);
        (accrued_funding, funding_direction)
    }

    fun net_funding_per_unit<B, Q>(
        market: &Market<B, Q>,
        start_index: u64,
        price: u64,
        timestamp_ms: u64
    ): (u64, bool) {
        // Compute the net difference between start and end indices (next - start)
        let (next_funding, next_funding_direction) = next_funding_entry<B, Q>(market, price, timestamp_ms);
        let (start_funding, start_funding_direction) = market_manager::funding_sequence<B, Q>(market, start_index);
        // next_funding - start_funding
        utils::subtract_signed(next_funding, next_funding_direction, start_funding, start_funding_direction)
    }

    public fun current_leverage(
        position_size: u64,
        price: u64,
        remaining_margin: u64
    ): u64 {
        if (remaining_margin == 0) {
            return 0
        };

        // we don't care about notional direction
        let (notional_value, _) = notional_value(position_size, true, price);
        utils::divide_decimal(notional_value, remaining_margin)
    }

    /**
     * The minimal margin at which liquidation can happen. Is the sum of liquidationBuffer and liquidationFee
     * @return lMargin liquidation margin to maintain in sUSD fixed point decimal units
     * @dev The liquidation margin contains a buffer that is proportional to the position
     * size. The buffer should prevent liquidation happening at negative margin (due to next price being worse)
     * so that stakers would not leak value to liquidators by receiving rewards that are not from the
     * account's margin.
     */
    fun liquidation_margin<B, Q>(
        market: &Market<B, Q>,
        position_size: u64,
        price: u64
    ): u64 {
        // size * price * buffer-ratio
        let liq_buff_ratio = market_manager::liquidation_buffer_ratio<B, Q>(market);
        let liq_buffer = utils::multiply_decimal(
            utils::multiply_decimal(position_size, price),
            liq_buff_ratio
        );

        let liq_fee = liquidation_fee<B, Q>(market, position_size, price);
        liq_buffer + liq_fee
    }

    /**
     * The fee charged from the margin during liquidation. Fee is proportional to position size
     * but is between min_keeper_fee and max_keeper_fee expressed in Q to prevent underincentivising
     * liquidations of small positions, or overpaying.
     */
    fun liquidation_fee<B, Q>(
        market: &Market<B, Q>,
        position_size: u64,
        price: u64
    ): u64 {
        // size * price * fee-ratio
        let liq_fee_ratio = market_manager::liquidation_fee_ratio<B, Q>(market);
        let proportional_fee = utils::multiply_decimal(
            utils::multiply_decimal(position_size, price),
            liq_fee_ratio
        );

        let max_keeper_fee = market_manager::max_keeper_fee<B, Q>(market);
        let min_keeper_fee = market_manager::min_keeper_fee<B, Q>(market);
        let capped_proportional_fee = if (proportional_fee > max_keeper_fee) {
            max_keeper_fee
        } else {
            proportional_fee
        };

        if (capped_proportional_fee < min_keeper_fee) {
            min_keeper_fee
        } else {
            capped_proportional_fee
        }
    }

    /**
     * The debt contributed by this market to the overall system.
     * The total market debt is equivalent to the sum of remaining margins in all open positions.
     */
    public fun market_debt<B, Q>(
        market: &Market<B, Q>,
        timestamp_ms: u64
    ): u64 {
        let price = asset_price_require_system_checks<B, Q>(market);
        //let (skew, skew_direction) = market_manager::market_skew<B, Q>(market);
        let size = market_manager::market_size<B, Q>(market);
        let (edc, edc_direction) = market_manager::entry_debt_correction<B, Q>(market);
        if (size == 0 && edc == 0) {
            // if these are 0, the resulting calculation is necessarily zero as well
            return 0
        };

        let (funding, funding_direction) = next_funding_entry<B, Q>(market, price, timestamp_ms);
        let (price_with_funding, pwf_direction) = utils::add_signed(price, true, funding, funding_direction);
        let (size_times_pwf, size_times_pwf_direction) = utils::multiply_decimal_signed(size, true, price_with_funding, pwf_direction);

        let (total_debt, total_debt_direction) = utils::add_signed(size_times_pwf, size_times_pwf_direction, edc, edc_direction);
        // debt can't be negative
        // TODO: verify this?
        if (!total_debt_direction) {
            return 0
        };
        total_debt
    }

}
