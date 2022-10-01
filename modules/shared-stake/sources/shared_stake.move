// Designed for independent validators and validator-networks (liquid staking protocols)
// There is no limit to the number of individual stakers, however
// only 65,536 users can deposit or stake per shared_stake_pool per epoch

module openrails::shared_stake {
    use std::signer;
    use std::vector;
    use std::error;
    use std::option::{Self, Option};
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::stake;
    use aptos_framework::reconfiguration;
    use aptos_framework::timestamp;

    const MAX_VECTOR: u64 = 65536;
    // Seconds per month, assuming 1 month = 30 days
    const MONTH_SECS: u64 = 2592000;
    /// Conversion factor between seconds and microseconds
    const MICRO_CONVERSION_FACTOR: u64 = 1000000;

    // Error enums. Move does not yet support proper enums
    const EALREADY_REGISTERED: u64 = 0;
    const ENO_ZERO_DEPOSITS: u64 = 1;
    const EINSUFFICIENT_BALANCE: u64 = 2;
    const ENOT_AUTHORIZED_ADDRESS: u64 = 3;
    const EACCOUNT_NOT_FOUND: u64 = 4;
    const EINVALID_PERFORMANCE_FEE: u64 = 5;
    const EGOVERNANCE_NOT_FOUND: u64 = 6;
    const ENO_SHARE_CHEST_FOUND: u64 = 7;
    const ENO_SHARE_FOUND: u64 = 8;

    /// Validator status enums.
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    struct SharedStakePool has key {
        owner_cap: stake::OwnerCapability,
        pending_inactive_shares: IterableMap,
        inactive_coins: IterableMap,
        balances: Balances,
        share_to_unlock_next_epoch: u64,
        operator_agreement: OperatorAgreement,
        pending_operator_agreement: Option<OperatorAgreement>,
        validator_status: u64,
        performance_log: vector<u128>
    }

    struct TotalValueLocked has key {
        coins: u128,
        shares: u128
    }

    // All of our public interface values are priced in APT (Aptos coin) not shares; shares
    // are our own internal ledger, and their values do not need to be exposed to users
    // share.value represents fractional ownership of a stake pool, it is not the number of
    // APT (Aptos coin) that that share is redeemable for.
    // I.e., if you have share.value = 10, out of a total pool with 100 shares, then you own
    // 10% of that stake pool's staked APT, whatever that amount is.
    struct Share has store {
        addr: address,
        value: u64
    }

    struct ShareChest has key {
        inner: vector<Share>
    }

    struct IterableMap has store, drop {
        map: SimpleMap<address, u64>,
        list: vector<address>
    }

    // These balances are cached versions of the same coin values in stake::StakePool
    struct Balances has store {
        active: u64,
        pending_active: u64,
        pending_inactive_shares: u64,
    }

    struct EpochTracker has key {
        epoch: u64,
        locked_until_secs: u64,
    }

    struct OperatorAgreement has store, drop {
        operator: address,
        monthly_fee_usd: u64,
        performance_fee_bps: u64,
        last_paid_secs: u64,
        epoch_effective: u64
    }

    struct GovernanceCapability has key, store {
        pool_addr: address
    }

    // ================= User entry functions =================

    // Call to create a new SharedStakePool. Only one can exist per address
    public entry fun initialize(this: &signer) {
        let addr = signer::address_of(this);
        assert!(!exists<SharedStakePool>(addr), error::invalid_argument(EALREADY_REGISTERED));

        stake::initialize_stake_owner(this, 0, addr, addr);

        let owner_cap = stake::extract_owner_cap(this);

        move_to(this, SharedStakePool {
            owner_cap,
            pending_inactive_shares: IterableMap {
                map: simple_map::create<address, u64>(),
                list: vector::empty<address>()
            },
            inactive_coins: IterableMap {
                map: simple_map::create<address, u64>(),
                list: vector::empty<address>()
            },
            balances: Balances {
                active: 0,
                pending_active: 0,
                pending_inactive_shares: 0,
            },
            share_to_unlock_next_epoch: 0,
            operator_agreement: OperatorAgreement {
                operator: addr,
                monthly_fee_usd: 0,
                performance_fee_bps: 500,
                last_paid_secs: 0,
                epoch_effective: 0
            },
            pending_operator_agreement: option::none(),
            validator_status: VALIDATOR_STATUS_INACTIVE,
            performance_log: vector::empty<u128>()
        });

        move_to(this, TotalValueLocked {
            coins: 0,
            shares: 0
        });

        move_to(this, EpochTracker {
            epoch: reconfiguration::current_epoch(),
            locked_until_secs: stake::get_lockup_secs(addr)
        });

        move_to(this, GovernanceCapability {
            pool_addr: addr
        });
    }

