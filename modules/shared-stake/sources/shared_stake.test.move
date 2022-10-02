#[test_only]
module openrails::shared_stake_tests {
    use std::signer;
    use aptos_framework::account;
    use aptos_framework::coin;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    use aptos_framework::stake;
    use aptos_framework::reconfiguration;
    use openrails::shared_stake;

    const EINCORRECT_BALANCE: u64 = 9;
    const EINCORRECT_VALIDATOR_STATE: u64 = 10;

    const CONSENSUS_KEY_2: vector<u8> = x"a344eb437bcd8096384206e1be9c80be3893fd7fdf867acce5a048e5b1546028bdac4caf419413fd16d4d6a609e0b0a3";
    const CONSENSUS_POP_2: vector<u8> = x"909d3a378ad5c17faf89f7a2062888100027eda18215c7735f917a4843cd41328b42fa4242e36dedb04432af14608973150acbff0c5d3f325ba04b287be9747398769a91d4244689cfa9c535a5a4d67073ee22090d5ab0a88ab8d2ff680e991e";

    public fun intialize_test_state(aptos_framework: &signer, validator: &signer, user: &signer) {
        account::create_account_for_test(signer::address_of(aptos_framework));
        account::create_account_for_test(signer::address_of(validator));
        account::create_account_for_test(signer::address_of(user));
        reconfiguration::initialize_for_test(aptos_framework);
        reconfiguration::reconfigure_for_test();
        coin::register<AptosCoin>(validator);
        coin::register<AptosCoin>(user);
        stake::initialize_for_test_custom(aptos_framework, 100, 10000, 3600, true, 1, 100, 100);

        // Call the initialize function, rotate consensus keys
        shared_stake::initialize(validator);
        stake::rotate_consensus_key(validator, signer::address_of(validator), CONSENSUS_KEY_2, CONSENSUS_POP_2);
    }

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    public entry fun test_end_to_end(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        // Mint some coins to the user
        aptos_coin::mint(aptos_framework, user_addr, 500);

        // Call deposit, which stakes the tokens with the validator address
        shared_stake::deposit(user, validator_addr, 100);

        // Because the validator is currently not part of the validator set, any deposited stake
        // should go immediately into active, not pending_active
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

        // End the epoch, beginning a new one
        stake::end_epoch();

        // We should be an in the active validator set
        assert!(stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);

        // User stakes more coins, since it is in the active validator set, the coins will go into pending active,
        // and not directly into active
        shared_stake::deposit(user, validator_addr, 50);
        stake::assert_stake_pool(validator_addr, 100, 0, 50, 0);
        shared_stake::assert_balances(validator_addr, 100, 50, 0);
        let user_stake = shared_stake::get_stake_balance(validator_addr, user_addr);
        assert!(user_stake == 150, EINCORRECT_BALANCE);

        // Unlock some coins in the same epoch
        shared_stake::unlock(user, validator_addr, 25);
        stake::assert_stake_pool(validator_addr, 75, 0, 50, 25);
        shared_stake::assert_balances(validator_addr, 75, 50, 25);
        let user_stake = shared_stake::get_stake_balance(validator_addr, user_addr);
        assert!(user_stake == 125, EINCORRECT_BALANCE);

        shared_stake::crank_on_new_epoch(validator_addr);

        // ** This indicates that any time a user wants to unlock their stake, it is subtracted from their active
        // balance, and is not deducted from their pending_active balance

        // End the epoch, and check the balances
        stake::end_epoch();
        // Both are incorrect. It should be:
        // active: 125
        // inactive: 25
        // pending_active: 0
        // pending_inactive: 0
        stake::assert_stake_pool(validator_addr, 125, 0, 0, 25);
        shared_stake::assert_balances(validator_addr, 75, 50, 25);
        let user_stake = shared_stake::get_stake_balance(validator_addr, user_addr);
        assert!(user_stake == 125, EINCORRECT_BALANCE);
    }

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