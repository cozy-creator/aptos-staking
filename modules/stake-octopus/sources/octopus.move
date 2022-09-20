// This is the stake router

module openrails::stake_octopus {
    use std::string;
    use std::option;
    use std::signer;
    use aptos_std::simple_map::{Self, SimpleMap};
    use aptos_framework::account::{Self, SignerCapability};
    use aptos_framework::coin::{Self, Coin, BurnCapability, MintCapability};
    use aptos_framework::stake::{Self, OwnerCapability };
    use aptos_framework::aptos_coin::AptosCoin;
    use aptos_framework::resource_account;

    // Errors
    const EUNKNOWN_SUPPLY: u64 = 0;

    const ZERO_AUTH_KEY: vector<u8> = x"0000000000000000000000000000000000000000000000000000000000000000";

    struct OrAPT has key { }

    struct OrAPTCaps has key {
        mint_cap: MintCapability<OrAPT>,
        burn_cap: BurnCapability<OrAPT>
    }

    // We store our reserve aptos coins in a resource account with 0 auth-key so that this module
    // has the sole authority to withdraw aptos coins from it, not anyone with the private key.
    // We do not store any aptos coins in this account, other than what is needed to pay for gas.
    struct ReserveAccount has key {
        addr: address,
        signer_cap: SignerCapability
    }

    // this lists all operator addresses known
    // validators will be selected based on:
    // minimize pay
    // maximize reward
    // make stake distribution even
    // take into account unlock times
    // it would be cool if we could bring off-chain info on-chain
    // such as country or service-provider
    struct OperatorRegistry has key {
        iso_numeric_country_code: u64,
    }

    // this lists all stake pools available
    // it records their performance
    // we also need a way to tell how much stake each pool has
    struct StakePoolRegistry has key {

    }

    struct TotalValueLocked has key {
        value: u64
    }

    // marketing partners
    struct Referrals has key {

    }

    // ============== User entry functions ==============

    // Takes APT and mints orAPT in return. The APT is stored in a reserve until
    // crank_on_epoch end is called.
    public entry fun deposit(account: &signer, amount: u64) acquires ReserveAccount, TotalValueLocked, OrAPTCaps {
        let addr = signer::address_of(account);
        if (!coin::is_account_registered<OrAPT>(addr)) {
            coin::register<OrAPT>(account);
        };

        let apt_coins = coin::withdraw<AptosCoin>(account, amount);
        let orapt_coins = deposit_with_coins(apt_coins);
        coin::deposit<OrAPT>(signer::address_of(account), orapt_coins);
    }

    public fun deposit_with_coins(coins: Coin<AptosCoin>): Coin<OrAPT> acquires ReserveAccount, TotalValueLocked, OrAPTCaps {
        let deposit_value = coin::value(&coins);
        if (deposit_value == 0) {
            coin::destroy_zero<AptosCoin>(coins);
            return coin::zero<OrAPT>()
        };

        let reserve_account = borrow_global<ReserveAccount>(@openrails);
        coin::deposit<AptosCoin>(*&reserve_account.addr, coins);

        let tvl = &mut borrow_global_mut<TotalValueLocked>(@openrails).value;
        *tvl = *tvl + deposit_value;

        let mint_value = apt_to_orapt(deposit_value);
        let mint_cap = &borrow_global<OrAPTCaps>(@openrails).mint_cap;

        coin::mint(mint_value, mint_cap)
    }

    // takes existing stake and returns orAPT
    public fun deposit_existing_stake() {

    }

    public fun deposit_existing_stake_to_coins(): Coin<OrAPT> {

    }

    // find the validators that are unlocking next, and call unstake on those
    public entry fun unlock(account: &signer) {
    }

    public fun unlock_with_coins(coins: Coin<OrAPT>) {

    }

    public entry fun cancel_unlock() {
    }

    public fun cancel_unlock_to_coins(): Coin<OrAPT> {

    }

    // This will withdraw from all of a user's stake pools, wherever inactive stake is
    // available, by calling into shared_stake_pool::withdraw()
    // This does not consume orAPT; use the instake_unstake function instead for that
    public entry fun withdraw(account: &signer, amount: u64) {
    }

    public fun withdraw_to_coins(account: &signer, amount: u64): Coin<AptosCoin> {
        coin::zero<AptosCoin>()
    }

    // places a market-order to exchange orAPT to APT
    // This doesn't require us to unlock or withdraw anything
    public entry fun instant_unstake(account: &signer, amount: u64) {
    }

    public fun instant_unstake_with_coins(coins: Coin<OrAPT>): Coin<AptosCoin> {

    }

    // ============== Network functions ==============

    // Add a shared_stake_pool to our stake-pool registry
    // Must be part of the validator or pending-validator set
    // This must be done manually, because the validator set cannot be introspected
    // We will prune validators automatically if they are removed from the active validator set
    // in order to maintain a high reward rate
    public entry fun register_stake_pool() {}