    public entry fun deposit(account: &signer, this: address, amount: u64)
    acquires EpochTracker, SharedStakePool, TotalValueLocked, ShareChest {
        let coins = coin::withdraw<AptosCoin>(account, amount);
        let share = deposit_with_coins(this, coins);

        let addr = signer::address_of(account);
        if (!exists<ShareChest>(addr)) {
            move_to(account, ShareChest { inner: vector::empty<Share>() });
        };

        store_share(addr, share);
    }

    public fun deposit_with_coins(this: address, coins: Coin<AptosCoin>): Share
    acquires EpochTracker, SharedStakePool, TotalValueLocked, ShareChest {
        crank_on_new_epoch(this);
        let coin_value = coin::value<AptosCoin>(&coins);
        if (coin_value == 0) {
            coin::destroy_zero<AptosCoin>(coins);
            return Share { addr: this, value: 0 }
        };

        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        stake::add_stake_with_cap(&stake_pool.owner_cap, coins);

        if (stake::is_current_epoch_validator(this)) {
            stake_pool.balances.pending_active = stake_pool.balances.pending_active + coin_value;
        } else {
            stake_pool.balances.active = stake_pool.balances.active + coin_value;
        };

        let tvl = borrow_global_mut<TotalValueLocked>(this);
        let share_value = apt_to_share(tvl, coin_value);
        let share = Share { addr: this, value: share_value };

        tvl.coins = tvl.coins + (coin_value as u128);
        tvl.shares = tvl.shares + (share_value as u128);

        share
    }

    public entry fun unlock(account: &signer, this: address, coin_value: u64)
    acquires EpochTracker, SharedStakePool, TotalValueLocked, ShareChest {
        let addr = signer::address_of(account);
        let share = extract_share(account, this, coin_value);
        unlock_with_share(addr, share);
    }

    public fun unlock_with_share(addr: address, share: Share)
    acquires EpochTracker, SharedStakePool, TotalValueLocked, ShareChest {
        let Share { addr: this, value: share_value } = share;
        crank_on_new_epoch(this);

        let tvl = borrow_global<TotalValueLocked>(this);
        let coin_value = share_to_apt(tvl, share_value);
        let (active, _, _, _) = stake::get_stake(this);
        let stake_pool = borrow_global_mut<SharedStakePool>(this);

        // this stake_pool doesn't have enough active balance to unlock; queue the unlock
        if (active < coin_value) {
            stake_pool.share_to_unlock_next_epoch = stake_pool.share_to_unlock_next_epoch + share_value;
        } else {
            stake::unlock_with_cap(coin_value, &stake_pool.owner_cap);
            stake_pool.balances.active = stake_pool.balances.active - coin_value;
        };

        // We store the share_value for now, so that pending_inactive will continue to earn
        // interest while it is unlocking
        // We keep a record of all users we owe pending_unlocked money to and how much
        //
        // Note: even if our validator is not active, aptos_framework::stake will still move stake from
        // active to pending_inactive, rather than straight to inactive
        add_to_iterable_map(&mut stake_pool.pending_inactive_shares, addr, share_value);
        stake_pool.balances.pending_inactive_shares = stake_pool.balances.pending_inactive_shares + share_value;
    }

    public entry fun cancel_unlock(account: &signer, this: address, amount: u64)
    acquires SharedStakePool, EpochTracker, ShareChest, TotalValueLocked {
        let addr = signer::address_of(account);
        let share = cancel_unlock_to_share(account, this, amount);
        store_share(addr, share);
    }

