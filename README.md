![Stake Router](./static/stake_router_octopie_small.png 'Stake Router')

## Shared Stake Pool by OpenRails

### Disclaimer!

This module is just an initial rough draft; do not use this in mainnet or with any real monetary value until after it's passed a full security audit.

### What This is

This module is intended to be the standard for all validator-operators and stakers on Aptos. Having a single Shared Stake Pool module will make composability easier. Stake-router (derivative staking, liquid staking) can be built on top of this.

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

### CLI Commands

- Only to be called by the stake pool: `aptos move run --function-id 0xbec1cf784c7b93744687fe7899f7aeafe6fc9a7fc9c758f3f933ec9cf1668f70::shared_stake_pool::initialize`
- `aptos move run --function-id 0xbec1cf784c7b93744687fe7899f7aeafe6fc9a7fc9c758f3f933ec9cf1668f70::shared_stake::deposit --args address:0x6057d69013e3c00ca1e12b1526fa28f3265072cb88b67e7dafc59394ce865e0a u64:200`
- `aptos move run --function-id 0xbec1cf784c7b93744687fe7899f7aeafe6fc9a7fc9c758f3f933ec9cf1668f70::shared_stake::unlock --args address:0x6057d69013e3c00ca1e12b1526fa28f3265072cb88b67e7dafc59394ce865e0a u64:200`
- `aptos move run --function-id 0xbec1cf784c7b93744687fe7899f7aeafe6fc9a7fc9c758f3f933ec9cf1668f70::shared_stake::cancel_unlock --args address:0x6057d69013e3c00ca1e12b1526fa28f3265072cb88b67e7dafc59394ce865e0a u64:200`
- `aptos move run --function-id 0xbec1cf784c7b93744687fe7899f7aeafe6fc9a7fc9c758f3f933ec9cf1668f70::shared_stake::withdraw --args address:0x6057d69013e3c00ca1e12b1526fa28f3265072cb88b67e7dafc59394ce865e0a u64:200`

### Gas Cost Benchmarks

- publish the module: 2,199
- initialize a stake pool: 168
- deposit into stake pool: 157
- turn the crank: ???

### TO DO

- Extract iterable map into its own module
- Rename 'share' to 'StakeShare' and Share.value to StakeShare.share_value (???)
- Write share chest to be an iterable map
- Make the apt_to_share function borrow TVL itself rather than being sent it
- Add full spec file
- Add 100% unit test coverage
- consider scenarios where the StakePool is inactive / pending_active, so that it's not part of the current validator set. Make sure everything is consistent
- write governance sample module
- Add events, in particular around unlocks, rewards, and payments
- Typescript interfaces for external functions calling in
- export the shareholder table such that it can be used in governance
- operators should be able to be paid in stablecoins or other coins if they prefer
