# A Junior Developer's Guide to `DSCEngineTest.t.sol`

This guide explains the tests in [`test/unit/DSCEngineTest.t.sol`](./test/unit/DSCEngineTest.t.sol), the behavior they check in [`src/DSCEngine.sol`](./src/DSCEngine.sol), and a practical way to write similar Solidity tests with Foundry.

The test file is not the protocol itself. It is a local, repeatable environment for asking: “When a user does this, does the contract produce the correct result, or reject the action for the correct reason?”

## 1. What the system does

The project implements a collateral-backed stablecoin:

- A user deposits approved collateral tokens, such as WETH or WBTC, into `DSCEngine`.
- The engine reads a price feed to value the collateral in USD.
- The user can mint DSC against that collateral, but must keep enough collateral to remain safe.
- A user can burn DSC and redeem collateral.
- A liquidator can repay some of an unhealthy user's DSC debt and receive collateral plus a bonus.

The tests focus on the engine's behavior and its integration with the DSC token, collateral tokens, and price feeds. They use local mocks so results are fast and predictable.

## 2. The test file's structure

### Imports and test contract

`DSCEngineTest` inherits from `forge-std/Test.sol`'s `Test` contract. This gives it Foundry cheatcodes and assertion helpers, including:

- `vm.prank(address)` to make the next contract call come from an address.
- `vm.startPrank(address)` and `vm.stopPrank()` to make a sequence of calls come from an address.
- `vm.expectRevert(...)` to require the next call to revert.
- `vm.expectEmit(...)` to check an emitted event.
- `assertEq(...)` to compare expected and actual values.

The test imports production contracts, deployment/configuration scripts, and test doubles (mocks). The mocks can set up conditions such as a changed price or a token transfer/mint failure without relying on a live network.

### Shared state and `setUp()`

Foundry calls `setUp()` before each test. It:

1. Deploys the DSC token and engine through `DeployDSC`.
2. Gets the configured token and feed addresses from `HelperConfig`.
3. Gives the test user some native ETH on the local Anvil chain.
4. Mints mock WETH and WBTC tokens to the test user.

Each test therefore starts with a fresh deployment and known balances. A test should not depend on another test having run first.

The shared values make scenarios easier to read:

| Name | Meaning |
|---|---|
| `user` | The account whose collateral or debt is usually under test. |
| `liquidator` | A separate account that attempts liquidations. |
| `amountCollateral` | The usual user collateral amount: `10 ether` (10 WETH with 18 decimals). |
| `amountToMint` | The usual DSC debt: `100 ether` (100 DSC with 18 decimals). |
| `collateralToCover` | A common collateral amount assigned to the liquidator. |
| `MIN_HEALTH_FACTOR` | `1e18`, the fixed-point representation of a health factor of 1.0. |

`ether` is a Solidity unit: `10 ether` means `10 * 10^18` base units. DSC and the mock collateral tokens use 18 decimal places in these tests.

### Setup modifiers

The modifiers are reusable scenario setup:

- `depositCollateral` makes `user` approve the engine and deposit `amountCollateral` WETH.
- `depositedCollateralAndMintedDsc` performs that deposit and mints `amountToMint` DSC.
- `liquidated` prepares a price-drop scenario, funds a liquidator, and performs a liquidation.

This avoids copying common setup into every test. Use a modifier when a scenario is repeated and its setup is easy to understand from the modifier's name. Keep test-specific or unusual setup in the test itself so it remains visible.

## 3. What behavior the test sections cover

The comments divide the file by the contract feature being tested:

1. **Constructor:** Reject mismatched collateral-token and price-feed array lengths.
2. **Price conversion:** Check USD-to-token and token-to-USD calculations.
3. **Collateral deposits:** Check zero amounts, unsupported tokens, failed transfers, recorded balances, and deposit events.
4. **Minting:** Check safe minting, zero minting, failed minting, missing collateral, and health-factor protection.
5. **Burning:** Check zero amounts, balances, and successful debt reduction.
6. **Redemption:** Check zero amounts, transfer failures, successful collateral returns, and emitted events.
7. **Health factor:** Check a healthy position and the effect of a price drop.
8. **Liquidation:** Check that healthy users cannot be liquidated, that liquidation must improve health, and that collateral/debt accounting is correct.
9. **View functions:** Check getters expose expected configuration and account data.

Together, these tests check both successful behavior and important failure boundaries. A good test suite needs both: checking only the happy path would miss invalid actions that the contract must reject.

