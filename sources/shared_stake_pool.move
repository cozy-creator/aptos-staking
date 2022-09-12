// Designed for single use, independent validators

// TODO: add a customizable percentage the operator can take out from rewards

// TODO: add specs

module openrails::shared_stake_pool {
    use std::signer;
    use std::vector;
    use aptos_std::pool_u64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::stake;
    use aptos_framework::reconfiguration;

    const MAX_SHAREHOLDERS: u64 = 65536;

    const ENO_ZERO_DEPOSITS: u64 = 1;
    const EINSUFFICIENT_BALANCE: u64 = 2;
    const ENOT_AUTHORIZED_ADDRESS: u64 = 3;
    const ENO_ZERO_WITHDRAWALS: u64 = 4;

    struct SharedStakePool has key {
        owner_cap: stake::OwnerCapability,
        pool: pool_u64::Pool,
        pending_active: SimpleMap<address, u64>,
        pending_active_list: vector<address>,
        pending_inactive: SimpleMap<address, u64>,
        pending_inactive_list: vector<address>,
        inactive: SimpleMap<address, u64>,
    }

    struct EpochTracker has key {
        epoch: u64,
        locked_until_secs: u64
    }

    struct OperatorInfo has key {
        /// The address of the operator of the stake pool
        operator_addr: address,
        /// Fee (in basis points) that is credited to the operator at every Epoch
        fee_bps: u64,
        /// How much APT the operator has accrued. When an operator wants to cash out this value is reset to 0.
        accrued_apt: u64,
    }

    // user entry functions

    public entry fun deposit(account: &signer, amount: u64) acquires SharedStakePool {
        let coin = coin::withdraw<AptosCoin>(account, amount);
        deposit_with_coins(signer::address_of(account), coin);
    }

    public fun deposit_with_coins(addr: address, coin: Coin<AptosCoin>) acquires SharedStakePool {
        let value = coin::value<AptosCoin>(&coin);
        assert!(value > 0, ENO_ZERO_DEPOSITS);

        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        stake::add_stake_with_cap(&stake_pool.owner_cap, coin);
        add_to_pending_active(addr, value);
    }

    fun add_to_pending_active(addr: address, amount: u64) acquires SharedStakePool {
        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        let pending_active = stake_pool.pending_active;

        if (simple_map::contains_key(&pending_active, &addr)) {
            let pending_balance = simple_map::borrow_mut<address, u64>(&mut pending_active, &addr);
            *pending_balance = *pending_balance + amount;
        }
        else {
            simple_map::add<address, u64>(&mut pending_active, addr, amount);
            vector::push_back(&mut stake_pool.pending_active_list, addr);
        }

    }

    public entry fun unlock(account: &signer, amount: u64) acquires SharedStakePool {
        let addr = signer::address_of(account);
        let (active, _inactive, _pending_active, _pending_inactive) = get_balances(addr);
        assert!(active >= amount, EINSUFFICIENT_BALANCE);

        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        let owner_cap = &stake_pool.owner_cap;
        stake::unlock_with_cap(amount, owner_cap);
        add_to_pending_inactive(addr, amount);
    }

    fun add_to_pending_inactive(addr: address, amount: u64) acquires SharedStakePool {
        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        let pending_inactive = stake_pool.pending_inactive;

        if (simple_map::contains_key(&pending_inactive, &addr)) {
            let pending_balance = simple_map::borrow_mut<address, u64>(&mut pending_inactive, &addr);
            *pending_balance = *pending_balance + amount;
        }
        else {
            simple_map::add<address, u64>(&mut pending_inactive, addr, amount);
            vector::push_back(&mut stake_pool.pending_inactive_list, addr);
        }
    }

    public entry fun withdraw(account: &signer, amount: u64) acquires EpochTracker, SharedStakePool {
        let coin = withdraw_to_coin(account, amount);
        coin::deposit<AptosCoin>(signer::address_of(account), coin);
    }

