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
    use std::option::{Self, Option};
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
    const EACCOUNT_NOT_FOUND: u64 = 4;
    const EINVALID_PERFORMANCE_FEE: u64 = 5;
    const EGOVERNANCE_NOT_FOUND: u64 = 6;

    /// Validator status enums.
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    struct SharedStakePool has key {
        owner_cap: stake::OwnerCapability,
        pool: pool_u64::Pool,
        pending_active: IterableMap,
        pending_inactive: IterableMap,
        inactive: IterableMap,
        balances: Balances,
        operator_agreement: OperatorAgreement,
        pending_operator_agreement: Option<OperatorAgreement>,
        validator_status: u64
    }

    struct IterableMap has store, drop {
        map: SimpleMap<address, u64>,
        list: vector<address>
    }

    // These balances are cached versions of the same coin values in stake::StakePool
    struct Balances has store {
        active: u64,
        inactive: u64,
        pending_active: u64,
        pending_inactive: u64,
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
        shared_pool_address: address
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
            pending_active: IterableMap {
                map: simple_map::create<address, u64>(),
                list: vector::empty<address>()
            },
            pending_inactive: IterableMap {
                map: simple_map::create<address, u64>(),
                list: vector::empty<address>()
            },
            inactive: IterableMap {
                map: simple_map::create<address, u64>(),
                list: vector::empty<address>()
            },
            balances: Balances {
                active: 0,
                inactive: 0,
                pending_active: 0,
                pending_inactive: 0,
            },
            operator_agreement: OperatorAgreement {
                operator: addr,
                monthly_fee_usd: 0,
                performance_fee_bps: 500,
                last_paid_secs: 0,
                epoch_effective: 0
            },
            pending_operator_agreement: option::none(),
            validator_status: VALIDATOR_STATUS_INACTIVE
        });

        move_to(this, EpochTracker {
            epoch: reconfiguration::current_epoch(),
            locked_until_secs: stake::get_lockup_secs(addr)
        });

        move_to(this, GovernanceCapability {
            shared_pool_address: addr
        });
    }

    public entry fun deposit(account: &signer, this: address, amount: u64) acquires EpochTracker, SharedStakePool {
        let coins = coin::withdraw<AptosCoin>(account, amount);
        deposit_with_coins(this, signer::address_of(account), coins);
    }

    public fun deposit_with_coins(this: address, addr: address, coins: Coin<AptosCoin>) acquires EpochTracker, SharedStakePool {
        crank_on_new_epoch(this);
        let value = coin::value<AptosCoin>(&coins);
        if (value == 0) {
            coin::destroy_zero<AptosCoin>(coins);
            return;
        };

        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        stake::add_stake_with_cap(&stake_pool.owner_cap, coins);

        add_to_iterable_map(&mut stake_pool.pending_active, addr, value);
        stake_pool.balances.pending_active = stake_pool.balances.pending_active + value;
    }

    public entry fun unlock(account: &signer, this: address, amount: u64) acquires EpochTracker, SharedStakePool {
        crank_on_new_epoch(this);
        let addr = signer::address_of(account);
        let (active, _inactive, _pending_active, _pending_inactive) = get_balances_for_address(this, addr);
        assert!(active >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));

        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        stake::unlock_with_cap(amount, &stake_pool.owner_cap);

        add_to_iterable_map(&mut stake_pool.pending_inactive, addr, amount);
        stake_pool.balances.pending_inactive = stake_pool.balances.pending_inactive + amount;
        stake_pool.balances.active = stake_pool.balances.active - amount;
    }

    public entry fun cancel_unlock(account: &signer, this: address, amount: u64) acquires SharedStakePool, EpochTracker {
        crank_on_new_epoch(this);
        let addr = signer::address_of(account);
        let (_active, _inactive, _pending_active, pending_inactive) = get_balances_for_address(this, addr);
        assert!(pending_inactive >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));

        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        stake::reactivate_stake_with_cap(&stake_pool.owner_cap, amount);

        subtract_from_iterable_map(&mut stake_pool.pending_inactive, addr, amount);
        stake_pool.balances.pending_inactive = stake_pool.balances.pending_inactive - amount;
        stake_pool.balances.active = stake_pool.balances.active + amount;
    }

    public entry fun withdraw(account: &signer, this: address, amount: u64) acquires EpochTracker, SharedStakePool {
        let coin = withdraw_to_coins(account, this, amount);
        coin::deposit<AptosCoin>(signer::address_of(account), coin);
    }

    public entry fun withdraw_to_coins(account: &signer, this: address, amount: u64): Coin<AptosCoin> acquires EpochTracker, SharedStakePool {
        crank_on_new_epoch(this);
        if (amount == 0) {
            return coin::zero<AptosCoin>()
        };

        let addr = signer::address_of(account);
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        assert!(simple_map::contains_key(&stake_pool.inactive.map, &addr), error::not_found(EACCOUNT_NOT_FOUND));

        let withdrawable_balance = simple_map::borrow_mut(&mut stake_pool.inactive.map, &addr);
        assert!(*withdrawable_balance >= amount, error::invalid_argument(EINSUFFICIENT_BALANCE));

        subtract_from_iterable_map(&mut stake_pool.inactive, addr, amount);
        stake_pool.balances.inactive = stake_pool.balances.inactive - amount;

        let coins = stake::withdraw_with_cap(&stake_pool.owner_cap, amount);
        coins
    }

    public fun get_balances_for_address(this: address, addr: address): (u64, u64, u64, u64) acquires EpochTracker, SharedStakePool {
        crank_on_new_epoch(this);
        let stake_pool = borrow_global_mut<SharedStakePool>(this);

        let pending_inactive = if (simple_map::contains_key(&stake_pool.pending_inactive.map, &addr)) {
            *simple_map::borrow(&stake_pool.pending_inactive.map, &addr)
        }
        else {
            0
        };

        let inactive = if (simple_map::contains_key(&stake_pool.inactive.map, &addr)) {
            *simple_map::borrow(&stake_pool.inactive.map, &addr)
        }
        else {
            0
        };

        let pending_active = if (simple_map::contains_key(&stake_pool.pending_active.map, &addr)) {
            *simple_map::borrow(&stake_pool.pending_active.map, &addr)
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
    public fun crank_on_new_epoch(this: address) acquires EpochTracker, SharedStakePool {
        let current_epoch = reconfiguration::current_epoch();
        let epoch_tracker = borrow_global_mut<EpochTracker>(this);

        // Ensures crank can only run once per epoch
        if (current_epoch <= epoch_tracker.epoch) return;
        epoch_tracker.epoch = current_epoch;

        // calculate rewards for the previous epoch
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        let (active, _, _, pending_inactive) = stake::get_stake(this);
        let stake_before_rewards = stake_pool.balances.active + stake_pool.balances.pending_active;
        let rewards_amount = if (active >= stake_before_rewards) {
            active - stake_before_rewards
        }
        else {
            // unless Aptos implements slashing, this branch is impossible to reach
            // Move does not support negative numbers
            0
        };
        let operator_fee = calculate_operator_fee(this, rewards_amount, &stake_pool.operator_agreement, stake_pool.validator_status);

        // update total coin balance; excluding operator_fee and pending_active_map stake, which
        // will be added below
        pool_u64::update_total_coins(&mut stake_pool.pool, active + stake_pool.balances.pending_inactive - stake_pool.balances.pending_active - operator_fee);

        // issue shares to pay the operator
        pool_u64::buy_in(&mut stake_pool.pool, stake::get_operator(this), operator_fee);

        // update our cached values
        stake_pool.operator_agreement.last_paid_secs = reconfiguration::last_reconfiguration_time() / MICRO_CONVERSION_FACTOR;
        stake_pool.validator_status = stake::get_validator_state(this);

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
        // I added the pending_inactive check as a double-measure; the check should always suffice
        if ((locked_until_secs > epoch_tracker.locked_until_secs) && (pending_inactive == 0)) {
            epoch_tracker.locked_until_secs = locked_until_secs;
            move_pending_inactive_to_inactive(stake_pool);
        };

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
        // TO DO: do we need this next line?
        stake_pool.pending_operator_agreement = option::none();
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
            let _fixed_fee_apt = convert_usd_to_apt(fixed_fee_usd, epoch_start_secs);
            let incentive_fee_apt = ((rewards_amount as u128) * (operator_agreement.performance_fee_bps as u128) / 10000 as u64);

            // TO DO: when usd_to_apt is implemented, start including the fixed fee as well
            operator_fee = incentive_fee_apt; // + _fixed_fee_apt;
        };

        operator_fee
    }

    // crank sub-function. Cannot abort
    fun move_pending_active_to_active(stake_pool: &mut SharedStakePool) {
        let addresses = stake_pool.pending_active.list;
        let pending_active_map = stake_pool.pending_active.map;
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
        stake_pool.pending_active.map = simple_map::create<address, u64>();
        stake_pool.pending_active.list = vector::empty();
        stake_pool.balances.pending_active = 0;
    }

    // crank sub-function. Cannot abort
    fun move_pending_inactive_to_inactive(stake_pool: &mut SharedStakePool) {
        let addresses = stake_pool.pending_inactive.list;
        let pending_inactive_map = stake_pool.pending_inactive.map;
        let inactive_map = stake_pool.inactive.map;
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
        stake_pool.pending_inactive.map = simple_map::create<address, u64>();
        stake_pool.pending_inactive.list = vector::empty();
        stake_pool.balances.pending_inactive = 0;
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
        let GovernanceCapability { shared_pool_address: _ } = governance_cap;
    }

    public fun get_governance_cap_shared_pool_address(governance_cap: &GovernanceCapability): address {
        governance_cap.shared_pool_address
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
        let this = governance_cap.shared_pool_address;
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
        let this = governance_cap.shared_pool_address;
        let stake_pool = borrow_global_mut<SharedStakePool>(this);
        stake::set_delegated_voter_with_cap(&stake_pool.owner_cap, new_voter);
    }

    public entry fun increase_lockup(account: &signer) acquires GovernanceCapability, SharedStakePool, EpochTracker {
        let addr = signer::address_of(account);
        assert!(exists<GovernanceCapability>(addr), error::not_found(EGOVERNANCE_NOT_FOUND));
        let governance_cap = borrow_global<GovernanceCapability>(addr);
        increase_lockup_with_cap(governance_cap);
    }

    public fun increase_lockup_with_cap(governance_cap: &GovernanceCapability) acquires SharedStakePool, EpochTracker {
        let this = governance_cap.shared_pool_address;
        let stake_pool = borrow_global<SharedStakePool>(this); 
        stake::increase_lockup_with_cap(&stake_pool.owner_cap);

        // crank_on_new_epoch uses increases in the locked_until_secs as an indicator that an unlock occurred
        // so we need to keep this up to date
        let epoch_tracker = borrow_global_mut<EpochTracker>(this);
        let new_locked_until_secs = stake::get_lockup_secs(this);
        epoch_tracker.locked_until_secs = new_locked_until_secs;
    }

    // ================= Utility functions =================

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

    // TO DO: query a switchboard oracle to find the USD price at the given timestamp
    fun convert_usd_to_apt(amount: u64, _time: u64): u64 {
        amount
    }

}
