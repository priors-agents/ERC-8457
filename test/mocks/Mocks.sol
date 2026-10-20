// SPDX-License-Identifier: CC0-1.0
pragma solidity ^0.8.20;

/// @notice An ERC-20 with a public mint and settable decimals. With `setBlocked` it acts as a token with a transfer
///         registry: any transfer from or to a blocked address reverts, as tokenized stocks can do. With `setFeeBps` it
///         charges a fee on every transfer, so the recipient gets less than the amount sent.
///         Not audited: a test double, never deploy it, and never deploy anything here without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
contract MockToken {
    uint8 public immutable decimals;
    uint256 public feeBps;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    mapping(address => bool) public blocked;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function setBlocked(address account, bool isBlocked) external {
        blocked[account] = isBlocked;
    }

    function setFeeBps(uint256 feeBps_) external {
        feeBps = feeBps_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        require(!blocked[from] && !blocked[to], "blocked by registry");
        balanceOf[from] -= amount;
        balanceOf[to] += amount - amount * feeBps / 10_000; // the fee is burned
    }
}

/// @notice A price feed with the aggregator interface; tests set the answer, its time and the decimals.
///         Not audited: a test double, never deploy it, and never deploy anything here without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
contract MockPriceFeed {
    uint8 public decimals;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setDecimals(uint8 decimals_) external {
        decimals = decimals_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}

/// @notice The session of a stock's reference market: tests open and close it, as a weekend or a halt would, and can
///         make it fail to answer.
///         Not audited: a test double, never deploy it, and never deploy anything here without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
contract MockMarketSession {
    bool public isOpen = true;
    uint64 public openedAt;
    bool public down;

    constructor(uint64 openedAt_) {
        openedAt = openedAt_;
    }

    function set(bool open_, uint64 openedAt_) external {
        isOpen = open_;
        openedAt = openedAt_;
    }

    function setDown(bool down_) external {
        down = down_;
    }

    function marketSession() external view returns (bool, uint64) {
        require(!down, "down");
        return (isOpen, openedAt);
    }
}

/// @notice A v3-style position manager that is also its pools' vault. Each pool pairs a base and a quote token at a
///         price tests set (quote units per 1e18 base units), standing for the pool's own price. Positions are ERC-721
///         tokens. To keep the math short every position is valued as full-range constant-product liquidity: ticks are
///         checked and recorded, not used. Withdrawn amounts and fees stay owed to the token until collected, as in v3.
///         Tests fund the manager with reserves so it can pay out at any price.
///         Not audited: a test double, never deploy it, and never deploy anything here without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
contract MockPositionManager {
    struct Pool {
        address base;
        address quote;
        uint256 price;
    }

    struct Pos {
        address pool;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint256 owedBase;
        uint256 owedQuote;
    }

    mapping(address => Pool) public pools;
    mapping(uint256 => Pos) private _pos;
    mapping(uint256 => address) public ownerOf;
    uint256 public nextId = 1;

    function setPool(address pool, address base, address quote, uint256 price) external {
        pools[pool] = Pool(base, quote, price);
    }

    /// @notice Moves the pool's own price, as a large trade or a flash loan would.
    function setPoolPrice(address pool, uint256 price) external {
        pools[pool].price = price;
    }

    /// @notice Credits fees to a position, as trades through its range would.
    function addFees(uint256 tokenId, uint256 base, uint256 quote) external {
        _pos[tokenId].owedBase += base;
        _pos[tokenId].owedQuote += quote;
    }

    function mint(
        address pool,
        int24 tickLower,
        int24 tickUpper,
        uint256 baseDesired,
        uint256 quoteDesired,
        address recipient
    ) external returns (uint256 tokenId, uint128 liquidity, uint256 baseUsed, uint256 quoteUsed) {
        require(tickLower < tickUpper, "ticks");
        Pool memory pl = pools[pool];
        require(pl.price > 0, "no pool");
        quoteUsed = baseDesired * pl.price / 1e18;
        baseUsed = baseDesired;
        if (quoteUsed > quoteDesired) {
            quoteUsed = quoteDesired;
            baseUsed = quoteDesired * 1e18 / pl.price;
        }
        liquidity = uint128(_sqrt(baseUsed * quoteUsed));
        require(liquidity > 0, "zero liquidity");
        require(MockToken(pl.base).transferFrom(msg.sender, address(this), baseUsed), "base");
        require(MockToken(pl.quote).transferFrom(msg.sender, address(this), quoteUsed), "quote");
        tokenId = nextId++;
        _pos[tokenId] = Pos(pool, tickLower, tickUpper, liquidity, 0, 0);
        ownerOf[tokenId] = recipient;
    }

    /// @notice Removes liquidity at the pool's own price; the amounts become owed to the token.
    function decreaseLiquidity(uint256 tokenId, uint128 liquidity) external returns (uint256 base, uint256 quote) {
        require(ownerOf[tokenId] == msg.sender, "not owner");
        Pos storage p = _pos[tokenId];
        require(liquidity > 0 && liquidity <= p.liquidity, "liquidity");
        (base, quote) = _amounts(liquidity, pools[p.pool].price);
        p.liquidity -= liquidity;
        p.owedBase += base;
        p.owedQuote += quote;
    }

    function collect(uint256 tokenId, address recipient, uint256 baseMax, uint256 quoteMax)
        external
        returns (uint256 base, uint256 quote)
    {
        require(ownerOf[tokenId] == msg.sender, "not owner");
        Pos storage p = _pos[tokenId];
        Pool memory pl = pools[p.pool];
        base = p.owedBase < baseMax ? p.owedBase : baseMax;
        quote = p.owedQuote < quoteMax ? p.owedQuote : quoteMax;
        p.owedBase -= base;
        p.owedQuote -= quote;
        if (base > 0) require(MockToken(pl.base).transfer(recipient, base), "base");
        if (quote > 0) require(MockToken(pl.quote).transfer(recipient, quote), "quote");
    }

    function positions(uint256 tokenId) external view returns (address, int24, int24, uint128, uint256, uint256) {
        Pos memory p = _pos[tokenId];
        return (p.pool, p.tickLower, p.tickUpper, p.liquidity, p.owedBase, p.owedQuote);
    }

    /// @notice What the position's liquidity holds at `price`, whatever the pool's own price is.
    function amountsAt(uint256 tokenId, uint256 price) external view returns (uint256 base, uint256 quote) {
        return _amounts(_pos[tokenId].liquidity, price);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(ownerOf[tokenId] == from && from == msg.sender, "not owner");
        ownerOf[tokenId] = to;
    }

    /// @dev Constant product: base * quote = L^2 and quote / base = price / 1e18.
    function _amounts(uint128 liquidity, uint256 price) private pure returns (uint256 base, uint256 quote) {
        // sqrt(price / 1e18) * 1e18, computed so that it cannot overflow for any price
        uint256 s = price <= 1e58 ? _sqrt(price * 1e18) : _sqrt(price) * 1e9;
        base = uint256(liquidity) * 1e18 / s;
        quote = uint256(liquidity) * s / 1e18;
    }

    function _sqrt(uint256 x) private pure returns (uint256 y) {
        if (x == 0) return 0;
        uint256 z = x / 2 + 1;
        y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }
}

/// @notice An ERC-721-shaped identity registry reduced to what the tests need.
///         Not audited: a test double, never deploy it, and never deploy anything here without an external audit.
/// @custom:security Not audited. Never deploy without an external audit.
contract MockRegistry {
    mapping(uint256 => address) private _owners;

    function mint(address to, uint256 id) external {
        _owners[id] = to;
    }

    function ownerOf(uint256 id) external view returns (address o) {
        o = _owners[id];
        require(o != address(0), "no token");
    }
}