    public entry fun withdraw_to_coin(account: &signer, amount: u64): Coin<AptosCoin> acquires EpochTracker, SharedStakePool {
        assert!(amount > 0, ENO_ZERO_WITHDRAWALS);

        // this ensures our inactive is up to date from any potential unlock
        crank_on_new_epoch();

        let addr = signer::address_of(account);
        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        assert!(simple_map::contains_key(&stake_pool.inactive, &addr), EINSUFFICIENT_BALANCE);
        let withdrawable_balance = simple_map::borrow_mut(&mut stake_pool.inactive, &addr);
        assert!(*withdrawable_balance >= amount, EINSUFFICIENT_BALANCE);

        let coin = stake::withdraw_with_cap(&stake_pool.owner_cap, amount);
        *withdrawable_balance = *withdrawable_balance - amount;

        if (*withdrawable_balance == 0) {
            simple_map::remove(&mut stake_pool.inactive, &addr);
        };

        freeze(stake_pool);
        update_balance();

        coin
    }

    public fun get_balances(addr: address): (u64, u64, u64, u64) acquires SharedStakePool {
        update_balance();

        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);

        let pending_inactive = if (simple_map::contains_key(&stake_pool.pending_inactive, &addr)) {
            *simple_map::borrow(&stake_pool.pending_inactive, &addr)
        }
        else {
            0
        };

        let inactive = if (simple_map::contains_key(&stake_pool.inactive, &addr)) {
            *simple_map::borrow(&stake_pool.inactive, &addr)
        }
        else {
            0
        };

        let pending_active = if (simple_map::contains_key(&stake_pool.pending_active, &addr)) {
            *simple_map::borrow(&stake_pool.pending_active, &addr)
        }
        else {
            0
        };

        let active = pool_u64::balance(&stake_pool.pool, addr) - pending_inactive;

