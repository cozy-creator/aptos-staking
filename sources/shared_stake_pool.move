// Designed for single use, independent validators

// TODO: add a customizable percentage the operator can take out from rewards

// TODO: add specs

// We need to consider; what if this StakePool is inactive? It may or may not always
// be part of a validator set. This SharedStakePool will still operate, even if it's
// not part of the current validator set

module openrails::shared_stake_pool {
    use std::signer;
    use std::vector;
    use std::error;
    use aptos_std::pool_u64;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::coin::{Self, Coin};
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::stake;
    use aptos_framework::reconfiguration;

    const MAX_SHAREHOLDERS: u64 = 65536;
    // Seconds per month, assuming 1 month = 30 days
    const MONTH_SECS: u64 = 2592000;
    /// Conversion factor between seconds and microseconds
    const MICRO_CONVERSION_FACTOR: u64 = 1000000;

    // Error enums. Move does not yet support proper enums
    const EALREADY_REGISTERED: u64 = 0;
    const ENO_ZERO_DEPOSITS: u64 = 1;
    const EINSUFFICIENT_BALANCE: u64 = 2;
    const ENOT_AUTHORIZED_ADDRESS: u64 = 3;
    const ENO_ZERO_WITHDRAWALS: u64 = 4;

    /// Validator status enums.
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    struct SharedStakePool has key {
        owner_cap: stake::OwnerCapability,
        pool: pool_u64::Pool,
        pending_active_map: SimpleMap<address, u64>,
        pending_active_list: vector<address>,
        pending_inactive_map: SimpleMap<address, u64>,
        pending_inactive_list: vector<address>,
        inactive_map: SimpleMap<address, u64>,
        inactive_list: vector<address>,
        // These balances are cached versions of the same coin values in stake::StakePool
        active: u64,
        inactive: u64,
        pending_active: u64,
        pending_inactive: u64
    }

    struct EpochTracker has key {
        epoch: u64,
        locked_until_secs: u64,
    }

    struct ValidatorStatus has key {
        status: u64
    }

    struct OperatorAgreement has key {
        monthly_fee_usd: u64,
        performance_fee_bps: u64,
        last_paid_secs: u64
    }

    // ================= User entry functions =================

    // Call to create a new SharedStakePool. Only one can exist per address
    public entry fun initialize(this: &signer) {
        let addr = signer::address_of(this);
        assert!(!exists<SharedStakePool>(addr), error::invalid_argument(EALREADY_REGISTERED));

        stake::initialize_stake_owner(this, 0, addr, addr);
        let owner_cap = stake::extract_owner_cap(this);
        let pool = pool_u64::create(MAX_SHAREHOLDERS);

        move_to(this, SharedStakePool {
            owner_cap,
            pool,
            pending_active_map: simple_map::create<address, u64>(),
            pending_active_list: vector::empty<address>(),
            pending_inactive_map: simple_map::create<address, u64>(),
            pending_inactive_list: vector::empty<address>(),
            inactive_map: simple_map::create<address, u64>(),
            inactive_list: vector::empty<address>(),
            active: 0,
            inactive: 0,
            pending_active: 0,
            pending_inactive: 0
        });

        move_to(this, EpochTracker {
            epoch: reconfiguration::current_epoch(),
            locked_until_secs: stake::get_lockup_secs(addr)
        });

        move_to(this, OperatorAgreement {
            monthly_fee_usd: 0,
            performance_fee_bps: 500,
            last_paid_secs: 0
        });
    }

    public entry fun deposit(account: &signer, this: address, amount: u64) acquires EpochTracker, SharedStakePool, ValidatorStatus, OperatorAgreement {
        let coins = coin::withdraw<AptosCoin>(account, amount);
        deposit_with_coins(this, signer::address_of(account), coins);
    }

    public fun deposit_with_coins(this: address, addr: address, coins: Coin<AptosCoin>) acquires EpochTracker, SharedStakePool, ValidatorStatus, OperatorAgreement {
        crank_on_new_epoch(this);
        let value = coin::value<AptosCoin>(&coins);
        assert!(value > 0, error::invalid_argument(ENO_ZERO_DEPOSITS));

        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        stake::add_stake_with_cap(&stake_pool.owner_cap, coins);
        add_to_pending_active(this, addr, value);
    }

    fun add_to_pending_active(this: address, addr: address, amount: u64) acquires SharedStakePool {
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        let pending_active_map = stake_pool.pending_active_map;

        if (simple_map::contains_key(&pending_active_map, &addr)) {
            let pending_balance = simple_map::borrow_mut<address, u64>(&mut pending_active_map, &addr);
            *pending_balance = *pending_balance + amount;
        }
        else {
            simple_map::add<address, u64>(&mut pending_active_map, addr, amount);
            vector::push_back(&mut stake_pool.pending_active_list, addr);
        };

        stake_pool.pending_active = stake_pool.pending_active + amount;
    }