## 4. Worked example: `testCantLiquidateGoodHealthFactor`

The test is in the liquidation section. Its goal is to prove that a liquidator cannot liquidate a position while that position is still healthy.

### The protocol rule

The engine calculates a health factor from the user's collateral value and DSC debt. In simplified form:

```text
adjusted collateral = collateral value * liquidation threshold / 100
health factor       = adjusted collateral / DSC debt
```

The code uses 18-decimal fixed-point arithmetic, so a health factor of `1.0` is represented by `1e18`. A position is liquidatable only when its health factor is **below** `1e18`. At or above that minimum, `liquidate` reverts with `DSCEngine__HealthFactorOk`.

The test configuration uses an ETH price of $2,000 and a 50% liquidation threshold. The user's 10 WETH is therefore worth $20,000:

```text
10 WETH * $2,000/WETH = $20,000 collateral
$20,000 * 50%         = $10,000 adjusted collateral
$10,000 / 100 DSC     = 100 health factor
```

That is safely above the minimum of 1.

### What the test does, step by step

The test body is:

```solidity
function testCantLiquidateGoodHealthFactor() public depositedCollateralAndMintedDsc {
    ERC20Mock(weth).mint(liquidator, collateralToCover);

    vm.startPrank(liquidator);
    ERC20Mock(weth).approve(address(dscEngine), collateralToCover);
    dscEngine.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);
    dsc.approve(address(dscEngine), amountToMint);

    vm.expectRevert(
        abi.encodeWithSelector(
            DSCEngine.DSCEngine__HealthFactorOk.selector,
            dscEngine.getHealthFactor(user)
        )
    );
    dscEngine.liquidate(weth, user, amountToMint);
    vm.stopPrank();
}
```

The modifier runs before the body, so first the original `user` deposits 10 WETH and mints 100 DSC.

Then the body:

1. **Funds the liquidator.** The mock WETH gives the liquidator `collateralToCover` tokens.
2. **Sets the caller.** `vm.startPrank(liquidator)` makes subsequent calls come from the liquidator until `vm.stopPrank()`.
3. **Approves and deposits collateral.** The liquidator deposits collateral and mints their own 100 DSC. This supplies the DSC needed to try paying off the user's debt.
4. **Approves DSC.** The engine will need permission to transfer the liquidator's DSC if liquidation proceeds.
5. **Specifies the expected error.** `expectRevert` requires the next call to fail with `DSCEngine__HealthFactorOk` and the user's current health factor as its argument.
6. **Attempts liquidation.** The engine checks the target user's health factor before transferring tokens. Since it is healthy, it reverts. The test passes only if the expected error is observed.

The liquidator's own deposit and DSC are deliberate: the test aims to isolate the target user's health-factor rule, rather than fail early because the liquidator lacks funds or approval.

### Why use the exact custom error?

`vm.expectRevert()` with no argument checks only that a revert happened. Here the encoded selector and argument make the assertion more specific:

```solidity
abi.encodeWithSelector(
    DSCEngine.DSCEngine__HealthFactorOk.selector,
    expectedHealthFactor
)
```

This catches regressions where the call reverts for the wrong reason or reports the wrong health factor. The expression `dscEngine.getHealthFactor(user)` is evaluated while preparing the expectation; it gives the value that `liquidate` should include in its error.

Because a revert rolls the attempted transaction back, the failed liquidation must not transfer the user's collateral or burn the liquidator's DSC. A stronger test could additionally assert those balances and debt values are unchanged after the revert, especially if protecting rollback behavior is important to the feature.

## 5. Tests with their own setup, explained line by line

`setUp()` still runs before every test below. “Own setup” means the test adds a special local fixture on top of the standard deployment, often because the regular DSC or collateral token cannot produce the failure needed for that test.

### `testRevertsIfMintFails`

**Goal:** Reach the engine's `DSCEngine__MintFailed` branch. The engine expects `dsc.mint(...)` to return `true`; this mock actually creates the tokens but returns `false`.