        (active, inactive, pending_active, pending_inactive)
    }


    // This should be run once every epoch, otherwise new stakers will not earn interest for that epoch,
    // and unlocking stakers will continue to earn interest
    // Its core logic always only executes once per epoch; there is no harm to calling it multiple times
    public fun crank_on_new_epoch() acquires EpochTracker, SharedStakePool {
        let current_epoch = reconfiguration::current_epoch();
        let epoch_tracker = borrow_global_mut<EpochTracker>(@stake_pool_address);

        // Ensures crank can only run once per epoch
        if (current_epoch <= epoch_tracker.epoch) return;
        epoch_tracker.epoch = current_epoch;

        // make sure our balance is current before we issue shares
        update_balance();

        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        move_pending_active_to_active(stake_pool);

        let lockup_secs = stake::get_lockup_secs(@stake_pool_address);
        // This means a lockup event occurred
        // TODO: this is flawed; an IncreaseLockupEvent might have also caused the lockup time to go up,
        // in addition to an actual lockup expiration. This module never calls the increase_lockup_with_cap
        // function, so it should be impossible for this that event to happen, but we should always check
        // just to be certain
        // I created an issue which should resolve this https://github.com/aptos-labs/aptos-core/issues/4080
        if (lockup_secs > epoch_tracker.locked_until_secs) {
            epoch_tracker.locked_until_secs = lockup_secs;
            move_pending_inactive_to_inactive(stake_pool);
        }
    }

    fun update_balance() acquires SharedStakePool {
        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        let (active, _inactive, _pending_active, pending_inactive) = stake::get_stake(@stake_pool_address);
        // These are the only balances that earn a StakePool interest
        let total_coins = active + pending_inactive;
        pool_u64::update_total_coins(&mut stake_pool.pool, total_coins);
    }

    // crank sub-function
    fun move_pending_active_to_active(stake_pool: &mut SharedStakePool) {
        let addresses = stake_pool.pending_active_list;
        let pending_active = stake_pool.pending_active;
        let pool = &mut stake_pool.pool;

        let i = 0;
        let len = vector::length(&addresses);
        while (i < len) {
            let addr = vector::borrow(&mut addresses, i);
            let pending_balance = simple_map::borrow(&mut pending_active, addr);

            let active_balance = if (simple_map::contains_key(&pending_active, addr)) {
                *simple_map::borrow_mut(&mut pending_active, addr)
            }
            else {
                0
            };

            // active balance begins earning interest
            pool_u64::buy_in(pool, *addr, active_balance);
        };
        stake_pool.pending_active = simple_map::create<address, u64>();
    }

    // crank sub-function
    fun move_pending_inactive_to_inactive(stake_pool: &mut SharedStakePool) {
        let addresses = stake_pool.pending_inactive_list;
        let pending_inactive = stake_pool.pending_inactive;
        let inactive = stake_pool.inactive;
        let pool = &mut stake_pool.pool;

        let i = 0;
        let len = vector::length(&addresses);
        while (i < len) {
            let addr = vector::borrow(&mut addresses, i);
            let pending_balance = simple_map::borrow(&mut pending_inactive, addr);

            // available_balance no longer earns interest, and is considered redeemed
            let shares = pool_u64::amount_to_shares(pool, *pending_balance);
            let redeemed_coins = pool_u64::redeem_shares(pool, *addr, shares);

            if (simple_map::contains_key(&inactive, addr)) {
                let available_balance = simple_map::borrow_mut(&mut inactive, addr);
                *available_balance = *available_balance + redeemed_coins;
            }
            else {
                simple_map::add(&mut inactive, *addr, redeemed_coins);
            }
        };
        stake_pool.pending_inactive = simple_map::create<address, u64>();
    }

    /// This function must be called every epoch to update how much APT the operator is credited
    fun update_operator_balance() acquires SharedStakePool, OperatorInfo {
        let operator_addr = stake::get_operator(@stake_pool_address);
        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);

        // Assuming operator initially deposited 0 APT, their comission is a linear function on the accrued interest
        let operator_info = borrow_global_mut<OperatorInfo>(operator_addr);
        let operator_fee = operator_info.fee_bps;
        let accrued_apt = operator_info.accrued_apt;
        let interest = pool_u64::total_coins(&stake_pool.pool) / pool_u64::total_shares(&stake_pool.pool);
        accrued_apt = (interest * operator_fee) - accrued_apt;
    }

    fun collect_operator_fee(operator_signer: &signer) acquires SharedStakePool, EpochTracker, OperatorInfo {
        let operator_addr = stake::get_operator(@stake_pool_address);
        assert!(signer::address_of(operator_signer) == operator_addr, ENOT_AUTHORIZED_ADDRESS);
        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        let operator_info = borrow_global<OperatorInfo>(operator_addr);
        let accrued_apt = operator_info.accrued_apt;
        withdraw(operator_signer, accrued_apt);
    }

    // Commission changes are delayed and take effect on the next epoch
    // There are validators on Solana which will set their commission to 0% then raise it briefly to
    // 10% right before an epoch end. Our logic prevents this abusive behavior.
    public fun change_operator_fee(operator_signer: &signer, new_comission: u64) acquires OperatorInfo {
        let operator_addr = stake::get_operator(@stake_pool_address);
        assert!(signer::address_of(operator_signer) == operator_addr,ENOT_AUTHORIZED_ADDRESS);
        let operator_fee = &mut borrow_global_mut<OperatorInfo>(operator_addr).fee_bps;
        *operator_fee = new_comission;
    }

    // admin functions

    public entry fun change_operator(account: &signer, new_operator: address) acquires SharedStakePool {
        let addr = signer::address_of(account);
        assert!(addr == @stake_pool_address, ENOT_AUTHORIZED_ADDRESS);

        let owner_cap = &borrow_global_mut<SharedStakePool>(addr).owner_cap;
        stake::set_operator_with_cap(owner_cap, new_operator);
    }

    // Initializer; only called upon depoyment
    fun init_module(this: &signer) {
        let addr = signer::address_of(this);
        stake::initialize_stake_owner(this, 0, addr, addr);
        let owner_cap = stake::extract_owner_cap(this);
        let pool = pool_u64::create(MAX_SHAREHOLDERS);
        move_to(this, SharedStakePool {
            owner_cap,
            pool,
            pending_active: simple_map::create<address, u64>(),
            pending_active_list: vector::empty<address>(),
            pending_inactive: simple_map::create<address, u64>(),
            pending_inactive_list: vector::empty<address>(),
            inactive: simple_map::create<address, u64>()
        });

        move_to(this, EpochTracker {
            epoch: reconfiguration::current_epoch(),
            locked_until_secs: stake::get_lockup_secs(addr)
        });

        move_to(this, OperatorInfo {
            operator_addr: addr,
            fee_bps: 5,
            accrued_apt: 0
        });
    }
}
