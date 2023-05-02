#[test_only]
module perp::utils_test {

    use perp::utils;

    // Test that adding two signed numbers together works correctly
    #[test]
    fun test_add_signed() {
        // both positive
        // result should be +15
        let (result, result_dir) = utils::add_signed(10, true, 5, true);
        assert!(result == 15, 0);
        assert!(result_dir, 0);
        let (result, result_dir) = utils::add_signed(5, true, 10, true);
        assert!(result == 15, 0);
        assert!(result_dir, 0);
        // one positive, one negative (postive larger)
        // result should be +5
        let (result, result_dir) = utils::add_signed(10, true, 5, false);
        assert!(result == 5, 0);
        assert!(result_dir, 0);
        let (result, result_dir) = utils::add_signed(5, false, 10, true);
        assert!(result == 5, 0);
        assert!(result_dir, 0);
        // one positive, one negative (negative larger)
        // result should be -5
        let (result, result_dir) = utils::add_signed(10, false, 5, true);
        assert!(result == 5, 0);
        assert!(!result_dir, 0);
        let (result, result_dir) = utils::add_signed(5, true, 10, false);
        assert!(result == 5, 0);
        assert!(!result_dir, 0);
        // both negative
        // result should be -15
        let (result, result_dir) = utils::add_signed(10, false, 5, false);
        assert!(result == 15, 0);
        assert!(!result_dir, 0);
        let (result, result_dir) = utils::add_signed(5, false, 10, false);
        assert!(result == 15, 0);
        assert!(!result_dir, 0);
    }

    // Test that subtracting two signed numbers works correctly
    #[test]
    fun test_subtract_signed() {
        // both positive
        // +10 - +5 = +5
        let (result, result_dir) = utils::subtract_signed(10, true, 5, true);
        assert!(result == 5, 0);
        assert!(result_dir, 0);
        // +5 - +10 = -5
        let (result, result_dir) = utils::subtract_signed(5, true, 10, true);
        assert!(result == 5, 0);
        assert!(!result_dir, 0);
        // one positive, one negative (postive larger)
        // +10 - -5 = +15
        let (result, result_dir) = utils::subtract_signed(10, true, 5, false);
        assert!(result == 15, 0);
        assert!(result_dir, 0);
        // -5 - +10 = -15
        let (result, result_dir) = utils::subtract_signed(5, false, 10, true);
        assert!(result == 15, 0);
        assert!(!result_dir, 0);
        // one positive, one negative (negative larger)
        // -10 - +5 = -15
        let (result, result_dir) = utils::subtract_signed(10, false, 5, true);
        assert!(result == 15, 0);
        assert!(!result_dir, 0);
        // +5 - -10 = +15
        let (result, result_dir) = utils::subtract_signed(5, true, 10, false);
        assert!(result == 15, 0);
        assert!(result_dir, 0);
        // both negative
        // -10 - -5 = -5
        let (result, result_dir) = utils::subtract_signed(10, false, 5, false);
        assert!(result == 5, 0);
        assert!(!result_dir, 0);
        // -5 - -10 = +15
        let (result, result_dir) = utils::subtract_signed(5, false, 10, false);
        assert!(result == 5, 0);
        assert!(result_dir, 0);
    }

}