| Test statement | What it does and why |
|---|---|
| `function testRevertsIfMintFails() public {` | Starts a separate test. It has no scenario modifier because this test needs a custom DSC contract rather than the normal DSC deployed in `setUp()`. |
| `MockFailedMintDSC mockDsc = new MockFailedMintDSC();` | Deploys a deliberately faulty DSC mock. Its `mint` function mints tokens, then returns `false`. That behavior lets the test exercise the engine's explicit false-return check rather than a normal successful mint. |
| `tokenAddresses = [weth];` | Configures WETH as the only collateral token for the custom engine. The standard `setUp()` has already deployed and funded the WETH mock. |
| `feedAddresses = [ethUsdPriceFeed];` | Pairs WETH with its USD price feed. The token and feed arrays must have matching lengths and corresponding positions. |
| `address owner = msg.sender;` | Saves the test's current caller as the account that will own the newly deployed mock and deploy the custom engine. |
| `vm.prank(owner);` | Makes the next external call come from `owner`. The following deployment makes that address the mock's initial `Ownable` owner. |
| `DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));` | Deploys a separate engine wired to WETH, its price feed, and the faulty DSC mock. The regular `dscEngine` remains untouched. |
| `mockDsc.transferOwnership(address(mockDsce));` | Gives the engine permission to call the mock's `onlyOwner mint`. This is essential: without the ownership transfer, the mock would revert with an ownership error, and the engine's `!minted` check would never be tested. |
| `vm.startPrank(user);` | Makes the following setup and protocol calls originate from the user who will deposit collateral and attempt to mint. |
| `ERC20Mock(weth).approve(address(mockDsce), amountCollateral);` | Approves the custom engine to pull WETH from the user. ERC-20 `transferFrom` requires this allowance. |
| `vm.expectRevert(DSCEngine.DSCEngine__MintFailed.selector);` | Tells Foundry that the next call must revert with the engine's custom mint-failure error. |
| `mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);` | Runs the combined action. Collateral deposit and health-factor validation succeed; the DSC mock then returns `false`, so the engine raises `DSCEngine__MintFailed`. |
| `vm.stopPrank();` | Ends the user impersonation so it cannot accidentally affect later calls in this test. |

**Execution detail:** The mock's `_mint` happens before it returns `false`, and the engine has already updated its debt mapping. However, the engine then reverts. EVM reverts roll back the entire transaction, including those earlier state changes and the collateral deposit made by this combined call.

### `testRevertsIfTransferFromFails`

**Goal:** Verify that a collateral token returning `false` from `transferFrom` causes `depositCollateral` to revert with `DSCEngine__TokenTransferFailed`.

| Test statement | What it does and why |
|---|---|
| `address owner = msg.sender;` | Saves the account used to deploy the fixture contracts. |
| `vm.prank(owner);` | Sets the caller for the next contract creation. |
| `MockFailedTransferFrom mockCollateralToken = new MockFailedTransferFrom();` | Deploys an ERC-20 mock whose `transferFrom` always returns `false`. Its ordinary `approve` and `mint` behavior remains available. |
| `tokenAddresses = [address(mockCollateralToken)];` | Makes the failing token the custom engine's one allowed collateral token. |
| `feedAddresses = [ethUsdPriceFeed];` | Gives that token a feed so the custom engine constructor receives equal-length arrays. The deposit failure occurs before any price valuation is needed. |
| `vm.prank(owner);` | Explicitly sets the caller for the next call, the custom engine deployment. |
| `DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(dsc));` | Creates an engine that accepts the failing token as collateral but uses the normal DSC token for its stablecoin. Keeping those roles separate helps make the failure specifically about collateral transfer. |
| `mockCollateralToken.mint(user, amountCollateral);` | Gives the user enough test collateral. The mock exposes a public mint for test setup. |
| `vm.startPrank(user);` | Makes the approval and deposit originate from the funded user. |
| `ERC20Mock(address(mockCollateralToken)).approve(address(mockDsce), amountCollateral);` | Approves the engine. The cast lets the test call the inherited ERC-20 `approve` function through the common mock type. |
| `vm.expectRevert(DSCEngine.DSCEngine__TokenTransferFailed.selector);` | Requires the next engine call to report its token-transfer failure error. |
| `mockDsce.depositCollateral(address(mockCollateralToken), amountCollateral);` | Calls deposit. The engine's collateral accounting is tentatively updated, then `transferFrom` returns `false`; the engine reverts. |
| `vm.stopPrank();` | Ends impersonation of the user. |

The mock's `transferFrom` returns `false` instead of moving tokens. The test deliberately provides a balance and allowance so the expected failure is the token's false return, not insufficient funds or missing approval.

### `testRevertsIfTransferFails`

**Goal:** Verify that failed outbound collateral transfer during redemption maps to `DSCEngine__TokenTransferFailed`.