    public fun cancel_unlock_to_share(account: &signer, this: address, coin_value: u64): Share
    acquires SharedStakePool, EpochTracker, ShareChest, TotalValueLocked {
        crank_on_new_epoch(this);
        let addr = signer::address_of(account);
        let tvl = borrow_global<TotalValueLocked>(this);
        let share_value = apt_to_share(tvl, coin_value);
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        let pending_inactive_share_value = *simple_map::borrow(&stake_pool.pending_inactive_shares.map, &addr);

        assert!(share_value <= pending_inactive_share_value, error::invalid_argument(EINSUFFICIENT_BALANCE));

        if (stake_pool.share_to_unlock_next_epoch >= share_value) {
            stake_pool.share_to_unlock_next_epoch = stake_pool.share_to_unlock_next_epoch - share_value;
        } else {
            stake::reactivate_stake_with_cap(&stake_pool.owner_cap, coin_value);
            stake_pool.balances.active = stake_pool.balances.active + coin_value;
        };

        subtract_from_iterable_map(&mut stake_pool.pending_inactive_shares, addr, share_value);
        stake_pool.balances.pending_inactive_shares = stake_pool.balances.pending_inactive_shares - share_value;

        Share { addr: this, value: share_value }
    }

    public entry fun withdraw(account: &signer, this: address, amount: u64)
    acquires EpochTracker, SharedStakePool, TotalValueLocked, ShareChest {
        let coin = withdraw_to_coins(account, this, amount);
        coin::deposit<AptosCoin>(signer::address_of(account), coin);
    }

    public entry fun withdraw_to_coins(account: &signer, this: address, coin_value: u64): Coin<AptosCoin>
    acquires EpochTracker, SharedStakePool, TotalValueLocked, ShareChest {
        crank_on_new_epoch(this);
        if (coin_value == 0) {
            return coin::zero<AptosCoin>()
        };

        let addr = signer::address_of(account);
        let stake_pool = borrow_global<SharedStakePool>(this);
        let epoch_tracker = borrow_global<EpochTracker>(this);

        if (stake_pool.validator_status == VALIDATOR_STATUS_INACTIVE) {
            // In this case, we can move coins straight from active -> pending_inactive -> inactive -> withdrawn
            if (timestamp::now_seconds() >= epoch_tracker.locked_until_secs) {
                let inactive_coins_value = if (simple_map::contains_key(&stake_pool.inactive_coins.map, &addr)) {
                    *simple_map::borrow(&stake_pool.inactive_coins.map, &addr)
                }
                else {
                    0
                };

                //we only dip into a user's active balance if their inactive balance is insufficent
                if (coin_value > inactive_coins_value) {
                    unlock(account, this, coin_value - inactive_coins_value);
                };
            };
        };

        // We have to re-acquire these here, as the above functions may have modified them
        // This is a global storage protection rule Move puts into place
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        let epoch_tracker = borrow_global<EpochTracker>(this);

        // In this edge-case, the stake::withdraw_with_cap function we call below will move
        // everything out of pending_inactive. We account for this here.
        if (stake_pool.validator_status == VALIDATOR_STATUS_INACTIVE && timestamp::now_seconds() >= epoch_tracker.locked_until_secs && stake_pool.balances.pending_inactive_shares > 0) {
            let tvl = borrow_global_mut<TotalValueLocked>(this);
            move_pending_inactive_to_inactive(stake_pool, tvl);
        };

        assert!(simple_map::contains_key(&stake_pool.inactive_coins.map, &addr), error::not_found(EACCOUNT_NOT_FOUND));

        let withdrawable_balance = simple_map::borrow(&stake_pool.inactive_coins.map, &addr);
        // Note: aptos_framework::stake will set amount = withdrawable_balance in this case, however
        // I think this behavior is wrong. If another module asks for 1000 APT but they can only withdraw
        // 500, it's best to give them an error rather than giving them 500.
        assert!(*withdrawable_balance >= coin_value, error::invalid_argument(EINSUFFICIENT_BALANCE));

        subtract_from_iterable_map(&mut stake_pool.inactive_coins, addr, coin_value);

        let coins = stake::withdraw_with_cap(&stake_pool.owner_cap, coin_value);
        coins
    }

