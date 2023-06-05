module perp::events {
    use sui::event::emit;

    friend perp::market;
    friend perp::vault;

    /// Staked event
    struct StakedEvent has copy, drop {
        user: address,
        shares: u64,
        amount: u64,
        is_reinvest: bool
    }

    /// Staked event
    struct UnstakedEvent has copy, drop {
        user: address,
        shares: u64,
        amount: u64,
        is_full_redeem: bool
    }

    /// Claim event
    struct ClaimedEvent has copy, drop {
        user: address,
        reward: u64
    }

    public(friend) fun staked_event(
        user: address,
        shares: u64,
        amount: u64,
        is_reinvest: bool
    ) {
        emit(
            StakedEvent {
                user,
                shares,
                amount,
                is_reinvest
            }
        );
    }

    public(friend) fun unstaked_event(
        user: address,
        shares: u64,
        amount: u64,
        is_full_redeem: bool
    ) {
        emit(
            UnstakedEvent {
                user,
                shares,
                amount,
                is_full_redeem
            }
        );
    }

    public(friend) fun claimed_event(
        user: address,
        reward: u64,
    ) {
        emit(
            ClaimedEvent {
                user,
                reward
            }
        );
    }

}