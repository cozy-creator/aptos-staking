#[test_only]
module openrails::shared_stake_tests {
    use std::signer;
    use aptos_framework::coin;
    use aptos_framework::stake;
    use aptos_framework::account;
    use aptos_framework::reconfiguration;
    use aptos_framework::aptos_coin::{Self, AptosCoin};
    // use aptos_std::debug;

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

    // The reward rate is 1%
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

    // The reward rate is 10%
    // Max stake is 10,000,000
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
        stake::initialize_for_test_custom(aptos_framework, 100, 10000000, 3600, true, 1, 10, 100);

        // Call the initialize function, rotate consensus keys
        shared_stake::initialize(validator);
        stake::rotate_consensus_key(validator, signer::address_of(validator), CONSENSUS_KEY_2, CONSENSUS_POP_2);
    }

    public fun new_epoch() {
        stake::end_epoch();
        reconfiguration::reconfigure_for_test_custom();
        // shared_stake::crank_on_new_epoch(validator_addr);
        // reconfiguration::reconfigure_for_test();
    }

    public fun assert_expected_balances(user_addr: address, validator_addr: address, user_coin_balance: u64, active_stake: u64, inactive_stake: u64, pending_active_stake: u64, pending_inactive_stake: u64, total_shares: u64, pending_inactive_shares: u64, user_staked_coin: u64) {
        assert!(coin::balance<AptosCoin>(user_addr) == user_coin_balance, EINCORRECT_BALANCE);
        stake::assert_stake_pool(validator_addr, active_stake, inactive_stake, pending_active_stake, pending_inactive_stake);
        shared_stake::assert_balances(validator_addr, active_stake, pending_active_stake, pending_inactive_shares);
        shared_stake::assert_tvl(validator_addr, (total_shares as u128), ((active_stake + pending_active_stake + pending_inactive_stake) as u128));
        let staked_balance = shared_stake::get_stake_balance(validator_addr, user_addr);
        assert!(staked_balance == user_staked_coin, EINCORRECT_BALANCE);
    }

    // ================= Tests =================

    #[test(aptos_framework = @0x1, validator = @0x123, user = @0x456)]
    public entry fun test_end_to_end(aptos_framework: &signer, validator: &signer, user: &signer) {
        let validator_addr = signer::address_of(validator);
        let user_addr = signer::address_of(user);

        intialize_test_state(aptos_framework, validator, user);

        // Mint some coins to the user
        aptos_coin::mint(aptos_framework, user_addr, 500);

        // Deposit coin, which stakes the tokens with the validator address
        // Because the validator is currently not part of the validator set, any deposited stake
        // should go immediately into active, not pending_active
        shared_stake::deposit(user, validator_addr, 100);
        assert_expected_balances(user_addr, validator_addr, 400, 100, 0, 0, 0, 100, 0, 100);

        // Minimum stake met, join validator set
        stake::join_validator_set(validator, validator_addr);

        // We should be in the pending_active validator set
        assert!(!stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);

        // ===== End the epoch 0, start epoch 1
        new_epoch();

        // We should now be in the active validator set
        assert!(stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);
        assert!(stake::get_remaining_lockup_secs(validator_addr) == LOCKUP_CYCLE_SECONDS, 1);

        // Balances are unchanged
        assert_expected_balances(user_addr, validator_addr, 400, 100, 0, 0, 0, 100, 0, 100);

        // ===== End epoch 1, earn our first reward, start epoch 2
        // If we do not call a shared_stake command, we must crank, otherwise shared_stake
        // balances will be outdated. (Crank updates balances.)
        new_epoch();
        shared_stake::crank_on_new_epoch(validator_addr);

        // active increases by 1 from staking reward
        assert_expected_balances(user_addr, validator_addr, 400, 101, 0, 0, 0, 100, 0, 101);

        shared_stake::deposit(user, validator_addr, 50);

        // user balance decreases, pending_active increases, total coins increases,
        // total shares increases
        assert_expected_balances(user_addr, validator_addr, 350, 101, 0, 50, 0, 149, 0, 151);

        // ===== End the epoch 2, start epoch 3
        new_epoch();
        shared_stake::crank_on_new_epoch(validator_addr);

        // pending_active moves to active, stake reward
        assert_expected_balances(user_addr, validator_addr, 350, 152, 0, 0, 0, 149, 0, 152);

        shared_stake::unlock(user, validator_addr, 100);

        // active moves to pending_inactive, pending_inactive_shares goes to 98
        // stake_balance also decreases to 52
        // Note that although we requested 100 coins, we only get 99 due to integer
        // arithmetic, which truncates any decimals
        // This 1 coin will effectively be kept in the active pool forever; the user went from
        // 152 active to 52 active, 99 unlocking
        assert_expected_balances(user_addr, validator_addr, 350, 53, 0, 0, 99, 149, 98, 52);

        shared_stake::deposit(user, validator_addr, 100);

        // Coin increases by 100, shares increases by 98. User balance increases by 100
        assert_expected_balances(user_addr, validator_addr, 250, 53, 0, 100, 99, 247, 98, 152);

        // ===== End epoch 3, start epoch 4
        new_epoch();
        shared_stake::crank_on_new_epoch(validator_addr);

        // No reward received, pending_active moves to active
        // No reward was received because the reward rate is 1%, thus there must be a minimum of 100 in a balance for rewards to accrue
        assert_expected_balances(user_addr, validator_addr, 250, 153, 0, 0, 99, 247, 98, 152);

        // Fast-forward to our lockup cycle ending
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);

        // ===== End epoch 4, start epoch 5
        new_epoch();
        shared_stake::crank_on_new_epoch(validator_addr);

        // +1 reward received, pending_inactive moves to inactive
        // pending_inactive_shares go to 0, decreasing the total supply of shares by 98
        // user balance is corrected to 154
        assert_expected_balances(user_addr, validator_addr, 250, 154, 99, 0, 0, 149, 0, 154);

        // // Now that the stake is in inactive, it should be able to be withdrawn
        shared_stake::withdraw(user, validator_addr, 99);

        assert_expected_balances(user_addr, validator_addr, 349, 154, 0, 0, 0, 149, 0, 154);

    }

    #[test(aptos_framework = @0x1, validator = @0x123, user1 = @0x456, user2 = @0x789)]
    public entry fun test_two_users(aptos_framework: &signer, validator: &signer, user1: &signer, user2: &signer) {
        let validator_addr = signer::address_of(validator);
        let user1_addr = signer::address_of(user1);
        let user2_addr = signer::address_of(user2);

        intialize_test_state_two_users(aptos_framework, validator, user1, user2);

        aptos_coin::mint(aptos_framework, user1_addr, 10000000);
        aptos_coin::mint(aptos_framework, user2_addr, 10000000);

        shared_stake::deposit(user1, validator_addr, 1000000);
        assert_expected_balances(user1_addr, validator_addr, 9000000, 1000000, 0, 0, 0, 1000000, 0,1000000);

        shared_stake::deposit(user2, validator_addr, 500000);
        assert_expected_balances(user2_addr, validator_addr, 9500000, 1500000, 0, 0, 0, 1500000, 0,500000);

        // Minimum stake met, join validator set
        stake::join_validator_set(validator, validator_addr);

        // We should be in the pending_active validator set
        assert!(!stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);

        // ===== End the epoch 0, start epoch 1
        new_epoch();

        // We should now be in the active validator set
        assert!(stake::is_current_epoch_validator(validator_addr), EINCORRECT_VALIDATOR_STATE);
        assert!(stake::get_remaining_lockup_secs(validator_addr) == LOCKUP_CYCLE_SECONDS, 1);

        // Balances are unchanged
        assert_expected_balances(user1_addr, validator_addr, 9000000, 1500000, 0, 0, 0, 1500000, 0,1000000);
        assert_expected_balances(user2_addr, validator_addr, 9500000, 1500000, 0, 0, 0, 1500000, 0,500000);

        // ===== End epoch 1, earn our first reward, start epoch 2
        // If we do not call a shared_stake command, we must crank, otherwise shared_stake
        // balances will be outdated. (Crank updates balances.)
        new_epoch();
        shared_stake::crank_on_new_epoch(validator_addr);

        // The stake pool has gained 10% interest on its deposit
        assert_expected_balances(user1_addr, validator_addr, 9000000, 1650000, 0, 0, 0, 1500000, 0,1100000);
        assert_expected_balances(user2_addr, validator_addr, 9500000, 1650000, 0, 0, 0, 1500000, 0,550000);

        // Unlock some stake in both accounts
        // Unlock 200,000 in user1
        // Unlock 300,000 in user2
        shared_stake::unlock(user1, validator_addr, 200000);
        assert_expected_balances(user1_addr, validator_addr, 9000000, 1450001, 0, 0, 199999, 1500000, 181818,900000);

        shared_stake::unlock(user2, validator_addr, 300000);
        assert_expected_balances(user2_addr, validator_addr, 9500000, 1150002, 0, 0, 499998, 1500000, 454545, 250000);

        // Cancel 100,000 of user2's stake since the unlock period isn't over
        shared_stake::cancel_unlock(user2, validator_addr, 100000);
        assert_expected_balances(user2_addr, validator_addr, 9500000, 1250002, 0, 0, 399998, 1500000, 363636, 350000);

        // ===== End epoch 2, start epoch 3
        // Fast-forward to our lockup cycle ending, we'll be able to unlock coins this epoch
        timestamp::fast_forward_seconds(LOCKUP_CYCLE_SECONDS);
        new_epoch();
        shared_stake::crank_on_new_epoch(validator_addr);

        // The stake pool has accrued another 10%.
        // Balances accrue in their own pools separately, with stake in pending inactive being moved to inactive since the lockup ended
        assert_expected_balances(user1_addr, validator_addr, 9000000, 1375002, 439997, 0, 0, 1136364, 0, 990001);
        assert_expected_balances(user2_addr, validator_addr, 9500000, 1375002, 439997, 0, 0, 1136364, 0, 385000);

        // Withdraw some stake from user1
        shared_stake::withdraw(user1, validator_addr, 5000);
        assert_expected_balances(user1_addr, validator_addr, 9005000, 1375002, 434997, 0, 0, 1136364, 0, 990001);

        // Withdraw some stake from user2
        shared_stake::withdraw(user2, validator_addr, 50000);
        assert_expected_balances(user2_addr, validator_addr, 9550000, 1375002, 384997, 0, 0, 1136364, 0, 385000);

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

        new_epoch();

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

        new_epoch();

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

        new_epoch();

        shared_stake::unlock(user, validator_addr, 50);

        new_epoch();

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

        shared_stake::withdraw(user, validator_addr, 51);
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


    // // For testing purposes
    // let (_test_active_stake, _test_pending_active_stake, test_pending_inactive_shares, shares, user_staked_coins) = shared_stake::get_balances(validator_addr);
    // let staked_balance = shared_stake::get_stake_balance(validator_addr, user2_addr);
    // let (active, inactive, pending_active, pending_inactive) = stake::get_stake(validator_addr);
    // let user_coin_balance = coin::balance<AptosCoin>(user2_addr);
    // debug::print(&active);
    // debug::print(&inactive);
    // debug::print(&pending_active);
    // debug::print(&pending_inactive);
    // debug::print(&test_pending_inactive_shares);
    // debug::print(&staked_balance);
    // debug::print(&shares);
    // debug::print(&user_staked_coins);
    // debug::print(&user_coin_balance);

}