    // ============== Helper functions ==============

    public fun share_to_apt(tvl: &TotalValueLocked, amount: u64): u64 {
        (((amount as u128) / share_apt_ratio(tvl)) as u64)
    }

    public fun apt_to_share(tvl: &TotalValueLocked, amount: u64): u64 {
        (((amount as u128) * share_apt_ratio(tvl)) as u64)
    }

    // We assume that crank_on_new_epoch has been called, otherwise this will
    // understimate the number of coins we have, and give an inferior price
    // This is not a security risk, but if slashing is ever introduced, this should be changed
    // to check the crank, as it might be possible we have fewer coins than expected
    public fun share_apt_ratio(tvl: &TotalValueLocked): u128 {
        if (tvl.coins == 0 || tvl.shares == 0) {
            1
        } else {
            ((tvl.shares as u128) / (tvl.coins as u128))
        }
    }

    // TO DO: query a switchboard oracle to find the USD price at the given timestamp
    // We should also add in the option to swap rewards into other coins
    public fun convert_usd_to_apt(amount: u64, _time: u64): u64 {
        amount
    }

    // ================= Interact with ShareChest =================

    public fun store_share(user_addr: address, share: Share) acquires ShareChest {
        assert!(exists<ShareChest>(user_addr), ENO_SHARE_CHEST_FOUND);
        let share_chest = &mut borrow_global_mut<ShareChest>(user_addr).inner;

        // This ensures that every share in our share chest is from a unique pool address
        let i = 0;
        let len = vector::length(share_chest);
        while (i < len) {
            let stored_share = vector::borrow_mut<Share>(share_chest, i);

            if (share.addr == stored_share.addr) {
                stored_share.value = stored_share.value + share.value;
                let Share { addr: _, value: _ } = share;
                return
            };

            i = i + 1;
        };

        vector::push_back<Share>(share_chest, share);
    }

    // coin_value is the number of coins you want to withdraw, not the number of shares
    public fun extract_share(account: &signer, pool_addr: address, coin_value: u64): Share acquires ShareChest, TotalValueLocked {
        let user_addr = signer::address_of(account);
        assert!(exists<ShareChest>(user_addr), ENO_SHARE_CHEST_FOUND);
        let share_chest = &mut borrow_global_mut<ShareChest>(user_addr).inner;
        let tvl = borrow_global<TotalValueLocked>(pool_addr);
        let share_value = apt_to_share(tvl, coin_value);

        let i = 0;
        let len = vector::length(share_chest);
        while (i < len) {
            let stored_share = vector::borrow_mut<Share>(share_chest, i);

            if (pool_addr == stored_share.addr) {
                assert!(stored_share.value >= share_value, error::invalid_argument(EINSUFFICIENT_BALANCE));
                stored_share.value = stored_share.value - share_value;

                if (stored_share.value == 0) {
                    let old_share = vector::remove<Share>(share_chest, i);
                    let Share { addr: _, value: _ } = old_share;
                };

                let share = Share { addr: pool_addr, value: share_value };
                return share
            };

            i = i + 1;
        };

        assert!(false, error::invalid_argument(ENO_SHARE_FOUND));
        Share { addr: pool_addr, value: 0 }
    }

    // Returns a user's staked APT balance in the specified pool address.
    // This includes pending_active and active balances, but not pending_inactive or inactive
    // balances. Remember that share-resources are destroyed when you unlock
    public fun get_stake_balance(pool_addr: address, user_addr: address): u64 acquires ShareChest, TotalValueLocked {
        if (!exists<ShareChest>(user_addr)) {
            return 0
        };

        let share_chest = &borrow_global<ShareChest>(user_addr).inner;
        let len = vector::length(share_chest);
        let i = 0;
        while (i < len) {
            let stored_share = vector::borrow(share_chest, i);
            if (stored_share.addr == pool_addr) {
                return (get_stake_balance_of_share(stored_share))
            };

            i = i + 1;
        };

        return 0
    }

