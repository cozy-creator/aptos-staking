module openrails::stake_pool {
    // TODO: Various tiers of fee calculations (OpenRails, seed staker, operator/validator, retail)
    // TODO: Generate non-conflicting seeds for resource accounts
    // TODO: Allow multiple people to be considered "seed staker"

    // =============== Uses ===============

    use std::signer;
    use std::string;
    use std::error;
    use std::option;
    use aptos_framework::coin;
    use aptos_framework::account;
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::stake;
    use aptos_framework::reconfiguration;

    use openrails::iterable_table::{Self, IterableTable};
    use openrails::fixed_point_64;

    // =============== Uses ===============

    // =============== Constants ===============

    /// The minimum number of coins that must be deposited in a stake pool
    const MIN_STAKE_AMOUNT: u64 = 100;
    /// The maximum number of coins that can be deposited in a stake pool
    const MAX_STAKE_AMOUNT: u64 = 1000000000;

    // =============== Constants ===============

    // =============== Structs ===============

    /// Validator status enum
    const VALIDATOR_STATUS_PENDING_ACTIVE: u64 = 1;
    const VALIDATOR_STATUS_ACTIVE: u64 = 2;
    const VALIDATOR_STATUS_PENDING_INACTIVE: u64 = 3;
    const VALIDATOR_STATUS_INACTIVE: u64 = 4;

    /// Info of a particular stake pool. Each `StakePoolInfo` for a unique stake pool is stored in its
    /// respective resource account, created upon genesis of a particular stake pool.
    struct StakePoolInfo has store {
        /// Signer capability that allows the stake pool to withdraw APT back to the user
        signer_cap: account::SignerCapability,
        /// Owner capability representing ownership and can be used to control the validator and associated stake pool
        owner_cap: stake::OwnerCapability,
        /// Balances in the previous epoch
        prev_epoch_balances: Balances,
        /// Validator status
        validator_status: u64,
    }

    /// The reserve is a resource account holding only APT. Once there is a suffiicient amount of APT in the reserve, it
    /// will be routed to a stake pool.
    struct LiquidityReserve has key {
        /// Signer capability of the reserve
        signer_cap: account::SignerCapability,
    }

    /// orAPT coin
    struct StakedAptosCoin {}

    /// orAPT coin capabilities
    struct OrAptCaps has key {
        mint_cap: coin::MintCapability<StakedAptosCoin>,
        burn_cap: coin::BurnCapability<StakedAptosCoin>,
        freeze_cap: coin::FreezeCapability<StakedAptosCoin>,
    }

    /// Iterable table of the stake pools' addresses and their caps. Stored in the admin account.
    struct StakePools<StakePoolInfo> has key, store {
        stake_pool_table: IterableTable<address, StakePoolInfo>,
    }

    /// Indicates which stake pool is currently receiving APT deposits. In our v1, this will be manually adjusted. In
    /// future versions, an algorithm will decide this. Stored in the admin account.
    struct ActiveStakePool has key {
        active_stake_pool: address,
    }

    /// When a user chooses to perform a delayed unstake, this value will be set to the amount of APT they can claim.
    /// After claiming it, this value is reset to 0.
    struct DelayedUnstakeCredit has key {
        credit: u64,
    }

    /// Table containing list of seed stakers. Stored in the admin account.
    struct SeedStaker has key {
        seed_stakers: vector<address>,
    }

    /// Resource containing the three different entities and their rewards. Operators are paid out via SharedStakePool.move
    /// The values are updated every epoch. Stored in the admin account.
    struct Rewards has key {
        openrails: IterableTable<address, u64>,
        seed_stakers: IterableTable<address, u64>,
        retail: IterableTable<address, u64>,
    }

    struct EpochTracker has key {
        epoch: u64,
        locked_until_secs: u64,
    }

    /// These balances are cached versions of the same coin values in stake::StakePool
    struct Balances has store {
        active: u64,
        inactive: u64,
        pending_active: u64,
        pending_inactive: u64,
    }

    // =============== Structs ===============

    // =============== Error Messages ===============

    const EWRONG_ADDR: u64 = 0;
    const EWRONG_BAL: u64 = 1;
    const ECOIN_NOT_INIT: u64 = 2;
    const ECOIN_INCORRECT_REG: u64 = 3;
    const ENO_CAPS: u64 = 4;
    const EOVER_WITHDRAW: u64 = 5;
    const EALREADY_INIT: u64 = 6;
    /// When there is insufficent liquidity in the reserve pool for a liquid unstake
    const EINSUF_LIQ: u64 = 7;
    const EMUST_NOT_BE_ZERO: u64 = 8;
    const EWITHDRAW_CLAIM_FIRST: u64 = 9;
    const ESTAKE_POOL_NOT_WHITELISTED: u64 = 10;

    // =============== Error Messages ===============

    // =============== Genesis Functions ===============
    // ** These are the first few functions to be called when initializing the module ** \\
    // ** Includes both `fun` and `public entry fun` functions ** \\

    // Initializes the orAPT coin
    entry fun initialize_orapt(admin: &signer) {
        assert!(signer::address_of(admin) == @openrails, EWRONG_ADDR);

        let name = string::utf8(b"Open Rails Staked Aptos");
        let symbol = string::utf8(b"orAPT");
        let decimals: u8 = 9;
        let (burn_cap, freeze_cap, mint_cap) =
            coin::initialize<StakedAptosCoin>(
                admin,
                name,
                symbol,
                decimals,
                true
            );

        move_to(admin, OrAptCaps { mint_cap, burn_cap, freeze_cap });
    }

    /// Initialize the liquidity reserve
    entry fun initialize_liquidity_reserve(admin: &signer) {
        assert!(signer::address_of(admin) == @openrails, EWRONG_ADDR);

        let (reserve_signer, reserve_signer_cap) = account::create_resource_account(admin, b"seed");

        coin::register<AptosCoin>(&reserve_signer);

        move_to<LiquidityReserve>(admin, LiquidityReserve {
            signer_cap: reserve_signer_cap,
        })
    }

    // Initialize the very first stake pool to be added to the Open Rails protocol.
    entry fun initialize_genesis_stake_pool(
        admin: &signer,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        fullnode_addresses: vector<u8>,
    ) {
        assert!(signer::address_of(admin) == @openrails, EWRONG_ADDR);

        // TODO: How to pass in unique vector<u8> to generate a random seed, or at least two seeds that won't collide
        let (stake_pool_signer, signer_cap) = account::create_resource_account(admin, b"random_seed");
        let stake_pool_addr = signer::address_of(&stake_pool_signer);

        // Register APT in stake pool account, this might not be needed on mainnet
        coin::register<AptosCoin>(&stake_pool_signer);

        // Initialize and select the genesis stake pool as the active stake pool

        // Begin tracking epochs
        move_to(&stake_pool_signer, EpochTracker {
            epoch: reconfiguration::current_epoch(),
            locked_until_secs: stake::get_lockup_secs(stake_pool_addr)
        });

        // Select genesis stake pool as active stake pool
        move_to<ActiveStakePool>(admin, ActiveStakePool{ active_stake_pool: stake_pool_addr });

        // Initialize the stake pool
        stake::initialize_validator(
            &stake_pool_signer,
            consensus_pubkey,
            proof_of_possession,
            network_addresses,
            fullnode_addresses,
        );

        // I'm extracting the owner_cap just to move it back to the stake_pool_signer because we can't directly access
        // the cap from global storage, since that is only unique to stake.move module
        let owner_cap = stake::extract_owner_cap(&stake_pool_signer);

        let prev_epoch_balances = Balances {
            active: 0,
            inactive: 0,
            pending_active: 0,
            pending_inactive: 0,
        };

        let stake_pool_info = StakePoolInfo {
            signer_cap,
            owner_cap,
            prev_epoch_balances,
            validator_status: VALIDATOR_STATUS_PENDING_ACTIVE,
        };

        // Move the initialized table to the admin account
        let stake_pool_table = iterable_table::new<address, StakePoolInfo>();
        iterable_table::add(&mut stake_pool_table, stake_pool_addr, stake_pool_info);
        move_to<StakePools<StakePoolInfo>>(admin, StakePools<StakePoolInfo> { stake_pool_table });
    }


    // The very first time someone deposits anything with us there will be no orAPT. Thus, the `calculate_price()`
    // function will error out (divide by zero). The very first depositor will receive orAPT equal to the amount of APT.
    public entry fun stake_genesis_stake_pool(
        genesis_staker: &signer,
        amount: u64,
    ) acquires StakePools, ActiveStakePool, LiquidityReserve, OrAptCaps {
        let admin_addr = @openrails;

        // Retrieve the first stake pool (genesis pool) from global storage.
        let stake_pool_table = borrow_global<StakePools<StakePoolInfo>>(admin_addr);
        let active_stake_pool = borrow_global<ActiveStakePool>(admin_addr).active_stake_pool;
        let genesis_pool_info =
            iterable_table::borrow<address, StakePoolInfo>(&stake_pool_table.stake_pool_table, active_stake_pool);
        let stake_pool_signer = account::create_signer_with_capability(&genesis_pool_info.signer_cap);
        let stake_pool_addr = signer::address_of(&stake_pool_signer);
        assert!(active_stake_pool == stake_pool_addr, EWRONG_ADDR);

        // Transfer the coins from the genesis staker to the reserve
        let liquidity_reserve = borrow_global<LiquidityReserve>(admin_addr);
        let reserve_signer = account::create_signer_with_capability(&liquidity_reserve.signer_cap);
        let reserve_addr = signer::address_of(&reserve_signer);
        coin::transfer<AptosCoin>(genesis_staker, reserve_addr, amount);

        // Call the `stake::add_stake` function to stake the coins in the stake pool that now belong to the `reserve_signer`
        stake::add_stake(&reserve_signer, amount);

        // Mint an equal number of orAPT to the genesis_staker_addr
        let genesis_staker_addr = signer::address_of(genesis_staker);
        let orapt_caps = borrow_global<OrAptCaps>(admin_addr);
        let orapt_minted = coin::mint(amount, &orapt_caps.mint_cap);
        coin::register<StakedAptosCoin>(genesis_staker);
        coin::deposit(genesis_staker_addr, orapt_minted);
    }

    // =============== Genesis Functions ===============

    // =============== Private Functions ===============

    /// Manually select which whitelisted stake pool APT will be deposited in from the reserve.
    entry fun select_validator(admin: &signer, stake_pool_addr: address)
    acquires ActiveStakePool, StakePools {
        let admin_addr = signer::address_of(admin);
        assert!(admin_addr == @openrails, EWRONG_ADDR);

        // Assert that new_stake_pool_addr must already exist in StakePools
        let stake_pool_table = borrow_global<StakePools<StakePoolInfo>>(admin_addr);
        assert!(iterable_table::contains<address, StakePoolInfo>
            (&stake_pool_table.stake_pool_table, stake_pool_addr), ESTAKE_POOL_NOT_WHITELISTED);


        let active_stake_pool = &mut borrow_global_mut<ActiveStakePool>(admin_addr).active_stake_pool;
        *active_stake_pool = stake_pool_addr;
    }

    /// Creates and whitelists a new stake pool to be added to the StakePools
    entry fun add_new_stake_pool(
        admin: &signer,
        consensus_pubkey: vector<u8>,
        proof_of_possession: vector<u8>,
        network_addresses: vector<u8>,
        fullnode_addresses: vector<u8>
    ) acquires StakePools {
        assert!(signer::address_of(admin) == @openrails, EWRONG_ADDR);
        let admin_addr = signer::address_of(admin);

        // TODO: How to pass in unique vector<u8> to generate a random seed, or at least two seeds that won't collide
        let (stake_pool_signer, signer_cap) = account::create_resource_account(admin, b"random_seed");
        let stake_pool_addr = signer::address_of(&stake_pool_signer);

        // Register APT in stake pool account, this might not be needed on mainnet
        coin::register<AptosCoin>(&stake_pool_signer);

        // Begin tracking epochs
        move_to(&stake_pool_signer, EpochTracker {
            epoch: reconfiguration::current_epoch(),
            locked_until_secs: stake::get_lockup_secs(stake_pool_addr)
        });

        // Initialize the stake pool
        stake::initialize_validator(
            &stake_pool_signer,
            consensus_pubkey,
            proof_of_possession,
            network_addresses,
            fullnode_addresses,
        );

        // I'm extracting the owner_cap to then move it back to the stake_pool_signer because we can't directly access
        // the cap from global storage, since that is only unique to the stake.move module
        let owner_cap = stake::extract_owner_cap(&stake_pool_signer);

        let prev_epoch_balances = Balances {
            active: 0,
            inactive: 0,
            pending_active: 0,
            pending_inactive: 0,
        };

        let stake_pool_info = StakePoolInfo {
            signer_cap,
            owner_cap,
            prev_epoch_balances,
            validator_status: VALIDATOR_STATUS_PENDING_ACTIVE,
        };

        // Move the initialized table to the admin account
        let stake_pool_table = borrow_global_mut<StakePools<StakePoolInfo>>(admin_addr);
        iterable_table::add(&mut stake_pool_table.stake_pool_table, stake_pool_addr, stake_pool_info);
    }

    /// Once a sufficient number of APT has been deposited into the reserve, stake some with the active validator
    entry fun delegate_stake(admin: &signer, amount: u64)
    acquires ActiveStakePool, StakePools, LiquidityReserve {
        let admin_addr = signer::address_of(admin);
        let active_stake_pool = borrow_global<ActiveStakePool>(admin_addr).active_stake_pool;
        let stake_pool_table = borrow_global<StakePools<StakePoolInfo>>(admin_addr);
        let stake_pool_info = iterable_table::borrow(&stake_pool_table.stake_pool_table, active_stake_pool);
        let reserve = borrow_global_mut<LiquidityReserve>(admin_addr);
        let reserve_signer = account::create_signer_with_capability(&reserve.signer_cap);
        let coins_to_stake = coin::withdraw<AptosCoin>(&reserve_signer, amount);
        stake::add_stake_with_cap(&stake_pool_info.owner_cap, coins_to_stake);
    }

    // =============== Private Functions ===============

    // =============== Public Functions ===============


    /// The total amount a user will be able to withdraw from the stake pool from a liquid unstake.
    fun max_withdraw_amount_liq(user_address: address): u64 acquires LiquidityReserve {
        let orapt_balance = coin::balance<StakedAptosCoin>(user_address);
        // Amount of APT left after OpenRails takes its cut
        let protocol_fee = protocol_fee(user_address, orapt_balance);
        // Amount of APT left after user pays unstake now fee
        let liq_unstake_fee = liq_unstake_fee(protocol_fee);

        liq_unstake_fee
    }

    fun max_withdraw_amount_delay(user_address: address): u64 {
        let orapt_balance = coin::balance<StakedAptosCoin>(user_address);
        // Amount of APT left after OpenRails takes its cut
        let protocol_fee = protocol_fee(user_address, orapt_balance);

        protocol_fee
    }

    // =============== Public Functions ===============

    // =============== Public Entry Functions ===============

    public entry fun stake(
        staker: &signer,
        amount: u64
    ) acquires LiquidityReserve, OrAptCaps {
        let admin_addr = @openrails;
        let staker_addr = signer::address_of(staker);
        // Transfer APT to reserve
        let liquidity_reserve = borrow_global_mut<LiquidityReserve>(admin_addr);
        let reserve_signer = account::create_signer_with_capability(&liquidity_reserve.signer_cap);
        let reserve_addr = signer::address_of(&reserve_signer);
        coin::transfer<AptosCoin>(staker, reserve_addr, amount);

        mint_orapt(staker_addr, amount);
    }

    /// When unstaking, the total possible amount a user can withdraw is `max_withdraw_amount()`. The APT being
    /// withdrawn is coming from the APT reserve.
    public entry fun liquid_unstake(
        unstaker: &signer,
        amount: u64,
    ) acquires OrAptCaps, LiquidityReserve {
        assert!(amount > 0, EMUST_NOT_BE_ZERO);
        let unstaker_addr = signer::address_of(unstaker);
        let admin_addr = @openrails;

        let liquidity_reserve = borrow_global_mut<LiquidityReserve>(admin_addr);
        let reserve_signer = account::create_signer_with_capability(&liquidity_reserve.signer_cap);
        let reserve_addr = signer::address_of(&reserve_signer);

        // Assert that there is sufficient liquidity in the reserve for the withdraw to occur.
        assert!(coin::balance<AptosCoin>(reserve_addr) >= amount, EINSUF_LIQ);

        // Assert that the user cannot withdraw more than `max_withdraw_amount`. This represents the amount in APT the
        // user will receive upon unstaking.
        assert!(max_withdraw_amount_liq(unstaker_addr) >= amount, EOVER_WITHDRAW);

        // Burn orAPT
        burn_orapt_liq(unstaker, amount);

        // Deposit APT equivalent to the orAPT-APT exchange rate
        withdraw_apt_liq(unstaker, amount);
    }

    /// Waits until the end of the epoch to withdraw funds back into the user account.
    /// Funds are unlocked from the stake pool.
    /// Note, the user must then return to the app to collect the APT via `collect_funds()`.
    public entry fun delayed_unstake(
        unstaker: &signer,
        amount: u64,
    ) acquires ActiveStakePool, StakePools, DelayedUnstakeCredit, OrAptCaps {
        let unstaker_addr = signer::address_of(unstaker);
        assert!(amount > 0, EMUST_NOT_BE_ZERO);
        let admin_addr = @openrails;

        assert!(max_withdraw_amount_delay(unstaker_addr) >= amount, EOVER_WITHDRAW);

        let active_stake_pool = borrow_global<ActiveStakePool>(admin_addr).active_stake_pool;
        let stake_pool_table =
            borrow_global_mut<StakePools<StakePoolInfo>>(admin_addr);
        let stake_pool_info = iterable_table::borrow(&stake_pool_table.stake_pool_table, active_stake_pool);
        let amt_after_protocol_fee = protocol_fee(unstaker_addr, amount);
        let net_amount = amt_after_protocol_fee;

        stake::unlock_with_cap(net_amount, &stake_pool_info.owner_cap);

        // Update global storage to indicate that the unstaker is owed ___ APT when the lockup is over
        if (!exists<DelayedUnstakeCredit>(unstaker_addr)) {
            move_to(unstaker, DelayedUnstakeCredit { credit: net_amount })
        } else {
            let delayed_unstake_credit = borrow_global_mut<DelayedUnstakeCredit>(unstaker_addr);
            // If the credit is non-zero, the user must withdraw those coins first before caling this function again
            assert!(delayed_unstake_credit.credit == 0, EWITHDRAW_CLAIM_FIRST);
            delayed_unstake_credit.credit = net_amount;
        };

        burn_orapt_delayed(unstaker, amount)
    }

    /// Once the unlock is over, the user will call this function to withdraw their funds to their account
    public entry fun collect_funds(
        unstaker: &signer
    ) acquires ActiveStakePool, StakePools, DelayedUnstakeCredit {
        let admin_addr = @openrails;
        let unstaker_addr = signer::address_of(unstaker);
        let active_stake_pool = borrow_global<ActiveStakePool>(admin_addr).active_stake_pool;
        let stake_pool_table =
            borrow_global_mut<StakePools<StakePoolInfo>>(admin_addr);
        let stake_pool_info = iterable_table::borrow(&stake_pool_table.stake_pool_table, active_stake_pool);

        let delayed_unstake_credit = borrow_global_mut<DelayedUnstakeCredit>(unstaker_addr);

        // Coins must be in the stake pool's inactive balance before one can withdraw
        let coins= stake::withdraw_with_cap(&stake_pool_info.owner_cap, delayed_unstake_credit.credit);

        // Reset APT credit to 0
        delayed_unstake_credit.credit = 0;

        coin::deposit(unstaker_addr, coins);
    }

    // The `net_amount` of orAPT received upon mint will always be less than the amount of APT deposited.
    public fun mint_orapt(staker_addr: address, amount: u64) acquires OrAptCaps {
        let admin_addr = @openrails;
        let orapt_caps = borrow_global<OrAptCaps>(admin_addr);
        let orapt_minted = coin::mint(amount, &orapt_caps.mint_cap);
        coin::deposit(staker_addr, orapt_minted);
    }

    /// The `net_amount` of orAPT burned will always be less than the amount of APT the user is receiving.
    /// The `amount` parameter refers to the amount of APT the user wants to withdraw, not the amount of orAPT the user will burn.
    fun burn_orapt_liq(unstaker: &signer, amount: u64) acquires OrAptCaps, LiquidityReserve {
        let unstaker_addr = signer::address_of(unstaker);
        let admin_addr = @openrails;
        let amt_after_protocol_fee = protocol_fee(unstaker_addr, amount);
        let net_amount = liq_unstake_fee(amt_after_protocol_fee);
        let orapt = coin::withdraw<StakedAptosCoin>(unstaker, net_amount);
        assert!(exists<OrAptCaps>(admin_addr), error::not_found(ENO_CAPS));
        let capabilities = borrow_global<OrAptCaps>(admin_addr);
        coin::burn<StakedAptosCoin>(orapt, &capabilities.burn_cap);
    }

    fun burn_orapt_delayed(unstaker: &signer, amount: u64) acquires OrAptCaps {
        let unstaker_addr = signer::address_of(unstaker);
        let admin_addr = @openrails;
        let net_amount = protocol_fee(unstaker_addr, amount);
        let orapt = coin::withdraw<StakedAptosCoin>(unstaker, net_amount);
        assert!(exists<OrAptCaps>(admin_addr), error::not_found(ENO_CAPS));
        let capabilities = borrow_global<OrAptCaps>(admin_addr);
        coin::burn<StakedAptosCoin>(orapt, &capabilities.burn_cap);
    }

    /// The `net_amount` of APT withdrawn is always greater (before the fee is applied)
    public fun withdraw_apt_liq(unstaker: &signer, amount: u64) acquires LiquidityReserve {
        let admin_addr = @openrails;
        let unstaker_addr = signer::address_of(unstaker);
        let protocol_fee = protocol_fee(unstaker_addr, amount);
        let net_amount = liq_unstake_fee(protocol_fee);
        let liquidity_reserve = borrow_global_mut<LiquidityReserve>(admin_addr);
        let reserve_signer = account::create_signer_with_capability(&liquidity_reserve.signer_cap);
        coin::transfer<AptosCoin>(&reserve_signer, unstaker_addr, net_amount);
    }

    /// A flat 10% fee on rewards reserved for the OpenRails protocol.
    /// The `amount` is how much APT a user wants to withdraw (# orAPT will be smaller than this number)
    /// This function returns the total APT left AFTER the fee has been calculated.
    fun protocol_fee(user: address, amount: u64): u64 {
        let orapt_bal = coin::balance<StakedAptosCoin>(user);
        let fee = fixed_point_64::from_u64(10, 2);  // 10% fee
        let amt_fp = fixed_point_64::from_u64(amount, 1);
        let orapt_bal_fp = fixed_point_64::from_u64(orapt_bal, 1);
        // fee * (amount - orAPT bal) / orAPT bal
        let net_fee_fp =
            fixed_point_64::divide_trunc(fixed_point_64::multiply_round_up(fee, fixed_point_64::sub(amt_fp, orapt_bal_fp)), orapt_bal_fp);
        fixed_point_64::to_u64(net_fee_fp, 1)
    }

    /// The fee a user is charged for choosing to unstake via the reserve.
    /// This function returns the total APT left AFTER the fee has been calculated.
    public fun liq_unstake_fee(amount: u64): u64 acquires LiquidityReserve {
        // unstake_fee = max_fee - (max_fee - min_fee) * amount_after / target
        // op_1 = (max_fee - min_fee)
        // op_2 = (max_fee - min_fee) * amount_after
        // op_3 = (max_fee - min_fee) * amount_after / target
        let admin_addr = @openrails;
        let amount_fp = fixed_point_64::from_u64(amount, 1);
        let max_fee = fixed_point_64::from_u64(3000, 5);      // 3%
        let min_fee = fixed_point_64::from_u64(300, 5);       // 0.3%
        let target = fixed_point_64::from_u64(100000, 1);
        let reserve = borrow_global<LiquidityReserve>(admin_addr);
        let reserve_signer = account::create_signer_with_capability(&reserve.signer_cap);
        let reserve_addr = signer::address_of(&reserve_signer);
        let reserve_balance_u64 = coin::balance<AptosCoin>(reserve_addr);
        let reserve_balance_fp = fixed_point_64::from_u64(reserve_balance_u64, 1);
        let amount_after = fixed_point_64::sub(amount_fp, reserve_balance_fp);
        let op_1 = fixed_point_64::sub(max_fee, min_fee);
        let op_2 = fixed_point_64::multiply_round_up(op_1, amount_after);
        let op_3 = fixed_point_64::divide_trunc(op_2, target);
        let fee_fp = fixed_point_64::sub(max_fee, op_3);
        fixed_point_64::to_u64_round_up(fee_fp, 5)
    }

    /// TODO: Make sure user's can't game reward system by staking/unstaking close to epoch boundaries
    /// Distribute rewards to all users in the form of an IOU that can be redeemed for an equivalent amount of APT.
    /// The user's wallet balance is not updated with orAPT. Rather, there is a separate button a user will be able to
    /// Call to collect their rewards.
    fun distribute_rewards() acquires Rewards, EpochTracker, StakePools {
        let admin_addr = @openrails;
        let rewards = borrow_global_mut<Rewards>(admin_addr);
        let total_rewards = get_total_rewards();

        // Distribute rewards to OpenRails.
        // OpenRails' comission is a flat 10% from the total rewards
        let openrails_reward = total_rewards / 10;
        let iter_key = iterable_table::head_key(&rewards.openrails);
        let key = option::borrow(&iter_key);
        let (openrails_iou, _prev_key, _next_key) =
            iterable_table::borrow_iter_mut(&mut rewards.openrails, *key);
        *openrails_iou = *openrails_iou + openrails_reward;

        // Distribute rewards to seed stakers.
        // OpenRails' comission is a flat 10% from the total rewards
    }

    /// This function should be called every epoch such that it finds the rewards (accrued APT) from the previous epoch.
    fun get_total_rewards(): u64 acquires EpochTracker, StakePools {
        let admin_addr = @openrails;
        let current_epoch = reconfiguration::current_epoch();
        let epoch_tracker = borrow_global_mut<EpochTracker>(admin_addr);

        // Ensures crank can only run once per epoch
        // TODO: Fix return
        if (current_epoch <= epoch_tracker.epoch) return 0;
        epoch_tracker.epoch = current_epoch;

        let stake_pools = borrow_global_mut<StakePools<StakePoolInfo>>(admin_addr);
        let iter_key = iterable_table::head_key(&stake_pools.stake_pool_table);
        let total_rewards: u64 = 0;
        while (option::is_some(&iter_key)) {
            let key = option::borrow(&iter_key);
            let (stake_pool, _prev_key, next_key) =
                iterable_table::borrow_iter_mut(&mut stake_pools.stake_pool_table, *key);
            let stake_pool_signer = account::create_signer_with_capability(&stake_pool.signer_cap);
            let stake_pool_addr = signer::address_of(&stake_pool_signer);
            // Get the current balances at the start of the epoch
            let (curr_active, curr_inactive, curr_pending_active, curr_pending_inactive) =
                stake::get_stake(stake_pool_addr);

            // Get a dangling reference error if I turn this into a function
            let prev_active = stake_pool.prev_epoch_balances.active;
            let _prev_inactive = stake_pool.prev_epoch_balances.inactive;
            let prev_pending_active = stake_pool.prev_epoch_balances.pending_active;
            let _prev_pending_inactive = stake_pool.prev_epoch_balances.pending_inactive;

            // Equation to find the cumulative amount of APT awarded between epochs
            total_rewards = total_rewards + curr_active - prev_active - prev_pending_active;

            // Update the prev values to be the curr ones such that when the next epoch crank is called, the values are up-to-date
            stake_pool.prev_epoch_balances.active = curr_active;
            stake_pool.prev_epoch_balances.inactive = curr_inactive;
            stake_pool.prev_epoch_balances.pending_active = curr_pending_active;
            stake_pool.prev_epoch_balances.pending_inactive = curr_pending_inactive;

            iter_key = next_key;
        };

        total_rewards
    }

    // =============== Public Entry Functions ===============

    // =============== Tests ===============

    // #[test_only]
    // use std::option;
    //
    // #[test(admin=@0x222, test_user=@0x111, core = @std)]
    // fun test_end_to_end(admin: &signer, test_user: &signer, core: signer)
    // acquires StakePoolInfo, OrAptCaps, UserInfo, TotalorAPT {
    //     let admin_addr = signer::address_of(admin);
    //     let user_addr = signer::address_of(test_user);
    //     account::create_account_for_test(admin_addr);
    //     account::create_account_for_test(user_addr);
    //
    //     let stake_pool_addr = @0x123;
    //     let decimals: u8 = 9;
    //
    //     initialize(admin, stake_pool_addr, decimals);
    //
    //     // Mint some AptosCoin to test_user
    //     let amount: u64 = 100;
    //     coin::register<aptos_coin::AptosCoin>(test_user);
    //     let (burn_cap, mint_cap) = aptos_coin::initialize_for_test(&core);
    //     let apt_minted = coin::mint(amount, &mint_cap);
    //     coin::deposit(user_addr, apt_minted);
    //
    //     // Before deposit to StakePoolInfo
    //     assert!(coin::balance<aptos_coin::AptosCoin>(user_addr) == amount, EWRONG_BAL);
    //     assert!(coin::is_account_registered<StakedAptosCoin>(user_addr) == false, ECOIN_INCORRECT_REG);
    //
    //     stake(test_user, amount);
    //
    //     // After deposit
    //     assert!(coin::balance<aptos_coin::AptosCoin>(user_addr) == 0, EWRONG_BAL);
    //     assert!(coin::balance<StakedAptosCoin>(user_addr) == amount, EWRONG_BAL);
    //     assert!(coin::supply<StakedAptosCoin>() == option::some((amount as u128)), EWRONG_BAL);
    //
    //     unstake(test_user, amount);
    //
    //     // After withdraw
    //     assert!(coin::balance<aptos_coin::AptosCoin>(user_addr) == amount, EWRONG_BAL);
    //     assert!(coin::balance<StakedAptosCoin>(user_addr) == 0, EWRONG_BAL);
    //     assert!(coin::supply<StakedAptosCoin>() == option::some(0), EWRONG_BAL);
    //
    //     coin::destroy_burn_cap(burn_cap);
    //     coin::destroy_mint_cap(mint_cap);
    //
    // }
    //
    // // =============== Tests ===============
}