// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ICreditMatchedLiquidity} from "../src/ICreditMatchedLiquidity.sol";
import {CreditMatchedLiquidity, MulDiv} from "../src/CreditMatchedLiquidity.sol";
import {MockToken, MockPriceFeed, MockMarketSession, MockPositionManager, MockRegistry} from "./mocks/Mocks.sol";

/// @dev The scenario of the ERC's Test Cases: a base token of 18 decimals priced 250 quote by a feed of 8 decimals, a
///      quote token of 6 decimals, a lender lending up to the value of the base brought (limit 10000), unwinding below
///      11000, asking new positions to survive a 20% gap, charging 1%, for 30 days, with prices at most a day old and
///      set in the current session of the base's reference market. The holder brings 100 base and borrows 25,000
///      quote. Mock positions are full-range constant-product liquidity, so a position worth 50,000 at 250 is worth
///      50,000 * sqrt(P / 250) at a price P: healthy at 80 (28,284 >= 1.1 * 25,250), unwindable at 70 (26,457).
/// @notice Tests of the reference implementation. Not audited: never deploy anything here without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
contract CreditMatchedLiquidityTest is Test {
    uint256 constant AGENT = 6592;
    int24 constant LOW = -887_220;
    int24 constant HIGH = 887_220;
    uint256 constant TOL = 1e14; // 0.01%, for amounts that go through a square root
    address constant UNLISTED = address(0xBEEF);

    MockToken quote;
    MockToken base;
    MockPriceFeed feed;
    MockMarketSession session;
    MockPositionManager pm;
    MockRegistry registry;
    CreditMatchedLiquidity cml;

    address pool = makeAddr("pool");
    address lender = makeAddr("lender");
    address fallbackAddr = makeAddr("fallback");
    address holder = makeAddr("holder");
    address stranger = makeAddr("stranger");

    function setUp() public {
        quote = new MockToken(6);
        base = new MockToken(18);
        feed = new MockPriceFeed(8, 250e8);
        session = new MockMarketSession(uint64(block.timestamp)); // the market is open, since now
        pm = new MockPositionManager();
        registry = new MockRegistry();
        pm.setPool(pool, address(base), address(quote), 250e6);
        cml = new CreditMatchedLiquidity(address(quote), address(pm), address(registry), lender, fallbackAddr);
        vm.prank(lender);
        cml.listPool(pool, _terms(address(feed)));

        quote.mint(address(cml), 1_000_000e6); // what the lender lends
        base.mint(address(pm), 1_000_000e18); // the pool's other liquidity, so it can pay out at any price
        quote.mint(address(pm), 10_000_000e6);
        base.mint(holder, 1_000e18);
        registry.mint(holder, AGENT);
        vm.startPrank(holder);
        base.approve(address(cml), type(uint256).max);
        quote.approve(address(cml), type(uint256).max);
        vm.stopPrank();
    }

    function _terms(address priceFeed) internal view returns (CreditMatchedLiquidity.PoolTerms memory) {
        return CreditMatchedLiquidity.PoolTerms({
            base: address(base),
            priceFeed: priceFeed,
            marketStatus: address(session),
            maxPriceAge: 1 days,
            limitBps: 10_000,
            unwindBps: 11_000,
            gapBps: 2_000,
            chargeBps: 100,
            term: 30 days,
            baseDecimals: 18
        });
    }

    function _open() internal returns (uint256 id) {
        vm.prank(holder);
        id = cml.open(pool, 100e18, 25_000e6, LOW, HIGH, AGENT);
    }

    /// @dev The feed's price, in whole quote per whole base, updated now.
    function _oracle(int256 price) internal {
        feed.set(price * 1e8, block.timestamp);
    }

    /// @dev The pool's own price, in whole quote per whole base.
    function _poolPrice(uint256 price) internal {
        pm.setPoolPrice(pool, price * 1e6);
    }

    function _tokenId(uint256 id) internal view returns (uint256) {
        return cml.positionOf(id).tokenId;
    }

    function _owedInToken(uint256 id) internal view returns (uint256 owedBase, uint256 owedQuote) {
        (,,,, owedBase, owedQuote) = pm.positions(_tokenId(id));
    }

    // ------------------------------------------------------------- views

    function test_views() public view {
        assertEq(cml.quoteToken(), address(quote));
        assertEq(cml.identityRegistry(), address(registry));
        assertEq(cml.lenderFallback(), fallbackAddr);
        assertEq(cml.oracleOf(pool), address(feed));
        assertEq(cml.oracleOf(UNLISTED), address(0));
        assertTrue(cml.supportsInterface(type(ICreditMatchedLiquidity).interfaceId));
        assertTrue(cml.supportsInterface(0x01ffc9a7));
        assertFalse(cml.supportsInterface(0xffffffff));
    }

    function test_positionOf_unknownIsZero_andHealthIsZero() public view {
        ICreditMatchedLiquidity.Position memory p = cml.positionOf(7);
        assertEq(p.holder, address(0));
        assertEq(uint8(p.status), uint8(ICreditMatchedLiquidity.Status.None));
        (uint256 value, uint256 owed, bool unwindable) = cml.health(7);
        assertEq(value + owed, 0);
        assertFalse(unwindable);
    }

    function test_listPool_rejectsBadTerms() public {
        CreditMatchedLiquidity.PoolTerms memory t = _terms(address(feed));
        vm.startPrank(lender);
        t.unwindBps = 10_000; // the unwind line must be above what is owed
        vm.expectRevert(CreditMatchedLiquidity.BadTerms.selector);
        cml.listPool(pool, t);
        t = _terms(address(feed));
        t.gapBps = 10_000;
        vm.expectRevert(CreditMatchedLiquidity.BadTerms.selector);
        cml.listPool(pool, t);
        t = _terms(address(feed));
        t.baseDecimals = 6; // token decimals are read, not assumed
        vm.expectRevert(CreditMatchedLiquidity.BadTerms.selector);
        cml.listPool(pool, t);
        t = _terms(address(feed));
        t.base = address(new MockToken(18)); // a pool's base never changes
        vm.expectRevert(CreditMatchedLiquidity.BadTerms.selector);
        cml.listPool(pool, t);
        vm.stopPrank();
        vm.prank(stranger);
        vm.expectRevert(CreditMatchedLiquidity.NotLender.selector);
        cml.listPool(pool, _terms(address(feed)));
    }

    function test_lenderFallback_isSetByTheLenderOnly_neverZero() public {
        vm.prank(stranger);
        vm.expectRevert(CreditMatchedLiquidity.NotLender.selector);
        cml.setLenderFallback(stranger);
        vm.prank(lender);
        vm.expectRevert(CreditMatchedLiquidity.ZeroAddress.selector);
        cml.setLenderFallback(address(0));
        vm.prank(lender);
        cml.setLenderFallback(makeAddr("newFallback"));
        assertEq(cml.lenderFallback(), makeAddr("newFallback"));
    }

    // ------------------------------------------------------------- quote limit

    function test_quoteLimit_isTheOracleValueOfBaseIn_notThePoolPrice() public {
        assertEq(cml.quoteLimit(pool, 100e18), 25_000e6);
        _poolPrice(1_000); // the pool says 1,000
        assertEq(cml.quoteLimit(pool, 100e18), 25_000e6);
        _oracle(200);
        assertEq(cml.quoteLimit(pool, 100e18), 20_000e6);
    }

    function test_quoteLimit_isCappedByWhatTheLenderHas() public view {
        assertEq(cml.quoteLimit(pool, 1_000_000e18), 1_000_000e6);
    }

    function test_quoteLimit_zeroNotRevert_forUnsupportedPoolOrUnusablePrice() public {
        assertEq(cml.quoteLimit(UNLISTED, 100e18), 0);
        vm.warp(block.timestamp + 1 days + 1); // stale
        assertEq(cml.quoteLimit(pool, 100e18), 0);
        _oracle(0);
        assertEq(cml.quoteLimit(pool, 100e18), 0);
        _oracle(-1);
        assertEq(cml.quoteLimit(pool, 100e18), 0);
        feed.set(250e8, block.timestamp + 1); // from the future
        assertEq(cml.quoteLimit(pool, 100e18), 0);
        _oracle(250);
        feed.setDecimals(19);
        assertEq(cml.quoteLimit(pool, 100e18), 0);
    }

    // ------------------------------------------------------------- open

    function test_open_withinQuoteLimit_recordsAndEscrowsThePosition() public {
        uint256 lenderBefore = quote.balanceOf(address(cml));
        vm.expectEmit(true, true, true, true, address(cml));
        emit ICreditMatchedLiquidity.PositionOpened(1, holder, AGENT, pool, 100e18, 25_000e6);
        uint256 id = _open();

        assertEq(id, 1);
        ICreditMatchedLiquidity.Position memory p = cml.positionOf(id);
        assertEq(p.holder, holder);
        assertEq(p.agentId, AGENT);
        assertEq(p.pool, pool);
        assertEq(p.positionManager, address(pm));
        assertEq(p.priceFeed, address(feed));
        assertEq(p.marketStatus, address(session));
        assertEq(p.maxPriceAge, 1 days);
        assertEq(p.unwindBps, 11_000);
        assertEq(p.gapBps, 2_000);
        assertEq(p.openedAt, block.timestamp);
        assertEq(p.dueAt, block.timestamp + 30 days);
        assertEq(p.baseIn, 100e18);
        assertEq(p.quoteLent, 25_000e6);
        assertEq(p.owed, 25_250e6); // 1% charge
        assertEq(uint8(p.status), uint8(ICreditMatchedLiquidity.Status.Open));

        assertEq(pm.ownerOf(p.tokenId), address(cml)); // in escrow
        assertEq(base.balanceOf(holder), 900e18);
        assertEq(quote.balanceOf(address(cml)), lenderBefore - 25_000e6);

        vm.prank(holder); // the holder cannot reach the position through the manager
        vm.expectRevert("not owner");
        pm.collect(p.tokenId, holder, type(uint256).max, type(uint256).max);

        assertEq(_open(), 2); // ids are never reused
    }

    function test_open_aboveQuoteLimit_reverts() public {
        vm.startPrank(holder);
        vm.expectRevert(CreditMatchedLiquidity.AboveQuoteLimit.selector);
        cml.open(pool, 100e18, 25_000e6 + 1, LOW, HIGH, AGENT);
        vm.expectRevert(CreditMatchedLiquidity.AboveQuoteLimit.selector);
        cml.open(UNLISTED, 100e18, 1, LOW, HIGH, AGENT);
        vm.expectRevert(CreditMatchedLiquidity.ZeroAmount.selector);
        cml.open(pool, 0, 1, LOW, HIGH, AGENT);
        vm.expectRevert(CreditMatchedLiquidity.ZeroAmount.selector);
        cml.open(pool, 100e18, 0, LOW, HIGH, AGENT);
        vm.stopPrank();
    }

    function test_open_returnsTheBaseThePositionDidNotTake() public {
        vm.prank(holder);
        uint256 id = cml.open(pool, 200e18, 25_000e6, LOW, HIGH, AGENT); // the quote binds at the pool's price
        assertEq(cml.positionOf(id).baseIn, 100e18);
        assertEq(base.balanceOf(holder), 900e18);
        assertEq(base.balanceOf(address(cml)), 0);
    }

    function test_open_agentIdMustBeTheHolders() public {
        base.mint(stranger, 100e18);
        vm.startPrank(stranger);
        base.approve(address(cml), type(uint256).max);
        vm.expectRevert(CreditMatchedLiquidity.NotAgentOwner.selector);
        cml.open(pool, 100e18, 25_000e6, LOW, HIGH, AGENT);
        uint256 id = cml.open(pool, 100e18, 25_000e6, LOW, HIGH, 0); // no identity
        vm.stopPrank();
        assertEq(cml.positionOf(id).agentId, 0);
    }

    function test_open_revertsWhenUnwindableRightAfter_poolPriceManipulated() public {
        _poolPrice(25_000); // the pool's price pushed up 100x: the mint takes 1 base and 25,000 quote
        vm.prank(holder);
        vm.expectRevert(CreditMatchedLiquidity.UnwindableAtOpen.selector);
        cml.open(pool, 100e18, 25_000e6, LOW, HIGH, AGENT);
    }

    function test_open_revertsOnAStalePrice() public {
        vm.warp(block.timestamp + 1 days + 1);
        vm.prank(holder);
        vm.expectRevert(CreditMatchedLiquidity.AboveQuoteLimit.selector);
        cml.open(pool, 100e18, 1, LOW, HIGH, AGENT);
    }

    function test_positionTerms_doNotChangeWhenThePoolIsRelisted() public {
        uint256 id = _open();
        MockPriceFeed other = new MockPriceFeed(8, 10e8); // a feed that would make the position unwindable
        CreditMatchedLiquidity.PoolTerms memory t = _terms(address(other));
        t.marketStatus = address(new MockMarketSession(0));
        t.unwindBps = 60_000;
        t.gapBps = 0;
        t.maxPriceAge = 1;
        vm.prank(lender);
        cml.listPool(pool, t);
        assertEq(cml.oracleOf(pool), address(other)); // for new positions

        ICreditMatchedLiquidity.Position memory p = cml.positionOf(id);
        assertEq(p.priceFeed, address(feed));
        assertEq(p.marketStatus, address(session));
        assertEq(p.unwindBps, 11_000);
        assertEq(p.gapBps, 2_000);
        assertEq(p.maxPriceAge, 1 days);
        assertEq(p.dueAt, block.timestamp + 30 days);
        (,, bool unwindable) = cml.health(id);
        assertFalse(unwindable);
    }

    // ------------------------------------------------------------- fees

    function test_applyFees_paysTheLenderFirst_andKeepsBaseFeesInThePosition() public {
        uint256 id = _open();
        pm.addFees(_tokenId(id), 2e18, 300e6);
        uint256 lenderBefore = quote.balanceOf(address(cml));

        vm.expectEmit(true, false, false, true, address(cml));
        emit ICreditMatchedLiquidity.FeesApplied(id, 300e6, 0);
        vm.prank(stranger); // anyone
        (uint256 toLender, uint256 toHolder) = cml.applyFees(id);

        assertEq(toLender, 300e6);
        assertEq(toHolder, 0);
        assertEq(cml.positionOf(id).owed, 24_950e6);
        assertEq(quote.balanceOf(address(cml)), lenderBefore + 300e6);
        assertEq(quote.balanceOf(holder), 0);
        (uint256 owedBase, uint256 owedQuote) = _owedInToken(id);
        assertEq(owedBase, 2e18); // base fees stay with the position
        assertEq(owedQuote, 0);
        assertEq(base.balanceOf(holder), 900e18);
        assertEq(base.balanceOf(fallbackAddr), 0);
    }

    function test_applyFees_paysTheHolderOnlyWhatExceedsOwed() public {
        uint256 id = _open();
        pm.addFees(_tokenId(id), 0, 25_200e6);
        cml.applyFees(id);
        assertEq(cml.positionOf(id).owed, 50e6);

        pm.addFees(_tokenId(id), 0, 300e6);
        (uint256 toLender, uint256 toHolder) = cml.applyFees(id);
        assertEq(toLender, 50e6);
        assertEq(toHolder, 250e6);
        assertEq(quote.balanceOf(holder), 250e6);
        assertEq(cml.positionOf(id).owed, 0);

        pm.addFees(_tokenId(id), 0, 40e6);
        (toLender, toHolder) = cml.applyFees(id);
        assertEq(toLender, 0);
        assertEq(toHolder, 40e6);
    }

    function testFuzz_applyFees_lenderFirst_owedNeverRises(uint256 fee1, uint256 fee2, uint32 wait) public {
        fee1 = bound(fee1, 0, 100_000e6); // within the mock pool's reserves
        fee2 = bound(fee2, 0, 100_000e6);
        uint256 id = _open();
        uint256 owed0 = cml.positionOf(id).owed;
        vm.warp(block.timestamp + wait);
        assertEq(cml.positionOf(id).owed, owed0); // time alone never raises it

        pm.addFees(_tokenId(id), 0, fee1);
        (uint256 l1, uint256 h1) = cml.applyFees(id);
        pm.addFees(_tokenId(id), 0, fee2);
        (uint256 l2, uint256 h2) = cml.applyFees(id);

        uint256 fees = fee1 + fee2;
        uint256 toLender = fees < owed0 ? fees : owed0;
        assertEq(l1 + l2, toLender);
        assertEq(h1 + h2, fees - toLender);
        assertEq(cml.positionOf(id).owed, owed0 - toLender);
        if (h1 > 0) assertEq(l2, 0); // the holder is paid only once nothing is owed
    }

    function test_applyFees_revertsUnlessOpen() public {
        vm.expectRevert(CreditMatchedLiquidity.NotOpen.selector);
        cml.applyFees(1);
    }

    // ------------------------------------------------------------- close

    function test_close_byTheHolderOnly() public {
        uint256 id = _open();
        vm.prank(stranger);
        vm.expectRevert(CreditMatchedLiquidity.NotHolder.selector);
        cml.close(id);
        vm.prank(lender);
        vm.expectRevert(CreditMatchedLiquidity.NotHolder.selector);
        cml.close(id);
    }

    function test_close_repaysOwed_andReturnsThePositionToken() public {
        uint256 id = _open();
        pm.addFees(_tokenId(id), 2e18, 0);
        quote.mint(holder, 25_250e6);
        uint256 lenderBefore = quote.balanceOf(address(cml));

        vm.expectEmit(true, false, false, true, address(cml));
        emit ICreditMatchedLiquidity.PositionClosed(id, 25_250e6);
        vm.prank(holder);
        cml.close(id);

        assertEq(quote.balanceOf(address(cml)), lenderBefore + 25_250e6);
        assertEq(quote.balanceOf(holder), 0);
        assertEq(pm.ownerOf(_tokenId(id)), holder); // liquidity and base fees with it
        ICreditMatchedLiquidity.Position memory p = cml.positionOf(id);
        assertEq(p.owed, 0);
        assertEq(uint8(p.status), uint8(ICreditMatchedLiquidity.Status.Closed));
        (uint256 value, uint256 owed, bool unwindable) = cml.health(id);
        assertEq(value + owed, 0);
        assertFalse(unwindable);

        vm.prank(holder);
        vm.expectRevert(CreditMatchedLiquidity.NotOpen.selector);
        cml.close(id);
        vm.expectRevert(CreditMatchedLiquidity.NotOpen.selector);
        cml.unwind(id);
    }

    function test_close_needsNoPrice_andNoBaseTransfer() public {
        uint256 id = _open();
        quote.mint(holder, 25_250e6);
        feed.set(0, 0); // no usable price
        base.setBlocked(address(cml), true); // the registry blocks the escrow and the holder
        base.setBlocked(holder, true);
        vm.prank(holder);
        cml.close(id);
        assertEq(pm.ownerOf(_tokenId(id)), holder);
    }

    // ------------------------------------------------------------- health

    function test_health_valuesThePositionAtTheOraclePrice() public {
        uint256 id = _open();
        (uint256 value, uint256 owed, bool unwindable) = cml.health(id);
        assertApproxEqRel(value, 50_000e6, TOL);
        assertEq(owed, 25_250e6);
        assertFalse(unwindable);

        _oracle(80);
        (value,, unwindable) = cml.health(id);
        assertApproxEqRel(value, 28_284.27e6, TOL); // 50,000 * sqrt(80 / 250)
        assertFalse(unwindable);

        _oracle(70);
        (value,, unwindable) = cml.health(id);
        assertApproxEqRel(value, 26_457.51e6, TOL); // below 1.1 * 25,250
        assertTrue(unwindable);
    }

    function test_health_ignoresAManipulatedPoolPrice() public {
        uint256 id = _open();
        (uint256 value0,,) = cml.health(id);
        _poolPrice(10); // a flash loan crashes the pool's price
        (uint256 value1,, bool unwindable1) = cml.health(id);
        _poolPrice(100_000);
        (uint256 value2,, bool unwindable2) = cml.health(id);
        assertEq(value1, value0);
        assertEq(value2, value0);
        assertFalse(unwindable1 || unwindable2);

        _poolPrice(10);
        vm.expectRevert(CreditMatchedLiquidity.NotUnwindable.selector);
        cml.unwind(id);
    }

    function test_unusablePrice_healthAndUnwindRevert() public {
        uint256 id = _open();
        int256[3] memory answers = [int256(0), int256(-1), int256(250e8)];
        uint256[3] memory times = [block.timestamp, block.timestamp, block.timestamp + 1]; // zero, negative, future
        for (uint256 i; i < 3; ++i) {
            feed.set(answers[i], times[i]);
            vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
            cml.health(id);
            vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
            cml.unwind(id);
        }

        feed.set(70e8, block.timestamp); // a price that would allow an unwind...
        vm.warp(block.timestamp + 1 days + 1); // ...once stale is not used
        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.health(id);
        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.unwind(id);

        _oracle(70);
        feed.setDecimals(19);
        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.health(id);
        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.unwind(id);
    }

    function test_decimals_areReadFromTheFeed() public {
        uint256 id = _open();
        feed.setDecimals(18);
        feed.set(250e18, block.timestamp); // the same price with 18 decimals
        (uint256 value,,) = cml.health(id);
        assertApproxEqRel(value, 50_000e6, TOL);
        assertEq(cml.quoteLimit(pool, 100e18), 25_000e6);
    }

    // ------------------------------------------------------------- unwind

    function test_unwind_refusedWhileHealthy() public {
        uint256 id = _open();
        _oracle(80);
        vm.expectRevert(CreditMatchedLiquidity.NotUnwindable.selector);
        cml.unwind(id);
    }

    function test_unwind_whenTheOracleSaysSo_paysTheLenderFirst() public {
        uint256 id = _open();
        _oracle(70);
        _poolPrice(70);
        uint256 lenderBefore = quote.balanceOf(address(cml));

        vm.expectEmit(true, false, false, true, address(cml));
        emit ICreditMatchedLiquidity.PositionUnwound(id, 25_250e6, 0);
        vm.prank(stranger); // anyone
        cml.unwind(id);

        // Withdrawn at 70: 13,228.76 quote and 188.982 base. The lender takes the quote, then base worth the other
        // 12,021.24 at 70 (171.732), at its fallback address; the holder keeps 17.250 base in the position token.
        assertApproxEqRel(quote.balanceOf(address(cml)) - lenderBefore, 13_228.76e6, TOL);
        assertApproxEqRel(base.balanceOf(fallbackAddr), 171.732e18, TOL);
        assertEq(pm.ownerOf(_tokenId(id)), holder);
        (uint256 owedBase, uint256 owedQuote) = _owedInToken(id);
        assertApproxEqRel(owedBase, 17.25e18, TOL);
        assertEq(owedQuote, 0);
        assertEq(base.balanceOf(address(cml)), 0);

        ICreditMatchedLiquidity.Position memory p = cml.positionOf(id);
        assertEq(p.owed, 0);
        assertEq(uint8(p.status), uint8(ICreditMatchedLiquidity.Status.Unwound));
        vm.expectRevert(CreditMatchedLiquidity.NotOpen.selector);
        cml.unwind(id);
    }

    function test_unwind_followsTheOracle_notThePool() public {
        uint256 id = _open();
        _oracle(70); // the pool still says 250
        uint256 lenderBefore = quote.balanceOf(address(cml));
        cml.unwind(id);
        // Withdrawn at the pool's 250: 100 base and 25,000 quote. The lender takes the quote and base worth the other
        // 250 at the oracle's 70 (3.571).
        assertApproxEqRel(quote.balanceOf(address(cml)) - lenderBefore, 25_000e6, TOL);
        assertApproxEqRel(base.balanceOf(fallbackAddr), 3.5714e18, TOL);
        (uint256 owedBase,) = _owedInToken(id);
        assertApproxEqRel(owedBase, 96.4286e18, TOL);
    }

    function test_unwind_settlesUnappliedFeesLenderFirst() public {
        uint256 id = _open();
        pm.addFees(_tokenId(id), 2e18, 1_000e6);
        _oracle(70);
        _poolPrice(70);
        uint256 lenderBefore = quote.balanceOf(address(cml));
        cml.unwind(id);
        assertApproxEqRel(quote.balanceOf(address(cml)) - lenderBefore, 14_228.76e6, TOL);
        assertApproxEqRel(base.balanceOf(fallbackAddr), 157.446e18, TOL); // 11,021.24 / 70
        (uint256 owedBase,) = _owedInToken(id);
        assertApproxEqRel(owedBase, 33.536e18, TOL); // 188.982 + 2 - 157.446
    }

    function test_unwind_reportsTheShortfall() public {
        uint256 id = _open();
        _oracle(20);
        _poolPrice(20);
        vm.recordLogs();
        cml.unwind(id);
        (uint256 recovered, uint256 shortfall) = abi.decode(vm.getRecordedLogs()[0].data, (uint256, uint256));
        // Worth 50,000 * sqrt(20 / 250) = 14,142.14: 7,071.07 quote and 353.553 base, all to the lender.
        assertApproxEqRel(recovered, 14_142.14e6, TOL);
        assertEq(recovered + shortfall, 25_250e6);
        assertApproxEqRel(base.balanceOf(fallbackAddr), 353.553e18, TOL);
        (uint256 owedBase, uint256 owedQuote) = _owedInToken(id);
        assertEq(owedBase + owedQuote, 0);
    }

    function test_unwind_pastDue_evenWhenHealthy() public {
        uint256 id = _open();
        uint256 dueAt = cml.positionOf(id).dueAt;
        vm.warp(dueAt - 1);
        _oracle(250);
        vm.expectRevert(CreditMatchedLiquidity.NotUnwindable.selector);
        cml.unwind(id);

        vm.warp(dueAt);
        _oracle(250);
        (,, bool unwindable) = cml.health(id);
        assertTrue(unwindable);
        cml.unwind(id);
        assertApproxEqRel(base.balanceOf(fallbackAddr), 1e18, TOL); // the 250 the quote did not cover
        (uint256 owedBase,) = _owedInToken(id);
        assertApproxEqRel(owedBase, 99e18, TOL);
    }

    function test_unwind_escrowAndHolderBlocked_paysTheFallback() public {
        uint256 id = _open();
        base.setBlocked(address(cml), true); // the stock token's registry blocks the escrow and the holder
        base.setBlocked(holder, true);
        _oracle(70);
        _poolPrice(70);
        cml.unwind(id);

        assertApproxEqRel(base.balanceOf(fallbackAddr), 171.732e18, TOL);
        assertEq(pm.ownerOf(_tokenId(id)), holder); // the holder's base waits in the position token
        (uint256 owedBase,) = _owedInToken(id);
        assertApproxEqRel(owedBase, 17.25e18, TOL);
    }

    function test_unwind_baseStuckInThePool_givesThePositionTokenToTheFallback() public {
        uint256 id = _open();
        base.setBlocked(address(pm), true); // no base can leave the pool
        _oracle(70);
        _poolPrice(70);
        uint256 lenderBefore = quote.balanceOf(address(cml));
        vm.recordLogs();
        cml.unwind(id);

        (uint256 recovered, uint256 shortfall) = abi.decode(vm.getRecordedLogs()[0].data, (uint256, uint256));
        uint256 quoteIn = quote.balanceOf(address(cml)) - lenderBefore;
        assertApproxEqRel(quoteIn, 13_228.76e6, TOL);
        assertEq(recovered, quoteIn);
        assertEq(shortfall, 25_250e6 - quoteIn);
        assertEq(pm.ownerOf(_tokenId(id)), fallbackAddr); // the lender holds the claim on the base

        base.setBlocked(address(pm), false); // once the registry lets it go, the base can be collected
        uint256 tokenId = _tokenId(id);
        vm.prank(fallbackAddr);
        pm.collect(tokenId, fallbackAddr, type(uint256).max, 0);
        assertApproxEqRel(base.balanceOf(fallbackAddr), 188.982e18, TOL);
    }

    // ------------------------------------------------------------- market sessions and gaps

    function test_marketClosed_noPriceIsUsed_evenPastDue() public {
        uint256 id = _open();
        session.set(false, uint64(block.timestamp)); // Friday's close
        vm.warp(block.timestamp + 1 hours);
        _oracle(70); // the feed refreshes over the weekend with a price that would allow an unwind

        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.health(id);
        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.unwind(id);
        assertEq(cml.quoteLimit(pool, 100e18), 0);
        vm.prank(holder);
        vm.expectRevert(CreditMatchedLiquidity.AboveQuoteLimit.selector);
        cml.open(pool, 100e18, 1, LOW, HIGH, AGENT);

        vm.warp(cml.positionOf(id).dueAt); // due while the market is closed
        _oracle(70);
        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.unwind(id);
    }

    function test_marketClosed_feesAndCloseStillWork() public {
        uint256 id = _open();
        session.set(false, uint64(block.timestamp));
        feed.set(0, 0);
        pm.addFees(_tokenId(id), 0, 300e6);
        (uint256 toLender,) = cml.applyFees(id); // no price needed
        assertEq(toLender, 300e6);

        quote.mint(holder, 24_950e6);
        vm.prank(holder);
        cml.close(id); // what is owed is in quote: no price needed either
        assertEq(pm.ownerOf(_tokenId(id)), holder);
    }

    function test_marketReopened_aPriceSetBeforeTheOpenIsNotUsed() public {
        uint256 id = _open();
        session.set(false, uint64(block.timestamp)); // Friday's close
        uint64 mondayOpen = uint64(block.timestamp) + 2.5 days;
        vm.warp(mondayOpen - 1 minutes);
        _oracle(250); // Friday's price, refreshed a minute before the open: fresh by age alone
        vm.warp(mondayOpen);
        session.set(true, mondayOpen);

        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.health(id);
        assertEq(cml.quoteLimit(pool, 100e18), 0);

        vm.warp(mondayOpen + 1 minutes);
        _oracle(70); // the first price of the session: the stock gapped down
        _poolPrice(70);
        (,, bool unwindable) = cml.health(id);
        assertTrue(unwindable);
        cml.unwind(id);
        assertApproxEqRel(base.balanceOf(fallbackAddr), 171.732e18, TOL); // settled at the gap price
    }

    function test_marketSessionThatCannotAnswer_countsAsClosed() public {
        uint256 id = _open();
        session.setDown(true);
        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
        cml.health(id);
        assertEq(cml.quoteLimit(pool, 100e18), 0);
    }

    function test_continuouslyTradedBase_needsNoSession() public {
        address ethPool = makeAddr("ethPool");
        pm.setPool(ethPool, address(base), address(quote), 250e6);
        CreditMatchedLiquidity.PoolTerms memory t = _terms(address(feed));
        t.marketStatus = address(0);
        vm.prank(lender);
        cml.listPool(ethPool, t);
        session.set(false, 0); // the stock market's state does not matter here
        assertEq(cml.quoteLimit(ethPool, 100e18), 25_000e6);
    }

    function test_open_mustSurviveTheGapAllowance() public {
        CreditMatchedLiquidity.PoolTerms memory t = _terms(address(feed));
        t.unwindBps = 18_000; // 1.8 * 25,250 = 45,450: worth 50,000 now, 44,721 after a 20% gap
        vm.prank(lender);
        cml.listPool(pool, t);
        vm.prank(holder);
        vm.expectRevert(CreditMatchedLiquidity.UnwindableAtOpen.selector);
        cml.open(pool, 100e18, 25_000e6, LOW, HIGH, AGENT);

        t.gapBps = 0;
        vm.prank(lender);
        cml.listPool(pool, t);
        uint256 id = _open();
        assertEq(cml.positionOf(id).gapBps, 0);
    }

    // ------------------------------------------------------------- quote tokens that do not transfer exact amounts

    function test_feeChargingQuote_closeRevertsUnlessOwedArrives() public {
        uint256 id = _open();
        quote.setFeeBps(100); // 1% of every transfer is burned
        quote.mint(holder, 25_250e6);
        vm.prank(holder);
        vm.expectRevert(abi.encodeWithSelector(CreditMatchedLiquidity.ShortPayment.selector, 24_997.5e6, 25_250e6));
        cml.close(id);
        assertEq(pm.ownerOf(_tokenId(id)), address(cml)); // the position stays in escrow
        assertEq(cml.positionOf(id).owed, 25_250e6);
    }

    function test_feeChargingQuote_applyFeesCountsWhatArrived() public {
        uint256 id = _open();
        quote.setFeeBps(100);
        pm.addFees(_tokenId(id), 0, 300e6);
        uint256 lenderBefore = quote.balanceOf(address(cml));
        (uint256 toLender, uint256 toHolder) = cml.applyFees(id);
        assertEq(toLender, 297e6); // 300 collected, 297 arrived
        assertEq(quote.balanceOf(address(cml)) - lenderBefore, 297e6);
        assertEq(toHolder, 0);
        assertEq(cml.positionOf(id).owed, 25_250e6 - 297e6);

        quote.setFeeBps(0);
        pm.addFees(_tokenId(id), 0, 24_953e6); // pays off the rest
        cml.applyFees(id);
        assertEq(cml.positionOf(id).owed, 0);
        quote.setFeeBps(100);
        pm.addFees(_tokenId(id), 0, 300e6);
        (toLender, toHolder) = cml.applyFees(id);
        assertEq(toLender, 0);
        assertEq(toHolder, 297e6);
        assertEq(quote.balanceOf(holder), 297e6);
    }

    function test_feeChargingQuote_unwindCountsWhatArrived() public {
        uint256 id = _open();
        _oracle(70);
        _poolPrice(70);
        quote.setFeeBps(100);
        uint256 lenderBefore = quote.balanceOf(address(cml));
        vm.recordLogs();
        cml.unwind(id);
        (uint256 recovered, uint256 shortfall) = abi.decode(vm.getRecordedLogs()[0].data, (uint256, uint256));

        uint256 quoteArrived = quote.balanceOf(address(cml)) - lenderBefore;
        assertApproxEqRel(quoteArrived, 13_096.47e6, TOL); // 99% of the 13,228.76 collected
        // The lender's base covers what is owed minus the quote that actually arrived, at 70, rounded up.
        assertEq(base.balanceOf(fallbackAddr), MulDiv.mulDivUp(25_250e6 - quoteArrived, 1e18, 70e6));
        assertEq(recovered, 25_250e6);
        assertEq(shortfall, 0);
    }

    // ------------------------------------------------------------- rounding

    function test_unwind_roundsTheLendersBaseUp_exactly() public {
        // At 256 the mock's square roots are exact: the position is 100 base and 25,600 quote, L = 1.6e15.
        _oracle(256);
        _poolPrice(256);
        vm.prank(holder);
        uint256 id = cml.open(pool, 100e18, 25_600e6, LOW, HIGH, AGENT);
        assertEq(cml.positionOf(id).owed, 25_856e6);

        vm.warp(cml.positionOf(id).dueAt);
        _oracle(255); // due, settled at 255 while the pool still says 256
        vm.recordLogs();
        cml.unwind(id);
        (uint256 recovered, uint256 shortfall) = abi.decode(vm.getRecordedLogs()[0].data, (uint256, uint256));

        // Withdrawn exactly: 100e18 base and 25,600e6 quote. The lender takes the quote, then base worth the other 256
        // quote at 255: 256e6 * 1e18 / 255e6 = 1,003,921,568,627,450,980.39, rounded up.
        assertEq(quote.balanceOf(address(cml)), 1_000_000e6);
        assertEq(base.balanceOf(fallbackAddr), 1_003_921_568_627_450_981);
        (uint256 owedBase, uint256 owedQuote) = _owedInToken(id);
        assertEq(owedBase, 100e18 - 1_003_921_568_627_450_981);
        assertEq(owedQuote, 0);
        assertEq(recovered, 25_856e6);
        assertEq(shortfall, 0);
    }

    // ------------------------------------------------------------- decimals and price bounds

    struct Kit {
        MockToken base;
        MockToken quote;
        MockPriceFeed feed;
        MockPositionManager pm;
        CreditMatchedLiquidity cml;
        address pool;
    }

    /// @dev A fresh lender for a base of `bd` decimals, a quote of `qd` and a feed of `fd`, priced 250, with a base
    ///      traded continuously. The holder has 1,000 base.
    function _kit(uint8 bd, uint8 qd, uint8 fd) internal returns (Kit memory k) {
        k.base = new MockToken(bd);
        k.quote = new MockToken(qd);
        k.feed = new MockPriceFeed(fd, int256(250) * int256(10) ** fd);
        k.pm = new MockPositionManager();
        k.pool = makeAddr(string(abi.encode(bd, qd, fd)));
        k.pm.setPool(k.pool, address(k.base), address(k.quote), _px(250, bd, qd));
        k.cml = new CreditMatchedLiquidity(address(k.quote), address(k.pm), address(registry), lender, fallbackAddr);
        CreditMatchedLiquidity.PoolTerms memory t = _terms(address(k.feed));
        t.base = address(k.base);
        t.marketStatus = address(0);
        t.baseDecimals = bd;
        vm.prank(lender);
        k.cml.listPool(k.pool, t);
        k.quote.mint(address(k.cml), 1_000_000 * 10 ** uint256(qd));
        k.base.mint(address(k.pm), 1_000_000 * 10 ** uint256(bd));
        k.quote.mint(address(k.pm), 100_000_000 * 10 ** uint256(qd));
        k.base.mint(holder, 1_000 * 10 ** uint256(bd));
        vm.startPrank(holder);
        k.base.approve(address(k.cml), type(uint256).max);
        k.quote.approve(address(k.cml), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev A price in whole quote per whole base, as quote units per 1e18 base units.
    function _px(uint256 price, uint8 bd, uint8 qd) internal pure returns (uint256) {
        return price * 10 ** uint256(qd) * 1e18 / 10 ** uint256(bd);
    }

    function _kitOpen(Kit memory k, uint8 bd, uint8 qd) internal returns (uint256 id) {
        vm.prank(holder);
        id = k.cml.open(k.pool, 100 * 10 ** uint256(bd), 25_000 * 10 ** uint256(qd), LOW, HIGH, 0);
    }

    function test_decimals_baseAndQuoteCombinations() public {
        uint8[3] memory bds = [6, 8, 18];
        uint8[2] memory qds = [6, 18];
        uint8[2] memory fds = [8, 18];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 2; ++j) {
                for (uint256 f; f < 2; ++f) {
                    (uint8 bd, uint8 qd, uint8 fd) = (bds[i], qds[j], fds[f]);
                    uint256 b = 10 ** uint256(bd);
                    uint256 q = 10 ** uint256(qd);
                    Kit memory k = _kit(bd, qd, fd);
                    assertEq(k.cml.quoteLimit(k.pool, 100 * b), 25_000 * q, "quoteLimit");
                    uint256 id = _kitOpen(k, bd, qd);
                    assertEq(k.cml.positionOf(id).owed, 25_250 * q, "owed");
                    (uint256 value,,) = k.cml.health(id);
                    assertApproxEqRel(value, 50_000 * q, TOL, "value");

                    k.feed.set(int256(70) * int256(10) ** fd, block.timestamp);
                    k.pm.setPoolPrice(k.pool, _px(70, bd, qd));
                    k.cml.unwind(id);
                    assertApproxEqRel(k.base.balanceOf(fallbackAddr), 171_732 * b / 1000, TOL, "lender's base");
                }
            }
        }
    }

    function test_extremeAnswer_neverOverflows() public {
        uint8[3] memory bds = [6, 8, 18];
        uint8[2] memory qds = [6, 18];
        uint8[3] memory fds = [0, 8, 18];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 2; ++j) {
                for (uint256 f; f < 3; ++f) {
                    (uint8 bd, uint8 qd, uint8 fd) = (bds[i], qds[j], fds[f]);
                    Kit memory k = _kit(bd, qd, fd);
                    uint256 id = _kitOpen(k, bd, qd);
                    // 1,000 base owed to the position token, as a range below the price would hold.
                    k.pm.addFees(k.cml.positionOf(id).tokenId, 1_000 * 10 ** uint256(bd), 0);
                    k.feed.set(type(int128).max, block.timestamp);

                    // Either an answer or a clean refusal, never an arithmetic panic.
                    assertLe(k.cml.quoteLimit(k.pool, 1_000 * 10 ** uint256(bd)), 1_000_000 * 10 ** uint256(qd));
                    try k.cml.health(id) returns (uint256 value, uint256, bool) {
                        assertGt(value, 0);
                    } catch (bytes memory err) {
                        assertEq(err, abi.encodeWithSelector(CreditMatchedLiquidity.PriceUnusable.selector), "health");
                    }
                    vm.warp(k.cml.positionOf(id).dueAt);
                    k.feed.set(type(int128).max, block.timestamp);
                    try k.cml.unwind(id) {
                        assertEq(uint8(k.cml.positionOf(id).status), uint8(ICreditMatchedLiquidity.Status.Unwound));
                    } catch (bytes memory err) {
                        assertEq(err, abi.encodeWithSelector(CreditMatchedLiquidity.PriceUnusable.selector), "unwind");
                    }
                }
            }
        }
    }

    function test_priceBounds_largestAcceptedAnswer_healthAndUnwindAnswer() public {
        uint8[3] memory bds = [6, 8, 18];
        uint8[2] memory qds = [6, 18];
        uint8[3] memory fds = [0, 8, 18];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 2; ++j) {
                for (uint256 f; f < 3; ++f) {
                    (uint8 bd, uint8 qd, uint8 fd) = (bds[i], qds[j], fds[f]);
                    Kit memory k = _kit(bd, qd, fd);
                    uint256 id = _kitOpen(k, bd, qd);
                    // 2**100 base owed to the position token: amounts up to 2**128 are what the bounds are sized for.
                    k.pm.addFees(k.cml.positionOf(id).tokenId, uint256(1) << 100, 0);

                    // The largest answer whose price, quote units per 1e18 base units, is at most MAX_PRICE.
                    uint256 up = 10 ** (18 + uint256(qd));
                    uint256 down = 10 ** (uint256(fd) + uint256(bd));
                    uint256 top = cml.MAX_PRICE() + 1;
                    uint256 largest = MulDiv.mulDiv(top, down, up);
                    if (mulmod(top, down, up) == 0) largest -= 1;
                    if (largest > uint256(uint128(type(int128).max))) largest = uint256(uint128(type(int128).max));

                    // forge-lint: disable-next-line(unsafe-typecast)
                    k.feed.set(int256(largest), block.timestamp); // largest <= type(int128).max
                    (uint256 value,, bool unwindable) = k.cml.health(id);
                    assertGt(value, 0);
                    assertFalse(unwindable);
                    if (largest < uint256(uint128(type(int128).max))) {
                        // forge-lint: disable-next-line(unsafe-typecast)
                        k.feed.set(int256(largest + 1), block.timestamp); // one above the bound is not used
                        vm.expectRevert(CreditMatchedLiquidity.PriceUnusable.selector);
                        k.cml.health(id);
                        assertEq(k.cml.quoteLimit(k.pool, 100 * 10 ** uint256(bd)), 0);
                    }

                    vm.warp(k.cml.positionOf(id).dueAt);
                    // forge-lint: disable-next-line(unsafe-typecast)
                    k.feed.set(int256(largest), block.timestamp);
                    vm.recordLogs();
                    k.cml.unwind(id);
                    (uint256 recovered, uint256 shortfall) =
                        abi.decode(vm.getRecordedLogs()[0].data, (uint256, uint256));
                    assertEq(recovered + shortfall, 25_250 * 10 ** uint256(qd));
                    assertEq(shortfall, 0);
                }
            }
        }
    }

    function test_listPool_rejectsAPriceOutOfBounds() public {
        MockToken shares = new MockToken(6);
        MockPriceFeed feed0 = new MockPriceFeed(0, type(int128).max); // 1.7e56 quote units per 1e18 base units
        CreditMatchedLiquidity.PoolTerms memory t = _terms(address(feed0));
        t.base = address(shares);
        t.baseDecimals = 6;
        address sharesPool = makeAddr("sharesPool");
        vm.startPrank(lender);
        vm.expectRevert(CreditMatchedLiquidity.BadTerms.selector);
        cml.listPool(sharesPool, t);
        feed0.set(0, block.timestamp);
        vm.expectRevert(CreditMatchedLiquidity.BadTerms.selector);
        cml.listPool(sharesPool, t);
        feed0.set(250, block.timestamp); // 2.5e26: within bounds
        cml.listPool(sharesPool, t);
        vm.stopPrank();
        assertEq(cml.oracleOf(sharesPool), address(feed0));
    }

    // ------------------------------------------------------------- full-precision arithmetic

    function testFuzz_mulDiv_matchesExactArithmetic(uint256 a, uint256 b, uint256 d) public pure {
        a = bound(a, 0, type(uint128).max);
        b = bound(b, 0, type(uint128).max);
        d = bound(d, 1, type(uint256).max);
        assertEq(MulDiv.mulDiv(a, b, d), a * b / d);
        assertEq(MulDiv.mulDivUp(a, b, d), a * b / d + (mulmod(a, b, d) > 0 ? 1 : 0));
    }

    function testFuzz_mulDiv_fullPrecisionBeyond256Bits(uint256 a, uint256 b) public pure {
        b = bound(b, 1, type(uint256).max);
        assertEq(MulDiv.mulDiv(a, b, b), a); // a * b can need 512 bits
        assertEq(MulDiv.mulDivUp(a, b, b), a);
    }

    function test_mulDiv_revertsWhenTheResultDoesNotFit() public {
        MulDivCaller c = new MulDivCaller();
        vm.expectRevert(MulDiv.MulDivOverflow.selector);
        c.mulDiv(type(uint256).max, 2, 1);
        vm.expectRevert(MulDiv.MulDivOverflow.selector);
        c.mulDiv(1, 1, 0);
        assertEq(c.mulDiv(type(uint256).max, type(uint256).max, type(uint256).max), type(uint256).max);
    }
}

/// @notice Calls the library from outside, so that its reverts can be expected. Not audited: never deploy anything here
///         without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
contract MulDivCaller {
    function mulDiv(uint256 a, uint256 b, uint256 d) external pure returns (uint256) {
        return MulDiv.mulDiv(a, b, d);
    }
}
