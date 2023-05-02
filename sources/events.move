module perp::events {
    use sui::event::emit;

    friend perp::market;
    friend perp::vault;

    /// Staked event.
    struct StakedEvent has copy, drop {
        user: address,
        shares: u64,
        amount: u64
    }

    public(friend) fun staked_event(
        user: address,
        shares: u64,
        amount: u64
    ) {
        emit(
            StakedEvent {
                user,
                shares,
                amount
            }
        )
    }

}