module perp::utils {

    const ONE_UNIT: u64 = 1_000_000_000;

    public fun divide_decimal(x: u64, y: u64): u64 {
        (x / y) * ONE_UNIT
    }

    public fun multiply_decimal(x: u64, y: u64): u64 {
        (x / ONE_UNIT) * y
    }

    /**
     * Adds two signed numbers. ex. +10 + -15 => -5
     * - this would be called like (10, true, 15, false)
     * - and would return (5, false)
     */
    public fun add_signed(x: u64, x_dir: bool, y: u64, y_dir: bool): (u64, bool) {
        if (x_dir) {
            // both positive, simply add
            if (y_dir) {
                (x + y, true)
            } else {
                // check if sign flips
                if (y > x) {
                    (y - x, false)
                } else {
                    (x - y, true)
                }
            }
        } else {
            // both negative, simply add
            if (!y_dir) {
                (y + x, false)
            } else {
                // check if sign flips
                if (x > y) {
                    (x - y, false)
                } else {
                    (y - x, true)
                }
            }
        }
    }

    /**
     * Subtracts two signed numbers. ex. +10 - -15 => -25
     * - this would be called like (10, true, 15, false)
     * - and would return (25, false)
     */
    public fun subtract_signed(x: u64, x_dir: bool, y: u64, y_dir: bool): (u64, bool) {
        if (x > y) {
            if (x_dir && y_dir) { // both positive
                return (x - y, true)
            };
            if (!x_dir && !y_dir) { // both negative
                return (x - y, false)
            };
            if (x_dir && !y_dir) { // x positive, y negative
                return (x + y, true)
            };
            if (!x_dir && y_dir) { // x negative, y positive
                return (x + y, false)
            };
        } else {
            if (x_dir && y_dir) { // both positive
                return (y - x, false)
            };
            if (!x_dir && !y_dir) { // both negative
                return (y - x, true)
            };
            if (x_dir && !y_dir) { // x positive, y negative
                return (y + x, true)
            };
            if (!x_dir && y_dir) { // x negative, y positive
                return (y + x, false)
            };
        };
        // should never reach this
        assert!(false, 0);
        (0, true)
    }

    // True if and only if two positions a and b are on the same side of the market;
    // that is, if they have the same sign, or either of them is zero.
    public fun same_side(x: u64, x_dir: bool, y: u64, y_dir: bool): bool {
        if (x == 0 || y == 0) {
            return true
        };

        x_dir == y_dir
    }

    // subtracts 2 numbers, returns 0 if result would be negative
    public fun sub(x: u64, y: u64): u64 {
        if (y > x) {
            return 0
        };

        x - y
    }

}