    public entry fun unlock(account: &signer, this: address, amount: u64) acquires EpochTracker, SharedStakePool, ValidatorStatus, OperatorAgreement {
        crank_on_new_epoch(this);
        let addr = signer::address_of(account);
        let (active, _inactive, _pending_active, _pending_inactive) = get_balances(addr);
        assert!(active >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));

        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        let owner_cap = &stake_pool.owner_cap;
        stake::unlock_with_cap(amount, owner_cap);
        add_to_pending_inactive(this, addr, amount);
    }

    fun add_to_pending_inactive(this: address, addr: address, amount: u64) acquires SharedStakePool {
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        let pending_inactive_map = stake_pool.pending_inactive_map;

        if (simple_map::contains_key(&pending_inactive_map, &addr)) {
            let pending_balance = simple_map::borrow_mut<address, u64>(&mut pending_inactive_map, &addr);
            *pending_balance = *pending_balance + amount;
        }
        else {
            simple_map::add<address, u64>(&mut pending_inactive_map, addr, amount);
            vector::push_back(&mut stake_pool.pending_inactive_list, addr);
        };

        stake_pool.pending_inactive = stake_pool.pending_inactive + amount;
    }

    // TO DO
    public entry fun cancel_unlock() acquires SharedStakePool {

    }

    public entry fun withdraw(account: &signer, this: address, amount: u64) acquires EpochTracker, SharedStakePool {
        let coin = withdraw_to_coins(account, this, amount);
        coin::deposit<AptosCoin>(signer::address_of(account), coin);
    }

    public entry fun withdraw_to_coins(account: &signer, this: address, amount: u64): Coin<AptosCoin> acquires EpochTracker, SharedStakePool {
        // TO DO: return a zero coin

        crank_on_new_epoch(this);

        let addr = signer::address_of(account);
        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);
        assert!(simple_map::contains_key(&stake_pool.inactive_map, &addr), EINSUFFICIENT_BALANCE);
        let withdrawable_balance = simple_map::borrow_mut(&mut stake_pool.inactive_map, &addr);
        assert!(*withdrawable_balance >= amount, EINSUFFICIENT_BALANCE);

        let coins = stake::withdraw_with_cap(&stake_pool.owner_cap, amount);
        *withdrawable_balance = *withdrawable_balance - amount;

        if (*withdrawable_balance == 0) {
            simple_map::remove(&mut stake_pool.inactive_map, &addr);
        };

        freeze(stake_pool);
        update_balance();

        coins
    }

    public fun get_balances(addr: address): (u64, u64, u64, u64) acquires SharedStakePool {
        update_balance();

        let stake_pool = borrow_global_mut<SharedStakePool>(@stake_pool_address);

        let pending_inactive = if (simple_map::contains_key(&stake_pool.pending_inactive_map, &addr)) {
            *simple_map::borrow(&stake_pool.pending_inactive_map, &addr)
        }
        else {
            0
        };

        let inactive = if (simple_map::contains_key(&stake_pool.inactive_map, &addr)) {
            *simple_map::borrow(&stake_pool.inactive_map, &addr)
        }
        else {
            0
        };

        let pending_active = if (simple_map::contains_key(&stake_pool.pending_active_map, &addr)) {
            *simple_map::borrow(&stake_pool.pending_active_map, &addr)
        }
        else {
            0
        };

        let active = pool_u64::balance(&stake_pool.pool, addr) - pending_inactive;

        (active, inactive, pending_active, pending_inactive)
    }


    // This should be run once every epoch, otherwise:
    // - new stakers will not earn interest for the missed epoch,
    // - inactive stakers will continue to earn interest for the missed epoch,
    // - operators will not be paid for the missed epoch
    // This function must be executed every epoch before any deposit, unlock, unlock_cancel, or withdraw
    // function calls by a user, otherwise the price used will be outdated.
    // As required for all crank functions:
    // - This function cannot abort
    // - This function is indempotent; calling it more than once per epoch does nothing
    public fun crank_on_new_epoch(this: address) acquires EpochTracker, SharedStakePool, ValidatorStatus, OperatorAgreement {
        let current_epoch = reconfiguration::current_epoch();
        let epoch_tracker = borrow_global_mut<EpochTracker>(this);

        // Ensures crank can only run once per epoch
        if (current_epoch <= epoch_tracker.epoch) return;
        epoch_tracker.epoch = current_epoch;

        // calculate rewards for the previous epoch
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        let (active, _, _, _) = stake::get_stake(this);
        let stake_before_rewards = stake_pool.active + stake_pool.pending_active;
        let rewards_amount = if (active >= stake_before_rewards) {
            active - stake_before_rewards
        }
        else {
            // unless Aptos implements slashing, this branch is impossible to reach
            // Move does not support negative numbers
            0
        };
        let operator_fee = calculate_operator_fee(this, rewards_amount);

        // update total coin balance; excluding operator_fee and pending_active_map stake, which
        // will be added below
        pool_u64::update_total_coins(&mut stake_pool.pool, active + stake_pool.pending_inactive - stake_pool.pending_active - operator_fee);

        // issue shares to pay the operator
        pool_u64::buy_in(&mut stake_pool.pool, stake::get_operator(this), operator_fee);

        // issue shares for the stakers who activated this epoch
        move_pending_active_to_active(stake_pool);

        let locked_until_secs = stake::get_lockup_secs(this);
        // This timestamp going up means our validator's lockup was renewed, so an unlock event
        // occurred.
        // In order for this to be logically sound, we need to make sure that all IncreaseLockupEvent 
        // events go through our module, so we can adjust our EpochTracker.locked_until_secs accordinginly.
        //
        // TO DO: The aptos_framework::stake module really needs to include its own stake unlock event. I
        // created an issue here to resolve this: https://github.com/aptos-labs/aptos-core/issues/4080
        // However this SharedStakePool will still needs to track all this info manually, 
        // because on-chain functions can't read on-chain events, as ridicilous as that sounds...
        if (locked_until_secs > epoch_tracker.locked_until_secs) {
            epoch_tracker.locked_until_secs = locked_until_secs;
            move_pending_inactive_to_inactive(stake_pool);
        }
    }

    // crank sub-function. Cannot abort
    // rewards_amount is the total APT earned by this operator in the previous epoch
    // operators only get paid while their validator is part of the active or pending_inactive_map set,
    // and are only paid in arrears for the epoch prior to the current one
    fun calculate_operator_fee(this: address, rewards_amount: u64): u64 acquires ValidatorStatus, OperatorAgreement {
        let operator_agreement = borrow_global_mut<OperatorAgreement>(this);
        let previous_status = borrow_global_mut<ValidatorStatus>(this).status;
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
            let fixed_fee_apt = convert_usd_to_apt(fixed_fee_usd, epoch_start_secs);
            let incentive_fee_apt = ((rewards_amount as u128) * (operator_agreement.performance_fee_bps as u128) / 10000 as u64);
            let operator_fee = fixed_fee_apt + incentive_fee_apt;
        };

        operator_agreement.last_paid_secs = epoch_start_secs;
        previous_status = current_status;

        operator_fee
    }

    // TO DO: consult a switchboard oracle to find the USD price at the given timestamp
    fun convert_usd_to_apt(amount: u64, _time: u64): u64 {
        amount
    }

    // fun update_balance(this: address) acquires SharedStakePool {
    //     let stake_pool = borrow_global_mut<SharedStakePool>(this);
    //     let (active, _inactive, _pending_active, pending_inactive_map) = stake::get_stake(this);
    //     // These are the only balances that earn a StakePool interest
    //     let total_coins = active + pending_inactive_map;
    //     pool_u64::update_total_coins(&mut stake_pool.pool, total_coins);
    // }

    // crank sub-function. Cannot abort
    fun move_pending_active_to_active(stake_pool: &mut SharedStakePool) {
        let addresses = stake_pool.pending_active_list;
        let pending_active_map = stake_pool.pending_active_map;
        let pool = &mut stake_pool.pool;

        let i = 0;
        let len = vector::length(&addresses);
        while (i < len) {
            let addr = vector::borrow(&mut addresses, i);

            let new_active_balance = if (simple_map::contains_key(&pending_active_map, addr)) {
                *simple_map::borrow(&pending_active_map, addr)
            }
            else {
                0
            };

            // active balance will begin earning interest this epoch
            pool_u64::buy_in(pool, *addr, new_active_balance);
        };
        stake_pool.pending_active_map = simple_map::create<address, u64>();
        stake_pool.pending_active_list = vector::empty();
        stake_pool.pending_active = 0;
    }

    // crank sub-function. Cannot abort
    fun move_pending_inactive_to_inactive(stake_pool: &mut SharedStakePool) {
        let addresses = stake_pool.pending_inactive_list;
        let pending_inactive_map = stake_pool.pending_inactive_map;
        let inactive_map = stake_pool.inactive_map;
        let pool = &mut stake_pool.pool;

        let i = 0;
        let len = vector::length(&addresses);
        while (i < len) {
            let addr = vector::borrow(&mut addresses, i);
            let pending_balance = simple_map::borrow(&mut pending_inactive_map, addr);

            // inactive stake no longer earns interest, and is considered redeemed
            let shares = pool_u64::amount_to_shares(pool, *pending_balance);
            let redeemed_coins = pool_u64::redeem_shares(pool, *addr, shares);

            if (simple_map::contains_key(&inactive_map, addr)) {
                let inactive_balance = simple_map::borrow_mut(&mut inactive_map, addr);
                *inactive_balance = *inactive_balance + redeemed_coins;
            }
            else {
                simple_map::add(&mut inactive_map, *addr, redeemed_coins);
            }
        };
        stake_pool.pending_inactive_map = simple_map::create<address, u64>();
        stake_pool.pending_inactive_list = vector::empty();
        stake_pool.pending_inactive = 0;
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

    // TO DO: figure out voting
    public entry fun change_voter() {}


}
