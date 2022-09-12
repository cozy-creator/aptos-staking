## Shared Stake Pool by OpenRails

### Disclaimer!

This module is just an initial rough draft; do not use this in production yet.

### Why We Made This:

The aptos_framework::stake module provides the basis for staking within Aptos. However, that module is designed only for a single-person; all the money within the StakePool belongs to whomever possess the owner_cap. That is to say, there is no way to trustlessly share a StakePool with someone else; whoever has the owner_cap could steal all your StakePool money easily.

Hence, why we created this SharedStakePool module; it is essentially a wrapper on top of StakePool. This module creates a StakePool, and then takes possession of its owner_cap, meaning it now has full control of the money within the StakePool. Whenever someone deposits, unlocks, or withdraws money, the SharedStakePool keeps track of how much each individual person is owed. It does this by maintaining an internal ledger, rather than by granting derivative tokens.

### This Module Is:

- Trustless: aside from trusting the logical soundness of this module and the Aptos network itself, and trusting any future upgrades made to the module, you do not have to trust the operator (validator), the module authors, or anyone else you are sharing a SharedStakePool with. They can never take your money. The worst a bad-operator can do is fail to produce blocks (hence earning you no interest). There are no slashing penalities yet on Aptos, but potentially in the future you could lose some of your staked money if your operator behaves maliciously and attacks the network.

- Permissionless: anyone can deposit any amount of money within any StakePool and earn money; there is no authorization or KYC required. There is no way for any person or authority to exclude or censor you. Aside from the usual pseudonymous transaction record on the Aptos public ledger, you retain fully privacy.

- Self-Sovereign: unlike Solana and Ethereum, a SharedStakePool is not bound to any one operator; if the members of the SharedStakePool are unhappy with the results of their operator, they can vote to fire them and replace them with a new operator. There is no need to migrate their stake to a new SharedStakePool. Furthermore, Shareholders can vote to adjust the compensation of their operator.

### How can you trust this module?

Ethereum contracts get exploited all the time; either through unsound code, or through an unsound economic models. We can never guarantee this module is immune to either; use this module at your own risk. OpenRails does not provide any insurance or take any responsibility for any money lost through the use of its code.

That being said, this is a core module whose safety is critical to Aptos. We want to ensure the soundness of this module in any way possible. Here is our security roadmap before this module is ready for use in mainnet:

- Achieve 100% unit-test coverage
- Deploy to Testnet and test it in real-world conditions
- Write a complete .spec file, to fully specify and formally prove correctness of behavior
- Receive a complete audit from a top audit firm

Theoretically, a complete .spec file should ensure that this module is 100% impossible to hack; Move uses formal verification at the bytecode level to guarantee logical correctness. However... I'm not entirely convinced that this is fool-proof yet.

Still; this is the greatest level of security guarantee any developer can ever make. This is a higher level of security guarantee than Ethereum or Solana can make.

### Upgrade Risk

This module is designed to be upgradeable; it may need to be changed in the future to accommodate changes to how Aptos staking works, and new features may be added. Anyone using our module will benefit from these upgrades the moment they occur. However, this poses a risk; what if we replace our safe, well-functioning module with an insecure or malicious module? An upgrade has to be done carefully. Similar to other Aptos core modules, we'll do our upgrades using a governance vote of some sort.

Details TBD.
