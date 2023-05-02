module perp::exchange_rates {

    const RATE: u64 = 2000 * 1_000_000_000;

    public fun rate_and_valid<B, Q>(): (u64, bool) {
        (RATE, true)
    }

    // returns rate, broken, valid
    public fun rate_with_safety_checks<B, Q>(): (u64, bool, bool) {
        (RATE, false, true)
    }

}