    // I don't think we need an unregister_stake_pool function

    // ============== Helper functions ==============

    public fun orapt_to_apt(amount: u64): u64 acquires TotalValueLocked {
        (((amount as u128) / orapt_apt_ratio()) as u64)
    }

    public fun apt_to_orapt(amount: u64): u64 acquires TotalValueLocked {
        (((amount as u128) * orapt_apt_ratio()) as u64)
    }

    public fun orapt_apt_ratio(): u128 acquires TotalValueLocked {
        let tvl = *&borrow_global<TotalValueLocked>(@openrails).value;
        let orapt_supply_maybe = coin::supply<OrAPT>();
        assert!(option::is_some<u128>(&orapt_supply_maybe), EUNKNOWN_SUPPLY);
        let orapt_supply = *option::borrow<u128>(&orapt_supply_maybe);

        if (orapt_supply == 0 || tvl == 0) {
            1
        } else {
            ((orapt_supply) / (tvl as u128))
        }
    }

    // ============== Crank functions ==============

    public fun crank_on_epoch_end() {
        // takes stake out of reserve, and puts it into pending_active
        // moves stake to pending_inactive as needed (especially if unlock time is close)
    }

    public fun crank_on_epoch_begin() {
        // tally up our epoch earnings (or losses) for all validators and our pool as a whole
        // this is needed to have the correct orapt / apt ratio
        // we collect our fee and pay our marketing-partners as needed
        // rank each of our validators based on performance and stake
    }

    // The general strategy is:
    // We rank StakePools from positive to negative;
    // negative stakepools we want to move stake away from, positive we want to move stake towards
    // (for whatever reason)
    // Deposit = stake with positive on epoch boundary
    // Unlock = unlock stake with negative immediately
    // cancel-unlock = cancel-unlock on positive immediately
    // withdraw = doesn't matter; comes from wherever
    // deposit_existing_stake_to_coins = we take negative first, so that we can unstake with them later

    fun rank_validators() {}

    // might not use these
    fun deposit_router() {
    }

    fun withdraw_router() {
    }

    // ============== Ad-Hoc Admin functions ==============

    // marks a stake pool as positive manually
    public fun promote_stake_pool() {
    }

    // marks a stake pool as negative manually
    public fun demote_stake_pool() {}

    // pin validator to top of the positive list, so that it can join the validator set
    public fun launch_stake_pool() {}

    // pin to the bottom of the negative list, so that we can drain everything we own out of it
    public fun drain_stake_pool(){ }

    // Does stake router have any parameters to config?
    public fun reconfigure_params() {}

    // these probably won't be possible without governance...
    public fun stagger_lock_times() {}
    public fun change_operator() {}
    public fun something_about_voting_delegation() {}

    // Iniitialization function; this is only ever called once upon deploy
    fun init_module(this: &signer) {
        let addr = signer::address_of(this);

        // Create the orAPT Coin
        let (burn_cap, freeze_cap, mint_cap) = coin::initialize<OrAPT>(
            this,
            string::utf8(b"Staked Aptos"),
            string::utf8(b"orAPT"),
            8,
            true
        );

        coin::destroy_freeze_cap(freeze_cap);
        move_to(this, OrAPTCaps { mint_cap, burn_cap });

        // TO DO: when Aptos governance allows us to, call this
        // coin::upgrade_supply<OrAPT>(this);

        // The problem with this solution is that it requires a second transaction
        // we will need to first do this init_module, which will create a signer_cap, store
        // it inside of a container inside of the resource_account
        // We would then sign a transaction using whatever key we specified here in order to
        // retrieve the resource_account_cap, and then store the signer_cap
        // let pubkey = vector::empty();
        // resource_account::create_resource_account(this, vector[0], pubkey);
        // let signer_cap = resource_account::retrieve_resource_account_cap();

        // If we create a resource account this way, we cannot rotate the key to 0 ever, we
        // can only rotate it to on-curve keypairs.
        // I'll try to add a function to aptos_core that allows accounts to be rotated to 0
        let (resource_signer, signer_cap) = account::create_resource_account(this, vector[0]);
        // account::rotate_authentication_key(&resource_signer, 0, ZERo_AUTH_KEY, 0, ZERO_AUTHKEY)

        // TO DO: aptos-core needs to have either an account::create_resource_account function that
        // returns a signer cap and rotates its key to 0, OR we need to add a function like
        // account::rotate_auth_key_to_zero that locks off accounts. I think the former is a
        // safer solution

        coin::register<AptosCoin>(&resource_signer);
        move_to(this, ReserveAccount { addr: signer::address_of(&resource_signer), signer_cap});
        move_to(this, TotalValueLocked { value: 0 });
    }

}