# PoC — BuildersV4 retroactive withdraw-lock extension (Morpheus Bug Bounty v2)

A subnet admin in BuildersV4 on Base can retroactively and unboundedly extend the
withdraw lock on existing stakers via `editSubnet`, permanently freezing their
principal. `withdraw` evaluates the lock against the **current** subnet struct,
so raising the lock after a victim has staked traps that stake — there is no
position transfer, partial-withdraw escape, or emergency exit in the deployed
contract.

- **Target:** BuildersV4 proxy `0x42BB446eAE6dca7723a9eBdb81EA88aFe77eF4B9` on Base
- **Fork block:** 57479000 (pinned in the test via `vm.createSelectFork`)
- **Demonstrated loss:** 1,000 MOR of victim principal trapped in the contract

## Run it

Requires [Foundry](https://book.getfoundry.sh/getting-started/installation).

```bash
git clone <this-repo>
cd <this-repo>
forge install foundry-rs/forge-std
forge test
```

The test forks Base mainnet from `https://mainnet.base.org` (hardcoded in
`setUp()`); no other setup or RPC configuration is needed.

## Expected result — 2/2 PASS

```
Ran 2 tests for test/PocBuildersLock.t.sol:PocBuildersLockTest
[PASS] testAttack_AdminExtendsLockRetroactively() (gas: 208970)
[PASS] testControl_WithdrawAfterOriginalLock() (gas: 177338)
Suite result: ok. 2 passed; 0 failed; 0 skipped
```

## What the tests do

- `setUp()`: the attacker — a fresh EOA with no roles — creates a subnet via the
  permissionless `createSubnet` (asserts the on-chain `subnetCreationFeeAmount`
  is 0, i.e. creation is currently free) with a 7-day withdraw lock (the
  protocol minimum). The victim — another fresh EOA — stakes 1,000 MOR.
- `testControl_WithdrawAfterOriginalLock()`: with the lock untouched, the
  victim withdraws in full after 8 days. The staking flow works as documented.
- `testAttack_AdminExtendsLockRetroactively()`: the attacker calls `editSubnet`
  raising the lock to 100 years (3,153,600,000 s). The victim's `withdraw`
  reverts with `"BU: user withdraw is locked"` at +8 days and again at +10
  years. The loss is asserted on-chain: `usersData` still records 1,000 MOR
  deposited, the victim's balance is 0, and the stake remains in the
  BuildersV4 contract.

No privileged accounts are used: attacker and victim are fresh EOAs created in
the test; no protocol owner, admin, or multisig is pranked. `deal()` is fork
scaffolding that only funds the two test EOAs with MOR.
