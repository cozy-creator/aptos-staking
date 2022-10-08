![Stake Router](./static/stake_router_octopie_small.png 'Stake Router')

## Shared Stake Pool by OpenRails

### Disclaimer!

This module is just an initial rough draft; do not use this in mainnet or with any real monetary value until after it's passed a full security audit.

### How to Use This

We only have CLI commands available at the moment. Please install the Aptos CLI and then use the following commands. First you'll need to specify the address where our module is deployed at:

Devnet address: 0x653edb913f80cc763a29fb63b5418659f830e1dd966ea9c2ebefbdd684b40bee
Testnet address: (coming soon)
Mainnet address: (coming soon)

`export OPENRAILS=<address>`

This will create the constant OPENRAILS that resolves to one of the above addresses. Next up, we'll do the same for your address:

`export STAKEPOOL=<address>`

This will be the address where your stake pool is initialize at (if you initialize it, it'll be at your own address).

Now use one of the following commands:

- **Initialize:** this will create the openrails::shared_stake::Shared_Stake::SharedStakePool and aptos_framework::stake::StakePool resources at your address. We can only call this once per address; stake pools cannot be overwritten and you can only have one.

`aptos move run --function-id $OPENRAILS::shared_stake::initialize`

The shared stake pool will take possession of the stake_pool's owner_cap; this means that even though the stake pool is at your address, you won't be able to remove yours or anyone's funds from the stake pool, except by going through the shared_stake's interface functions. Your address will be set as the operator by default; this can be changed through the shared stake pool's governance (more on this below). Aside from being able to take over the governance cap and being the initial operator, your account has no special privileges over the shared stake pool.

Note that if these transactions are failing by running out of gas, try increasing the amount of gas you use, by adding `--max-gas 1000` to the end of these transactions.

- **Deposit:** anyone can deposit at any time; there is no permissioning system. To deposit, simply run:

`aptos move run --function-id $OPENRAILS::shared_stake::deposit --args address:$STAKEPOOL u64:$AMOUNT`

Fill in $AMOUNT with the number of APT coins you want to deposit. Note that for all commands here and below, APT has 8 decimals of precision, so 10000000 = 1 APT, 100000 = 0.001 APT, etc.

- **Unlock:** -

`aptos move run --function-id $OPENRAILS::shared_stake::unlock --args address:$STAKEPOOL u64:$AMOUNT`

- **Cancel Unlock:** -

- `aptos move run --function-id $OPENRAILS::shared_stake::cancel_unlock --args address:$STAKEPOOL u64:$AMOUNT`

- **Withdraw:** -

- `aptos move run --function-id $OPENRAILS::shared_stake::withdraw --args address:$STAKEPOOL u64:$AMOUNT`

### What This is

This module is intended to be the standard for all validator-operators and stakers on Aptos. Having a single Shared Stake Pool module will make compsability easier.

### Why We Made This:

The aptos_framework::stake module provides the basis for staking within Aptos. However, that module is designed only for a single-person; all the money within the StakePool belongs to whomever possess the owner_cap. That is to say, there is no way to trustlessly share a StakePool with someone else; whoever has the owner_cap could steal all your StakePool money easily. Furthermore, the aptos_framework::stake module is permissioned; you cannot deposit stake into another person's stake pool, only the possessor of owner_cap can do that.

Unlike Solana, Aptos creates a distinction between a "StakePool owner" and an "operator". StakePool owners bond money, while operators run the physical machines that validate the Aptos network, earning rewards every epoch dependent upon the operator peformance. Unfortunately, the aptos_framework::stake module has no built-in way to split epoch-rewards between the StakePool owner and the operator.

For decentralization, Aptos needs permissionless, shared stake pools. ...oh and operators need to get paid.

Hence, why we created this SharedStakePool module; it is essentially a wrapper on top of StakePool. This module creates a StakePool, and then takes possession of its owner_cap, meaning it now has full control of the money within the StakePool. Whenever someone deposits, unlocks, or withdraws money, the SharedStakePool keeps track of how much each individual person is owed by maintaining an internal ledge of stakeholders, not by granting derivative tokens.

Furthermore, it tracks rewards as they're earned, and pays an agreed-upon commission to the operator every epoch.

### This Module Is:

- Trustless: aside from trusting the logical soundness of this module and the Aptos network itself, and trusting any future upgrades OpenRails may make to the module, you do not have to trust the operator (validator), the module authors, or anyone else you are sharing a SharedStakePool with. They can never take your money. The worst a bad-operator can do is fail to produce blocks (hence earning you no interest). There are no slashing penalities yet on Aptos, but potentially in the future you could lose some of your staked money if your operator behaves maliciously and attacks the network.

- Permissionless: anyone can deposit any amount of money within any StakePool and earn money; there is no authorization or KYC required. There is no way for any person or authority to exclude or censor you. Aside from the usual pseudonymous transaction record on the Aptos public ledger, you retain fully privacy.

- Self-Sovereign: This program is designed with a modular governance_cap, which can be removed from the SharedStakePool's address, and placed in the custody of a governance module or with some trusted individuals. This allows every SharedStakePool to write its own custom governance structure. For example, if the members of the SharedStakePool are unhappy with the results of their operator, they can vote to fire them and replace them with a new operator. Furthermore, Stakeholders can vote to adjust the compensation of their operator. There is no need for each person to manually and individually migrate their stake to a new SharedStakePool, as in Solana.

### Who this module is for

- Groups of APT bag holders: if you and a couple thousand of your friends are sitting on some APT bags, and you want to run your own Aptos validator, you can form your own SharedStakePool and hire an operator.

- Independent validators: if you're an operator looking to collect enough stake to join Aptos' validator set, you can form a SharedStakePool so that individuals can deposit with you.

In both cases, you will need to meet the minimum stake requirements to join the validator set, which can be quite high.

### How can you trust this module?

Ethereum contracts get exploited all the time; either through unsound code, or through an unsound economic models. We can never guarantee this module is immune to either; use this module at your own risk. OpenRails does not provide any insurance or take any responsibility for any money lost through the use of its code.

That being said, this is a core module whose safety is critical to Aptos. We want to ensure the soundness of this module in any way possible. Here is our security roadmap before this module is ready for use in mainnet:

- Achieve 100% unit-test coverage
- Deploy to Testnet and test it in real-world conditions
- Write a complete .spec file, to fully specify and formally prove correctness of behavior
- Receive a complete audit from a top audit firm

Theoretically, a complete .spec file should ensure that this module is 100% impossible to hack; Move uses formal verification at the bytecode level to guarantee logical correctness. However... I'm not entirely convinced that this is fool-proof yet.

Still; this is the greatest level of security guarantee any developer can ever make. This is a higher level of security guarantee than any Ethereum smart-contract or Solana program can make.

### Upgrade Risk

This module is designed to be upgradeable; it may need to be changed in the future to accommodate changes to how Aptos staking works, and new features may be added. Anyone using our module will benefit from these upgrades the moment they occur. However, this poses a risk; what if we replace our safe, well-functioning module with an insecure or malicious module? An upgrade has to be done carefully. Similar to other Aptos core modules, we'll do our upgrades using a governance vote of some sort.

Details TBD.

### Network Risks

Proof of stake networks can die when their token-emissions are insufficient to support their validator's costs of operation. It doesn't make sense for validators to pay more to operate a chain than they receive in rewards, so they quit. When enough validators quit, a network dies. This has only happened to smaller Cosmos-SDK chains so far, but I imagine in the future even larger chains may face the same fate if their tokens crater in value.

### Minor Details

Any stake added to this SharedStakePool's StakePool must go through the SharedStakePool module; it's not possible to do deposits directly into the StakePool (you need the owner_cap, and this SharedStakePool possess the owner cap). If this bypass-deposit behavior were possible, the SharedStakePool would register this balance change as a reward distribution on the next epoch.

This module has no direct way to observe reward distributions; in Aptos, on-chain modules cannot read historic data, even if it's a publicly viewable event. As a result this module calculates reward distributions manually.

### Technical Aptos Details

- On Aptos, epochs are measured in seconds, not blocks produced.

### How to publish

- Go into the module you want to use (i.e., modules/shared-stake-pools)
- run `aptos init`. This will generate a new random keypair for you and fund it with tokens initially. You may need to request additional tokens from the faucet for publishing large modules
- run `aptos account list` and find your authentication key
- run `aptos move compile --named-addresses openrails=0xa413044c01d22ce1c821e11e3a9f825da6f839ca4beb1937e960555cde8bb56c` or whatever your authentication key was that was generated above
- similarly, you can do `aptos move publish --named-addresses openrails=0xa413044c01d22ce1c821e11e3a9f825da6f839ca4beb1937e960555cde8bb56c`

### Gas Cost Benchmarks

- publish the module: 5,551
- initialize a stake pool: 572
- deposit into stake pool: 532
- unlock: 398
- cancel unlock: 447
- withdraw: 690
- turn the crank (skip): 167
- turn the crank (full): ???

### TO DO

- Extract iterable map into its own module
- Write share chest to be an iterable map
- We could add a pending_unlock resource, which you get, instead of keeping a map of all pending_unlock addresses
- Add full spec file
- Add 100% unit test coverage
- consider scenarios where the StakePool is inactive / pending_active, so that it's not part of the current validator set. Make sure everything is consistent
- write governance sample module
- Add events, in particular around unlocks, rewards, and payments
- Typescript interfaces for external functions calling in
- export the shareholder table such that it can be used in governance
- operators should be able to be paid in stablecoins or other coins if they prefer

### Tests to write

- Make sure the crank is being called in every instance that matters (when tvl changes). Most user-callable functions are tvl-changing events
- Make sure a user's account is still earning interest when unlocking
- Test with large numbers of user accounts; thousands of them all unlocking at once. In particular, test the crank with this. My concern is that the crank may become too heavy to turn if large numbers of users are involved.
- Edge case: when we have to use queued-unlock, which is when a user tries to unlock more than we have in active, but we have a large amount of pending_active available
- Have the validator join and then leave the validator set. Test deposits, unlocks, cancel-unlocks, and withdrawals afterwards
- Every function should have its own separate test