    public fun get_stake_balance_of_share(share: &Share): u64 acquires TotalValueLocked {
        let tvl = borrow_global<TotalValueLocked>(share.addr);
        return share_to_apt(tvl, share.value)
    }

    // ================= Crank Functions =================

    // This should be run once every epoch, otherwise:
    // - new stakers will not earn interest for the missed epoch,
    // - inactive stakers will continue to earn interest for the missed epoch,
    // - operators will not be paid for the missed epoch
    // This function must be executed every epoch before any deposit, unlock, unlock_cancel, or withdraw
    // function calls by a user, otherwise the price used will be outdated.
    // As required for all crank functions:
    // - This function cannot abort
    // - This function is indempotent; calling it more than once per epoch does nothing
    public entry fun crank_on_new_epoch(this: address) acquires EpochTracker, SharedStakePool, TotalValueLocked, ShareChest {
        let current_epoch = reconfiguration::current_epoch();
        let epoch_tracker = borrow_global_mut<EpochTracker>(this);

        // Ensures crank can only run once per epoch
        if (current_epoch <= epoch_tracker.epoch) return;
        epoch_tracker.epoch = current_epoch;

        let (active, _, _, pending_inactive) = stake::get_stake(this);

        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        let tvl = borrow_global_mut<TotalValueLocked>(this);
        // This timestamp going up means our validator's lockup was renewed, so an unlock event
        // occurred.
        // In order for this to be logically sound, we need to make sure that all IncreaseLockupEvent
        // events go through our module, so we can adjust our EpochTracker.locked_until_secs accordinginly.
        //
        // I added the pending_inactive check as a double-measure; all pending_inactive stake should
        // have been emptied out by aptos_framework::stake when an unlock event occurs
        //
        // We deliberately process this prior to updating our tvl for the last epoch. This means
        // that unlocking stakers will not earn interest on their stake for the final epoch. This
        // compensates for the pending_active stakers who do earn interest on the one epoch where they
        // are not qualified for. Also, this allows us to make sure there is always enough coins
        // in stake_pool.inactive to meet all withdrawls. See below in this function.
        let locked_until_secs = stake::get_lockup_secs(this);
        if ((locked_until_secs > epoch_tracker.locked_until_secs) && (pending_inactive == 0)) {
            epoch_tracker.locked_until_secs = locked_until_secs;
            move_pending_inactive_to_inactive(stake_pool, tvl);
        };

        // calculate rewards for the previous epoch
        let stake_before_rewards = stake_pool.balances.active + stake_pool.balances.pending_active;
        let rewards_amount = if (active >= stake_before_rewards) {
            active - stake_before_rewards
        }
        else {
            // unless Aptos implements slashing, this branch is impossible to reach
            // Move does not support negative numbers
            0
        };

        let performance = (rewards_amount as u128) / (stake_before_rewards as u128);
        vector::push_back(&mut stake_pool.performance_log, performance);
        // only stores the last 10 epochs
        if (vector::length(&stake_pool.performance_log) > 10) {
            vector::remove(&mut stake_pool.performance_log, 0);
        };

        // Update our coins balance to account for rewards
        let tvl = borrow_global_mut<TotalValueLocked>(this);
        tvl.coins = (active as u128) + (pending_inactive as u128);

        // issue shares to pay the operator
        let operator_fee = calculate_operator_fee(this, rewards_amount, &stake_pool.operator_agreement, stake_pool.validator_status);
        issue_shares(this, stake::get_operator(this), operator_fee);

        // we need to reacquire this, because issue_shares just changed it
        let tvl = borrow_global_mut<TotalValueLocked>(this);

        // Schedule unlocking any stake we didn't have enough stake.active for last epoch
        if (stake_pool.share_to_unlock_next_epoch > 0) {
            let coin_value = share_to_apt(tvl, stake_pool.share_to_unlock_next_epoch);
            stake::unlock_with_cap(coin_value, &stake_pool.owner_cap);
            stake_pool.share_to_unlock_next_epoch = 0;
        };

        // Make sure we have enough stake pending_inactive to account for interest earned on
        // pending_inactive stake. This ensures we can meet all withdrawls
        let coin_value = share_to_apt(tvl, stake_pool.balances.pending_inactive_shares);
        if (coin_value > pending_inactive) {
            let pending_inactive_interest = coin_value - pending_inactive;
            stake::unlock_with_cap(pending_inactive_interest, &stake_pool.owner_cap);
        };
        // Note: the above stake unlocks have already been accounted for in
        // stake_pool.balances.pending_inactive_shares, and we do not need to update that value
        // here.

        // update our cached values
        let (active, _, pending_active, _) = stake::get_stake(this);
        stake_pool.balances.active = active;
        stake_pool.balances.pending_active = pending_active;
        stake_pool.operator_agreement.last_paid_secs = reconfiguration::last_reconfiguration_time() / MICRO_CONVERSION_FACTOR;
        stake_pool.validator_status = stake::get_validator_state(this);

        // Check if we have a pending operator agreement to switch to
        if (option::is_some(&stake_pool.pending_operator_agreement)) {
            let epoch_effective = option::borrow(&stake_pool.pending_operator_agreement).epoch_effective;
            if (epoch_effective <= current_epoch) {
                activate_new_operator_agreement(stake_pool);
            }
        };
    }

