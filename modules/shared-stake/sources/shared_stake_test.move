#[test_only]
module openrails::shared_stake_tests {
    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::stake;
    use aptos_framework::account;
    use aptos_framework::reconfiguration;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_std::debug;

    use openrails::shared_stake;
    use aptos_framework::timestamp;

    const EINCORRECT_BALANCE: u64 = 9;
    const EINCORRECT_VALIDATOR_STATE: u64 = 10;

    const CONSENSUS_KEY_2: vector<u8> = x"a344eb437bcd8096384206e1be9c80be3893fd7fdf867acce5a048e5b1546028bdac4caf419413fd16d4d6a609e0b0a3";
    const CONSENSUS_POP_2: vector<u8> = x"909d3a378ad5c17faf89f7a2062888100027eda18215c7735f917a4843cd41328b42fa4242e36dedb04432af14608973150acbff0c5d3f325ba04b287be9747398769a91d4244689cfa9c535a5a4d67073ee22090d5ab0a88ab8d2ff680e991e";

    const LOCKUP_CYCLE_SECONDS: u64 = 3600;

    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    // ================= Test-only helper functions =================

    public fun intialize_test_state(aptos_framework: &signer, validator: &signer, user: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(validator));
        account::create_account_for_test(signer::address_of(user));
        reconfiguration::initialize_for_test(aptos_framework);
        reconfiguration::reconfigure_for_test();
        coin::register<AptosCoin>(validator);
        coin::register<AptosCoin>(user);
        // stake::initialize_for_test_custom(aptos_framework, 100, 10000, 3600, true, 1, 100, 100);
        // stake::initialize_test_validator(validator, 0, false, false);