| Test statement | What it does and why |
|---|---|
| `address owner = msg.sender;` | Saves the fixture deployer address. |
| `vm.prank(owner);` | Sets the next deployment's caller. |
| `MockFailedTransfer mockDsc = new MockFailedTransfer();` | Deploys a token whose `transfer` always returns `false`, while inherited `transferFrom` still works. That distinction lets deposit succeed and redemption fail. |
| `tokenAddresses = [address(mockDsc)];` | Registers the mock token as the custom engine's collateral token. |
| `feedAddresses = [ethUsdPriceFeed];` | Supplies the corresponding feed, so constructor array lengths match. |
| `vm.prank(owner);` | Sets the caller for the next custom-engine deployment. |
| `DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));` | Deploys an engine that uses this same mock both as collateral and as the DSC interface. The redemption test exercises the collateral transfer path; it does not mint or burn DSC. |
| `mockDsc.mint(user, amountCollateral);` | Gives the user enough mock tokens to deposit. This mock's test mint is public. |
| `vm.prank(owner);` | Sets the caller for the ownership transfer that follows. |
| `mockDsc.transferOwnership(address(mockDsce));` | Makes the engine the mock token's owner, consistent with the normal deployment's engine-controlled DSC. This is not what makes `transfer` fail; the mock override does that. |
| `vm.startPrank(user);` | Makes the approval, deposit, and redemption originate from the user. |
| `ERC20Mock(address(mockDsc)).approve(address(mockDsce), amountCollateral);` | Approves the engine to pull the mock token during deposit. |
| `mockDsce.depositCollateral(address(mockDsc), amountCollateral);` | Deposits using inherited `transferFrom`, which succeeds and establishes the user's collateral position. This is necessary setup so redemption reaches the outbound transfer. |
| `vm.expectRevert(DSCEngine.DSCEngine__TokenTransferFailed.selector);` | Requires the redemption attempt to fail with the engine's transfer error. |
| `mockDsce.redeemCollateral(address(mockDsc), amountCollateral);` | The engine tentatively subtracts recorded collateral, then calls the mock's overridden `transfer`, which returns `false`; the engine reverts. |
| `vm.stopPrank();` | Ends the user impersonation. |

Because redemption reverts, the tentative collateral accounting change and event are rolled back as part of the same transaction.

### `testMustImproveHealthFactorOnLiquidation`

**Goal:** Check that a liquidation is rejected if the target user's health factor is not higher after liquidation. This test needs a special DSC mock that changes the price feed while the engine is burning DSC.

| Test statement | What it does and why |
|---|---|
| `MockMoreDebtDSC mockDsc = new MockMoreDebtDSC(ethUsdPriceFeed);` | Deploys a DSC-like token configured with the ETH/USD feed. Its `burn` function changes that feed's answer to zero before burning. That injected behavior creates an unhealthy ending calculation at a precise point in the liquidation flow. |
| `tokenAddresses = [weth];` | Uses WETH as the custom engine's collateral. |
| `feedAddresses = [ethUsdPriceFeed];` | Pairs WETH with the feed that the mock will later change. |
| `address owner = msg.sender;` | Saves the account that deploys the custom engine and initially owns the mock DSC. |
| `vm.prank(owner);` | Sets the caller for custom-engine deployment. |
| `DSCEngine mockDsce = new DSCEngine(tokenAddresses, feedAddresses, address(mockDsc));` | Creates an isolated engine using the special DSC mock, leaving the normal engine/token pair alone. |
| `mockDsc.transferOwnership(address(mockDsce));` | Lets the engine call the mock's `onlyOwner` `mint` and `burn` functions. Without this, the test would stop at an ownership failure. |
| `vm.startPrank(user);` | Sets the original borrower as caller. |
| `ERC20Mock(weth).approve(address(mockDsce), amountCollateral);` | Approves the custom engine to transfer the user's WETH. |
| `mockDsce.depositCollateralAndMintDsc(weth, amountCollateral, amountToMint);` | Creates the target position: 10 WETH collateral and 100 DSC debt at the normal $2,000 feed price. |
| `vm.stopPrank();` | Ends the borrower's calls before switching actors. |
| `collateralToCover = 1 ether;` | Chooses how much WETH to give the liquidator for its own position in this scenario. |
| `ERC20Mock(weth).mint(liquidator, collateralToCover);` | Funds the liquidator with the WETH it is about to deposit. |
| `vm.startPrank(liquidator);` | Switches subsequent calls to the liquidator. |
| `ERC20Mock(weth).approve(address(mockDsce), collateralToCover);` | Approves the engine to pull the liquidator's WETH. |
| `uint256 debtToCover = 10 ether;` | Sets the attempted partial repayment to 10 DSC. It is intentionally less than the user's 100 DSC debt. |
| `mockDsce.depositCollateralAndMintDsc(weth, collateralToCover, amountToMint);` | Gives the liquidator its own collateral-backed DSC, which it needs to repay another user's debt. |
| `mockDsc.approve(address(mockDsce), debtToCover);` | Allows the engine to transfer the liquidator's 10 DSC during liquidation. |
| `int256 ethUsdUpdatedPrice = 18e8;` | Prepares the new price: the feed has 8 decimals, so `18e8` represents $18 per WETH. This makes the target's 10 WETH worth $180 and its health factor fall below 1. |
| `MockV3Aggregator(ethUsdPriceFeed).updateAnswer(ethUsdUpdatedPrice);` | Applies the price drop before liquidation. At $18, the target starts below the liquidation threshold and is eligible for liquidation. |
| `vm.expectRevert(DSCEngine.DSCEngine__HealthFactorNotImproved.selector);` | Requires the engine's post-liquidation health-improvement guard to be the reason the call fails. |
| `mockDsce.liquidate(weth, user, debtToCover);` | Begins liquidation. The engine sees an unhealthy target, calculates collateral to seize, redeems it, and calls the DSC mock's `burn`. That burn changes the feed to zero. The engine then rechecks the target; zero collateral value gives a zero ending health factor, which is not greater than the starting factor, so it reverts with `HealthFactorNotImproved`. |
| `vm.stopPrank();` | Ends the liquidator's impersonation. |