    fun activate_new_operator_agreement(stake_pool: &mut SharedStakePool) {
        // check if this agreement changes the operator
        let new_operator = option::borrow(&stake_pool.pending_operator_agreement).operator;
        if (new_operator != stake_pool.operator_agreement.operator) {
            stake::set_operator_with_cap(&stake_pool.owner_cap, new_operator);
        };

        stake_pool.operator_agreement = option::extract(&mut stake_pool.pending_operator_agreement);
    }

    // crank sub-function. Cannot abort
    // rewards_amount is the total APT earned by this operator in the previous epoch
    // operators only get paid while their validator is part of the active or pending_inactive_map set,
    // and are only paid in arrears for the epoch prior to the current one
    public fun calculate_operator_fee(this: address, rewards_amount: u64, operator_agreement: &OperatorAgreement, previous_status: u64): u64 {
        let current_status = stake::get_validator_state(this);
        let epoch_start_secs = reconfiguration::last_reconfiguration_time() / MICRO_CONVERSION_FACTOR;
        let operator_fee = 0;

        // we just joined the validator set; mark to pay the operator on next time stamp
        if ((previous_status == VALIDATOR_STATUS_PENDING_ACTIVE || previous_status == VALIDATOR_STATUS_INACTIVE) && (current_status == VALIDATOR_STATUS_ACTIVE || current_status == VALIDATOR_STATUS_PENDING_INACTIVE)) {
            // do nothing
        }
        // we have been part of the validator set at least one full epoch now, or
        // the validator just left the set; do a final payout to the operator until we rejoin the next set
        else if (previous_status == VALIDATOR_STATUS_ACTIVE || previous_status == VALIDATOR_STATUS_PENDING_INACTIVE) {
            let pay_period_secs = if (epoch_start_secs > operator_agreement.last_paid_secs) {
                epoch_start_secs - operator_agreement.last_paid_secs
            }
            else {
                0
            };

            let fixed_fee_usd = ((operator_agreement.monthly_fee_usd as u128) * (pay_period_secs as u128) / (MONTH_SECS as u128) as u64);
            let _fixed_fee_apt = convert_usd_to_apt((fixed_fee_usd as u64), epoch_start_secs);
            let incentive_fee_apt = ((rewards_amount as u128) * (operator_agreement.performance_fee_bps as u128) / 10000 as u64);

            // TO DO: when convert_usd_to_apt is implemented, start including the fixed fee as well
            operator_fee = incentive_fee_apt; // + _fixed_fee_apt;
        };

        (operator_fee as u64)
    }