        // Call the initialize function, rotate consensus keys
        shared_stake::initialize_for_test(aptos_framework, validator);
        stake::rotate_consensus_key(validator, signer::address_of(validator), CONSENSUS_KEY_2, CONSENSUS_POP_2);
    }

    public fun intialize_test_state_two_users(aptos_framework: &signer, validator: &signer, user1: &signer, user2: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(validator));
        account::create_account_for_test(signer::address_of(user1));
        account::create_account_for_test(signer::address_of(user2));
        reconfiguration::initialize_for_test(aptos_framework);
        reconfiguration::reconfigure_for_test();
        coin::register<AptosCoin>(validator);
        coin::register<AptosCoin>(user1);
        coin::register<AptosCoin>(user2);
        stake::initialize_for_test_custom(aptos_framework, 100, 10000, 3600, true, 1, 100, 100);

        // Call the initialize function, rotate consensus keys
        shared_stake::initialize(validator);
        stake::rotate_consensus_key(validator, signer::address_of(validator), CONSENSUS_KEY_2, CONSENSUS_POP_2);
    }

    public fun new_epoch() {
        stake::end_epoch();
        reconfiguration::reconfigure_for_test_custom()
        // reconfiguration::reconfigure_for_test();
    }

    // ================= Tests =================

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    public entry fun test_end_to_end(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        // Mint some coins to the user
        aptos_coin::mint(aptos_framework, user_addr, 500);

        // Call deposit, which stakes the tokens with the validator address
        shared_stake::deposit(user, validator_addr, 100);
        assert!(coin::balance<AptosCoin>(user_addr) == 400, EINCORRECT_BALANCE);

        // Because the validator is currently not part of the validator set, any deposited stake
        // should go immediately into active, not pending_active
        stake::assert_validator_state(validator_addr, 100, 0, 0, 0, 0);
        stake::assert_stake_pool(validator_addr, 100, 0, 0, 0);
        shared_stake::assert_balances(validator_addr, 100, 0, 0);

        // Assert that the user now has shares equivalent to the initial deposit amount (100)
        let user_stake = shared_stake::get_stake_balance(validator_addr, user_addr);
        assert!(user_stake == 100, EINCORRECT_BALANCE);

        // Examine the share's value directly; we should be able to extract and store shares
        let share = shared_stake::extract_share(user, validator_addr, user_stake);
        let share_value_in_apt = shared_stake::get_stake_balance_of_share(&share);
        assert!(share_value_in_apt == user_stake, EINCORRECT_BALANCE);
        shared_stake::store_share(user_addr, share);

        // Now that the validator has at least the minimum stake, it can be added to the validator set
        stake::join_validator_set(validator, validator_addr);

        // We should be in the pending_active validator set
        assert!(!stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);

        // End the epoch 0, start epoch 1
        new_epoch();

        // We should now be in the active validator set
        assert!(stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);
        assert!(stake::get_remaining_lockup_secs(validator_addr) == LOCKUP_CYCLE_SECONDS, 1);

        // End the epoch 1, earn our first reward, start epoch 2, and check the balances
        new_epoch();
        assert!(stake::get_validator_state(validator_addr) == VALIDATOR_STATUS_ACTIVE, 3);
        stake::assert_validator_state(validator_addr, 101, 0, 0, 0, 0);
        stake::assert_stake_pool(validator_addr, 101, 0, 0, 0);
        let (active, _, _, _) = stake::get_stake(validator_addr);
        assert!(active == 101, 10);
        // shared stake has to be cranked, or else its internal balance will be out of date
        shared_stake::crank_on_new_epoch(validator_addr);
        shared_stake::assert_balances(validator_addr, 101, 0, 0);

        // Deposit some coins. Now that the validator status is active, the coins will be deposited into pending active first
        shared_stake::deposit(user, validator_addr, 100);
        assert!(coin::balance<AptosCoin>(user_addr) == 300, EINCORRECT_BALANCE);
        stake::assert_validator_state(validator_addr, 101, 0, 100, 0, 0);

        // Assert that the user now has coins from new deposit (100), old deposit (100) and interest (1)
        shared_stake::assert_balances(validator_addr, 101, 100, 0);
        let user_stake = shared_stake::get_stake_balance(validator_addr, user_addr);
        assert!(user_stake == 201, EINCORRECT_BALANCE);

        // End the epoch 2, start epoch 3
        new_epoch();
        stake::assert_validator_state(validator_addr, 202, 0, 0, 0, 0);

        // Now, let's deposit and unlock some coins in the same epoch
        shared_stake::deposit(user, validator_addr, 100);
        assert!(coin::balance<AptosCoin>(user_addr) == 200, EINCORRECT_BALANCE);
        stake::assert_validator_state(validator_addr, 202, 0, 100, 0, 0);
        let user_stake = shared_stake::get_stake_balance(validator_addr, user_addr);
        assert!(user_stake == 300, EINCORRECT_BALANCE);

        shared_stake::unlock(user, validator_addr, 100);
        assert!(coin::balance<AptosCoin>(user_addr) == 200, EINCORRECT_BALANCE);
        debug::print(&9999);
        stake::assert_validator_state(validator_addr, 102, 0, 100, 100, 0); // <--- ERROR HERE
        let user_stake = shared_stake::get_stake_balance(validator_addr, user_addr);
        assert!(user_stake == 202, EINCORRECT_BALANCE);

        // End epoch 3, start epoch 4
        new_epoch();
        stake::assert_validator_state(validator_addr, 203, 0, 0, 101, 0);

        // Once unlocked, and coins are in pending_inactive, coins will accrue there instead of active

        // Flashforward to the lockup cycle ending, and check the balances again
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);

        debug::print(&7777);

        // End epoch 4, start epoch 5
        new_epoch();
        stake::assert_validator_state(validator_addr, 205, 102, 0, 0, 0);

        // Now that the stake is in inactive, it should be able to be withdrawn
        shared_stake::withdraw(user, validator_addr, 100);
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user1 = @0x456, user2 = @0x789)]
    public entry fun test_two_users(aptos_framework: &signer, validator: &signer, user1: &signer, user2: &signer) {
        let validator_addr = signer::address_of(validator);
        let user1_addr = signer::address_of(user1);
        let user2_addr = signer::address_of(user2);

        intialize_test_state_two_users(aptos_framework, validator, user1, user2);

        aptos_coin::mint(aptos_framework, user1_addr, 500);
        aptos_coin::mint(aptos_framework, user2_addr, 500);

        shared_stake::deposit(user1, validator_addr, 100);
        shared_stake::deposit(user2, validator_addr, 100);

        stake::assert_stake_pool(validator_addr, 200, 0, 0, 0);
        shared_stake::assert_balances(validator_addr, 200, 0, 0);

        let user1_stake = shared_stake::get_stake_balance(validator_addr, user1_addr);
        assert!(user1_stake == 100, EINCORRECT_BALANCE);
        let user2_stake = shared_stake::get_stake_balance(validator_addr, user2_addr);
        assert!(user2_stake == 100, EINCORRECT_BALANCE);

        let share1 = shared_stake::extract_share(user1, validator_addr, user1_stake);
        let share_value_in_apt1 = shared_stake::get_stake_balance_of_share(&share1);
        assert!(share_value_in_apt1 == user1_stake, EINCORRECT_BALANCE);
        shared_stake::store_share(user1_addr, share1);

        let share2 = shared_stake::extract_share(user2, validator_addr, user2_stake);
        let share_value_in_apt2 = shared_stake::get_stake_balance_of_share(&share2);
        assert!(share_value_in_apt2 == user2_stake, EINCORRECT_BALANCE);
        shared_stake::store_share(user2_addr, share2);

        stake::join_validator_set(validator, validator_addr);
        assert!(!stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);
        stake::end_epoch();
        assert!(stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);

        shared_stake::deposit(user1, validator_addr, 50);
        stake::assert_stake_pool(validator_addr, 200, 0, 50, 0);
        shared_stake::assert_balances(validator_addr, 200, 50, 0);
        let user1_stake = shared_stake::get_stake_balance(validator_addr, user1_addr);
        assert!(user1_stake == 150, EINCORRECT_BALANCE);

        shared_stake::deposit(user2, validator_addr, 25);
        stake::assert_stake_pool(validator_addr, 200, 0, 75, 0);
        shared_stake::assert_balances(validator_addr, 200, 75, 0);
        let user2_stake = shared_stake::get_stake_balance(validator_addr, user2_addr);
        assert!(user2_stake == 125, EINCORRECT_BALANCE);

        stake::end_epoch();
        shared_stake::crank_on_new_epoch(validator_addr);

        // Again, similar to the previous test, this passes but the values are incorrect.
        // They should be:
        // active: 275
        // inactive: 0
        // pending_active: 0
        // pending_inactive: 0
        // stake::assert_stake_pool(validator_addr, 275, 0, 0, 0);
        shared_stake::assert_balances(validator_addr, 200, 75, 0);

        // Between these two tests, it indicates that coins will go to the correct balance from epoch 0 (not in active
        // validator set) to epoch 1 (active). But once a validator is active, the coins do not enter the correct
        // balance from one epoch to the next. This might be due to a bug in our crank.
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    public entry fun test_spam_crank(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);
        aptos_coin::mint(aptos_framework, user_addr, 500);
        shared_stake::deposit(user, validator_addr, 100);
        stake::join_validator_set(validator, validator_addr);

        // Call the function 1,000 times in a single epoch
        // Calling it 1,000,000 causes the test to fail via timeout, but that's ok
        let i = 0;
        while (i < 1000) {
            shared_stake::crank_on_new_epoch(validator_addr);
            i = i + 1;
        }
    }

    // ================= Expected Failure Tests =================

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    #[expected_failure]
    public entry fun test_withdraw_before_unlock(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        aptos_coin::mint(aptos_framework, user_addr, 500);
        shared_stake::deposit(user, validator_addr, 100);
        stake::join_validator_set(validator, validator_addr);

        stake::end_epoch();

        shared_stake::withdraw(user, validator_addr, 50);
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    #[expected_failure]
    public entry fun test_unlock_more_than_deposited(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        aptos_coin::mint(aptos_framework, user_addr, 500);
        shared_stake::deposit(user, validator_addr, 100);
        stake::join_validator_set(validator, validator_addr);

        stake::end_epoch();

        shared_stake::unlock(user, validator_addr, 101);
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    #[expected_failure]
    public entry fun test_unlock_more_than_deposited_same_epoch(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        aptos_coin::mint(aptos_framework, user_addr, 500);
        shared_stake::deposit(user, validator_addr, 100);
        stake::join_validator_set(validator, validator_addr);

        shared_stake::unlock(user, validator_addr, 101);
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    #[expected_failure]
    public entry fun test_withdraw_more_than_unlocked(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        aptos_coin::mint(aptos_framework, user_addr, 500);
        shared_stake::deposit(user, validator_addr, 100);
        stake::join_validator_set(validator, validator_addr);

        stake::end_epoch();

        shared_stake::unlock(user, validator_addr, 50);

        stake::end_epoch();

        shared_stake::withdraw(user, validator_addr, 51)
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    #[expected_failure]
    public entry fun test_withdraw_more_than_unlocked_same_epoch(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        aptos_coin::mint(aptos_framework, user_addr, 500);
        shared_stake::deposit(user, validator_addr, 100);
        stake::join_validator_set(validator, validator_addr);

        shared_stake::unlock(user, validator_addr, 50);

        shared_stake::withdraw(user, validator_addr, 51)
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    #[expected_failure]
    public entry fun test_deposit_more_than_balance(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        aptos_coin::mint(aptos_framework, user_addr, 500);
        shared_stake::deposit(user, validator_addr, 501);
        stake::join_validator_set(validator, validator_addr);
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    #[expected_failure]
    public entry fun test_join_validator_set_less_than_min_stake(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        aptos_coin::mint(aptos_framework, user_addr, 99);
        shared_stake::deposit(user, validator_addr, 99);
        stake::join_validator_set(validator, validator_addr);
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    #[expected_failure]
    public entry fun test_join_validator_set_more_than_max_stake(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        aptos_coin::mint(aptos_framework, user_addr, 10001);
        shared_stake::deposit(user, validator_addr, 10001);
        stake::join_validator_set(validator, validator_addr);
    }
}