This is an intentionally adversarial test double, not a realistic DSC implementation: it changes an oracle as a side effect of burning. It is useful for forcing the engine's ending-health-factor guard to fail. Since the transaction reverts, its attempted collateral transfer, DSC burn, and price-feed update are all rolled back.

### Other tests that arrange state directly

These are shorter, but their setup is still part of the test's meaning:

- **`testRevertsIfTokenAddressesAndPriceFeedAddressesDontMatch`:** Pushes one token address and two feed addresses, expects the constructor's length-mismatch custom error, then calls `new DSCEngine(...)`. This tests validation at deployment time. The constructor arguments are passed in reverse array-name order in this test, but the lengths still differ, so it reaches the same length guard; using the semantically correct order would make the test clearer.
- **`testCanRedeemDepositedCollateral`:** Starts acting as `user`, approves WETH, approves DSC, deposits collateral and mints DSC, approves DSC again, then calls `redeemCollateralForDsc`. The bundled function burns DSC and redeems collateral in one transaction. The first DSC approval occurs before DSC exists and is not needed for the deposit/mint operation; the second approval after mint is the one needed for burning.
- **`testGetCollateralBalanceOfuser`:** Starts acting as `user`, approves WETH, deposits it, stops impersonating, reads the engine's per-user/per-token collateral mapping through a getter, and asserts it equals the deposited amount.
- **`testGetAccountCollateralValue`:** Uses the same approve-and-deposit setup, then reads the user's total collateral value and compares it with the USD conversion for the deposited WETH.
- **`testRevertsWithUnapprovedCollateral`:** Creates a new random ERC-20 that was not registered in the engine constructor, then calls `depositCollateral` as the user and expects `TokenNotAllowed`. It tests the allowlist check, not token transfer behavior.

When reviewing a test without a modifier, first identify the baseline from `setUp()`, then read the test's local setup in order. Setup is not incidental: balances, approvals, ownership, token wiring, and price changes determine which branch the test reaches.

## 6. A small end-to-end simulation

Suppose the price feed says 1 WETH = $2,000:

1. Alice deposits 10 WETH, worth $20,000.
2. Alice mints 100 DSC.
3. At a 50% threshold, her adjusted collateral is $10,000, so her health factor is 100. She is healthy.
4. Bob deposits collateral and mints DSC so he has the resources to act as a liquidator.
5. Bob calls `liquidate(WETH, Alice, 100 DSC)`.
6. The engine checks Alice's health factor before doing liquidation work. Since it is greater than 1, the engine reverts with `DSCEngine__HealthFactorOk`.