    // note that coin_value is the argument, not share_value. The share_value will be
    // calculated from the coin_value
    fun issue_shares(pool_addr: address, recipient: address, coin_value: u64) acquires TotalValueLocked, ShareChest {
        // if the recipient is not setup to receive shares, we give them nothing
        // it's important that the recipient setup their ShareChest ahead of time if they want us
        // to pay them.
        if (!exists<ShareChest>(recipient)) {
            return
        };

        let tvl = borrow_global_mut<TotalValueLocked>(pool_addr);
        let share_value = ((coin_value as u128) * tvl.shares / (tvl.coins - (coin_value as u128)) as u64);

        let share = Share { addr: pool_addr, value: (share_value as u64) };
        tvl.shares = tvl.shares + (share_value as u128);
        store_share(recipient, share);
    }

    // crank sub-function. Cannot abort
    fun move_pending_inactive_to_inactive(stake_pool: &mut SharedStakePool, tvl: &mut TotalValueLocked) {
        let addresses = stake_pool.pending_inactive_shares.list;
        let inactive_map = stake_pool.inactive_coins.map;

        let i = 0;
        let len = vector::length(&addresses);
        while (i < len) {
            let addr = vector::borrow(&addresses, i);
            let share_value = *simple_map::borrow(&stake_pool.pending_inactive_shares.map, addr);

            // inactive stake no longer earns interest, and is considered redeemed
            // convert all pending_inactive shares to inactive coins
            let coin_value = share_to_apt(tvl, share_value);
            tvl.coins = tvl.coins - (coin_value as u128);
            tvl.shares = tvl.shares - (share_value as u128);

            if (simple_map::contains_key(&inactive_map, addr)) {
                let inactive_balance = simple_map::borrow_mut(&mut inactive_map, addr);
                *inactive_balance = *inactive_balance + coin_value;
            }
            else {
                simple_map::add(&mut inactive_map, *addr, coin_value);
            };

            i = i + 1;
        };

        stake_pool.pending_inactive_shares.map = simple_map::create<address, u64>();
        stake_pool.pending_inactive_shares.list = vector::empty<address>();
        stake_pool.balances.pending_inactive_shares = 0;
    }

    // ================= Governance functions =================

    public fun extract_governance_cap(account: &signer): GovernanceCapability acquires GovernanceCapability {
        move_from<GovernanceCapability>(signer::address_of(account))
    }

    public fun deposit_governance_cap(account: &signer, governance_cap: GovernanceCapability) {
        move_to(account, governance_cap);
    }

    // Warning; destroying this means governance can never be used again for this SharedStakePool
    public fun destroy_governance_cap(governance_cap: GovernanceCapability) {
        let GovernanceCapability { pool_addr: _ } = governance_cap;
    }

    public fun get_governance_cap_pool_addr(governance_cap: &GovernanceCapability): address {
        governance_cap.pool_addr
    }

    public entry fun set_operator_agreement(account: &signer, operator: address, monthly_fee_usd: u64, performance_fee_bps: u64, epoch_effective: u64) acquires GovernanceCapability, SharedStakePool {
        let addr = signer::address_of(account);
        assert!(exists<GovernanceCapability>(addr), error::not_found(EGOVERNANCE_NOT_FOUND));
        let governance_cap = borrow_global<GovernanceCapability>(addr);
        let operator_agreement = create_operator_agreement(operator, monthly_fee_usd, performance_fee_bps, epoch_effective);
        set_operator_agreement_with_cap(governance_cap, operator_agreement);
    }

    public fun create_operator_agreement(operator: address, monthly_fee_usd: u64, performance_fee_bps: u64, epoch_effective: u64): OperatorAgreement {
        assert!(performance_fee_bps <= 10000, error::invalid_argument(EINVALID_PERFORMANCE_FEE));

        OperatorAgreement {
            operator,
            monthly_fee_usd,
            performance_fee_bps,
            epoch_effective,
            last_paid_secs: 0
        }
    }

    // Operator Agreement changes are queued and take effect at the start of the next epoch or later
    // There are validators on Solana which will set their commission to 0%, then raise it briefly to
    // 10% right before an epoch end to deceive stakers. Our logic prevents this abusive behavior.
    public fun set_operator_agreement_with_cap(governance_cap: &GovernanceCapability, operator_agreement: OperatorAgreement) acquires SharedStakePool {
        let this = governance_cap.pool_addr;
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        stake_pool.pending_operator_agreement = option::some(operator_agreement);

        // We can skip the queue if the validator is current inactive
        if (stake_pool.validator_status == VALIDATOR_STATUS_INACTIVE || stake_pool.validator_status == VALIDATOR_STATUS_PENDING_ACTIVE) {
            activate_new_operator_agreement(stake_pool);
        };
    }