A separate price-drop test shows the other side of the boundary: the suite changes the mock feed to $18, after which the user's health factor falls below 1. That demonstrates how the test can simulate changing external conditions without waiting for a real market move.

## 7. A reusable pattern for writing tests

Most tests can follow **Arrange – Act – Assert**:

```solidity
function testRejectsAnUnsafeAction() public {
    // Arrange: make the state and caller explicit.
    vm.startPrank(user);
    ERC20Mock(weth).approve(address(dscEngine), amountCollateral);
    dscEngine.depositCollateral(weth, amountCollateral);

    uint256 expectedHealthFactor = dscEngine.calculateHealthFactor(
        amountToMint,
        dscEngine.getUsdValue(weth, amountCollateral)
    );

    // Act / Assert: require this exact operation to fail in this exact way.
    vm.expectRevert(
        abi.encodeWithSelector(
            DSCEngine.DSCEngine__HealthFactorIsBroken.selector,
            expectedHealthFactor
        )
    );
    dscEngine.mintDsc(amountToMint);
    vm.stopPrank();
}
```

Use the pattern as a guide, not a template to copy blindly:

- **Arrange:** Set balances, approvals, price feeds, and caller identity before the behavior under test.
- **Act:** Make the one contract call whose behavior is being tested.
- **Assert:** Check its return value, resulting state, emitted event, or expected revert.

For a successful operation, assert an observable result. For example, after a mint, check the user's DSC balance; after a deposit, check the engine's recorded collateral balance. For a revert test, place `expectRevert` immediately before the call that should revert.

## 8. Foundry testing ideas used here

### Test names are executable documentation

Names such as `testCanMintDsc`, `testRevertsIfRedeemAmountIsZero`, and `testCantLiquidateGoodHealthFactor` state the behavior under test. Prefer one behavior per test so a failure points to one rule.

### Simulate callers deliberately

Contracts see `msg.sender`, not the test author's intention. Use `vm.prank(user)` for one call and `vm.startPrank(user)` / `vm.stopPrank()` for several. Stop a prank when the scenario changes actors, and avoid accidentally making setup calls from the wrong account.

### Use mocks for external dependencies

Price feeds and ERC-20 tokens are external contracts. Mocks let tests control their answers and failure modes. For example, `MockV3Aggregator.updateAnswer(...)` changes the price deterministically, and the failing-token mocks exercise error paths.

### Test boundaries, not only typical values

The suite checks zero amounts, unsupported tokens, broken health factors, and healthy liquidation attempts. For a new feature, consider:

- The smallest valid value and zero.
- A value just below, at, and just above an important threshold.
- Missing approvals or insufficient balances.
- External calls that fail.
- The expected event and state changes on success.

### Check events with the event declaration

`vm.expectEmit(...)` takes booleans for indexed topics and data, plus the address expected to emit. The test declares the expected event before calling the engine. Make the flags match which event fields are indexed and whether non-indexed data should be compared.

### Be careful with oracle units

The mock feed has 8 decimals (`2000e8` represents $2,000). Token amounts and DSC use 18 decimals. The engine's precision constants convert between them. Prefer asking the contract for a calculated expected value or deriving it from the documented units instead of comparing incompatible raw integers.

## 9. Running and debugging these tests

From the repository root:

```bash
# Run the whole suite
forge test

# Run only the selected liquidation test
forge test --match-test testCantLiquidateGoodHealthFactor -vv

# Run tests in this test file
forge test --match-path test/unit/DSCEngineTest.t.sol
```

If a test fails:

1. Read the failure message and the test name first.
2. Check whether the revert was missing, unexpected, or carried the wrong argument.
3. Verify `msg.sender`, token approvals, balances, and setup modifier effects.
4. Recalculate token/USD decimal conversions and health factor values.
5. Run the focused test again before running the full suite.

## 10. Checklist for adding a Solidity test

- [ ] Is the test for one clearly named behavior?
- [ ] Does `setUp()` or the test itself establish all required state?
- [ ] Is the caller explicitly set where `msg.sender` matters?
- [ ] Are token balances and approvals sufficient for the intended path?
- [ ] Does the test check the important observable result, not just that the call did not revert?
- [ ] For a failure, does it assert the correct custom error and arguments?
- [ ] Are external dependencies mocked so the scenario is deterministic?
- [ ] Does the focused test pass, and does the related suite still pass?

The most useful tests read like short explanations of a protocol rule: establish a realistic state, perform one action, and prove the exact behavior that must always hold.