    public entry fun set_delegated_voter(account: &signer, new_voter: address) acquires SharedStakePool, GovernanceCapability {
        let addr = signer::address_of(account);
        assert!(exists<GovernanceCapability>(addr), error::not_found(EGOVERNANCE_NOT_FOUND));
        let governance_cap = borrow_global<GovernanceCapability>(addr);
        set_delegated_voter_with_cap(governance_cap, new_voter);
    }

    public fun set_delegated_voter_with_cap(governance_cap: &GovernanceCapability, new_voter: address) acquires SharedStakePool {
        let this = governance_cap.pool_addr;
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        stake::set_delegated_voter_with_cap(&stake_pool.owner_cap, new_voter);
    }

    // the signing account must own the GovernanceCapability for this to work
    public entry fun increase_lockup(account: &signer) acquires GovernanceCapability, SharedStakePool, EpochTracker {
        let addr = signer::address_of(account);
        assert!(exists<GovernanceCapability>(addr), error::not_found(EGOVERNANCE_NOT_FOUND));
        let governance_cap = borrow_global<GovernanceCapability>(addr);
        increase_lockup_with_cap(governance_cap);
    }

    public fun increase_lockup_with_cap(governance_cap: &GovernanceCapability) acquires SharedStakePool, EpochTracker {
        let this = governance_cap.pool_addr;
        let stake_pool = borrow_global<SharedStakePool>(this);
        stake::increase_lockup_with_cap(&stake_pool.owner_cap);

        // crank_on_new_epoch uses increases in the locked_until_secs as an indicator that an unlock occurred
        // so we need to keep this up to date
        let epoch_tracker = borrow_global_mut<EpochTracker>(this);
        let new_locked_until_secs = stake::get_lockup_secs(this);
        epoch_tracker.locked_until_secs = new_locked_until_secs;
    }

    // ================= Iterable Map =================

    fun add_to_iterable_map(iterable_map: &mut IterableMap, addr: address, amount: u64) {
        let map = &mut iterable_map.map;

        // TO DO: make sure these balances are really being updated
        if (simple_map::contains_key(map, &addr)) {
            let balance = simple_map::borrow_mut(map, &addr);
            *balance = *balance + amount;
        }
        else {
            simple_map::add(map, addr, amount);
            vector::push_back(&mut iterable_map.list, addr);
        };
    }

    fun subtract_from_iterable_map(iterable_map: &mut IterableMap, addr: address, amount: u64) {
        let map = &mut iterable_map.map;

        assert!(simple_map::contains_key(map, &addr), error::invalid_argument(EACCOUNT_NOT_FOUND));

        // TO DO: make sure these balances are really being updated
        let balance = simple_map::borrow_mut(map, &addr);
        assert!(*balance >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));
        *balance = *balance - amount;

        if (*balance == 0) {
            simple_map::remove(map, &addr);
            let (exists, i) = vector::index_of(&iterable_map.list, &addr);
            if (exists) {
                vector::remove(&mut iterable_map.list, i);
            }
        };
    }

    // ================= For Testing =================

    #[test_only]
    const EINCORRECT_BALANCE: u64 = 9;

    #[test_only]
    public fun assert_balances(pool_addr: address, active: u64, pending_active: u64, pending_inactive_shares: u64) acquires SharedStakePool {
        let shared_stake_pool = borrow_global<SharedStakePool>(pool_addr);
        assert!(shared_stake_pool.balances.active == active, EINCORRECT_BALANCE);
        assert!(shared_stake_pool.balances.pending_active == pending_active, EINCORRECT_BALANCE);
        assert!(shared_stake_pool.balances.pending_inactive_shares == pending_inactive_shares, EINCORRECT_BALANCE);
    }
}