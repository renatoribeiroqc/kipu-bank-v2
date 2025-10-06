// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title KipuBank (V2)
 * @author Renato Ribeiro
 * @notice A minimal ETH vault with per-tx withdrawal limit and a global bank cap.
 *
 * @dev Demonstrates secure Solidity practices for ETH handling, custom errors,
 *      NatSpec, events, immutables, modifiers, and CEI (checks-effects-interactions).
 *
 * @notice Upgraded vault:
 *  - AccessControl (ADMIN_ROLE)
 *  - Multi-token (ETH + ERC-20 via nested mappings; ETH = address(0))
 *  - Global bank cap in USD-6 using Chainlink feeds at txn time
 *  - Decimal conversion (token decimals & feed decimals -> USD-6)
 *  - Custom errors, rich events, CEI, ReentrancyGuard, SafeERC20
 *
 * @dev This extends the original V1 concepts while keeping the same filename and folder structure.
 */

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @dev Minimal Chainlink Aggregator v3 interface kept for type usage in storage/ctor.
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

/// @dev Legacy-like interface exposing latestAnswer(); many feeds (incl. Sepolia) support this.
interface AggregatorV2V3Like {
    function latestAnswer() external view returns (int256);
    function decimals() external view returns (uint8);
}

/**
 * @dev Token configuration: enabled flag, decimals, and price feed.
 *      For ETH (address(0)), decimals are fixed to 18 and feed is ETH/USD.
 */
struct TokenConfig {
    bool enabled;
    uint8 decimals;
    AggregatorV3Interface feed; // TOKEN/USD (or ETH/USD)
}

contract KipuBank is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ========= Constants =========

    /// @notice Human-readable version.
    string public constant VERSION = "2.0.0";

    /// @notice Sentinel for native ETH.
    address public constant ETH_ADDRESS = address(0);

    /// @notice Internal USD accounting uses USDC-style 6 decimals.
    uint8 public constant USD_DECIMALS = 6;

    /// @notice Admin role allowed to update cap/token configs.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // ========= Storage (V2 additions while keeping V1 spirit) =========

    /// @notice Bank cap in USD-6; total vault value (at txn time) must not exceed this on deposit.
    uint256 public bankCapUsd6;

    /// @notice Running total USD-6 (valued at txn time). See notes in withdraw() about saturation.
    uint256 public totalUsd6;

    /// @notice User balances per token: balances[token][user] in token native units.
    mapping(address => mapping(address => uint256)) private _balances;

    /// @notice Per-token totals in token native units (analytics).
    mapping(address => uint256) public totalTokenBalances;

    /// @notice Token registry (ETH + ERC20) with decimals & price feed.
    mapping(address => TokenConfig) public tokenConfig;

    /// @notice Global counters (kept from V1 design).
    uint256 public depositCount;
    uint256 public withdrawalCount;

    // ========= Events =========

    event TokenConfigured(address indexed token, bool enabled, address indexed feed, uint8 decimals);
    event BankCapUpdated(uint256 oldCapUsd6, uint256 newCapUsd6);
    event Deposited(
        address indexed token,
        address indexed account,
        uint256 amountToken,
        uint256 valuedUsd6,
        uint256 newUserTokenBalance
    );
    event Withdrawn(
        address indexed token,
        address indexed account,
        address indexed to,
        uint256 amountToken,
        uint256 valuedUsd6,
        uint256 newUserTokenBalance
    );
    event EtherPayoutFailed(address indexed to, uint256 amount);

    // ========= Custom Errors (gas-efficient) =========

    error AmountZero();
    error TokenDisabled(address token);
    error PriceFeedNotSet(address token);
    error NegativePrice(address token);
    error BankCapExceeded(uint256 attemptedUsd6, uint256 capUsd6);
    error InsufficientBalance(uint256 requested, uint256 available);
    error EtherTransferFailed();

    // ========= Constructor =========

    /**
     * @param admin Receives DEFAULT_ADMIN_ROLE and ADMIN_ROLE.
     * @param _bankCapUsd6 Bank cap in USD-6 (e.g., 5_000_000 == $5,000.000).
     * @param ethUsdFeed Chainlink ETH/USD feed (for address(0) ETH).
     */
    constructor(address admin, uint256 _bankCapUsd6, AggregatorV3Interface ethUsdFeed) {
        require(admin != address(0), "admin=0");
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);

        bankCapUsd6 = _bankCapUsd6;

        // Pre-register ETH.
        tokenConfig[ETH_ADDRESS] = TokenConfig({
            enabled: true,
            decimals: 18,
            feed: ethUsdFeed
        });

        emit TokenConfigured(ETH_ADDRESS, true, address(ethUsdFeed), 18);
        emit BankCapUpdated(0, _bankCapUsd6);
    }

    // ========= Admin =========

    /**
     * @notice Register / update a token (ERC20) or ETH (address(0)).
     * @dev For ETH, decimals are forced to 18.
     */
    function setTokenConfig(
        address token,
        bool enabled,
        uint8 decimals_,
        AggregatorV3Interface feed
    ) external onlyRole(ADMIN_ROLE) {
        if (token == ETH_ADDRESS) {
            tokenConfig[token] = TokenConfig({enabled: enabled, decimals: 18, feed: feed});
            emit TokenConfigured(token, enabled, address(feed), 18);
        } else {
            tokenConfig[token] = TokenConfig({enabled: enabled, decimals: decimals_, feed: feed});
            emit TokenConfigured(token, enabled, address(feed), decimals_);
        }
    }

    /// @notice Update the global USD-6 bank cap.
    function setBankCapUsd6(uint256 newCapUsd6) external onlyRole(ADMIN_ROLE) {
        uint256 old = bankCapUsd6;
        bankCapUsd6 = newCapUsd6;
        emit BankCapUpdated(old, newCapUsd6);
    }

    // ========= Views =========

    /// @notice Read user balance of a token (native units).
    function balanceOf(address token, address account) external view returns (uint256) {
        return _balances[token][account];
    }

    /**
     * @notice Convert a token amount to USD-6 using Chainlink `latestAnswer()` (legacy accessor).
     * @dev Reverts if token disabled, feed unset, or negative price.
     *      We keep the feed typed as AggregatorV3Interface in storage, but cast to a
     *      legacy-compatible interface here to call `latestAnswer()` explicitly.
     */
    function quoteToUsd6(address token, uint256 amountToken) public view returns (uint256 usd6) {
        TokenConfig memory cfg = tokenConfig[token];
        if (!cfg.enabled) revert TokenDisabled(token);
        if (address(cfg.feed) == address(0)) revert PriceFeedNotSet(token);

        AggregatorV2V3Like feed = AggregatorV2V3Like(address(cfg.feed));

        int256 answer = feed.latestAnswer(); // <— uses latestAnswer() as requested
        if (answer <= 0) revert NegativePrice(token);

        uint8 feedDec = feed.decimals();
        uint8 tokDec = token == ETH_ADDRESS ? 18 : cfg.decimals;

        // usd6 = amount * price * 10^USD_DECIMALS / (10^tokDec * 10^feedDec)
        uint256 price = uint256(answer);
        uint256 num = amountToken * price * (10 ** USD_DECIMALS);
        uint256 den = (10 ** tokDec) * (10 ** feedDec);
        usd6 = num / den;
    }

    // ========= Actions =========

    /// @notice Deposit native ETH (valued at txn-time via ETH/USD feed).
    function depositETH() external payable nonReentrant {
        if (msg.value == 0) revert AmountZero();

        uint256 usd6 = quoteToUsd6(ETH_ADDRESS, msg.value);
        uint256 newTotal = totalUsd6 + usd6;
        if (newTotal > bankCapUsd6) revert BankCapExceeded(newTotal, bankCapUsd6);

        // Effects
        _balances[ETH_ADDRESS][msg.sender] += msg.value;
        totalTokenBalances[ETH_ADDRESS] += msg.value;
        totalUsd6 = newTotal;
        unchecked { depositCount++; }

        emit Deposited(ETH_ADDRESS, msg.sender, msg.value, usd6, _balances[ETH_ADDRESS][msg.sender]);
        // Interactions: none (ETH already received)
    }

    /**
     * @notice Deposit ERC-20 tokens (requires prior approve).
     * @param token ERC-20 token address.
     * @param amount Amount in token native units.
     */
    function depositERC20(address token, uint256 amount) external nonReentrant {
        if (token == ETH_ADDRESS) revert(); // use depositETH()
        if (amount == 0) revert AmountZero();

        TokenConfig memory cfg = tokenConfig[token];
        if (!cfg.enabled) revert TokenDisabled(token);

        uint256 usd6 = quoteToUsd6(token, amount);
        uint256 newTotal = totalUsd6 + usd6;
        if (newTotal > bankCapUsd6) revert BankCapExceeded(newTotal, bankCapUsd6);

        // Interactions first (pull), then effects (CEI variation is safe since SafeERC20 reverts on failure).
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        // Effects
        _balances[token][msg.sender] += amount;
        totalTokenBalances[token] += amount;
        totalUsd6 = newTotal;
        unchecked { depositCount++; }

        emit Deposited(token, msg.sender, amount, usd6, _balances[token][msg.sender]);
    }

    /**
     * @notice Withdraw ETH or ERC-20 to `to` (defaults to caller if zero address).
     * @param token ERC-20 address or address(0) for ETH.
     * @param amount Token units.
     * @param to Recipient.
     */
    function withdraw(address token, uint256 amount, address to) external nonReentrant {
        if (amount == 0) revert AmountZero();
        if (to == address(0)) to = msg.sender;

        uint256 bal = _balances[token][msg.sender];
        if (amount > bal) revert InsufficientBalance(amount, bal);

        // Valuation at txn time (for analytics / totalUsd6 accounting).
        uint256 usd6 = quoteToUsd6(token, amount);

        // Effects
        unchecked { _balances[token][msg.sender] = bal - amount; }
        totalTokenBalances[token] -= amount;

        // Saturating subtraction to avoid underflow if price moved a lot since deposit
        if (usd6 > totalUsd6) totalUsd6 = 0;
        else totalUsd6 -= usd6;

        unchecked { withdrawalCount++; }

        // Interactions
        if (token == ETH_ADDRESS) {
            (bool ok, ) = payable(to).call{value: amount}("");
            if (!ok) {
                emit EtherPayoutFailed(to, amount);
                revert EtherTransferFailed();
            }
        } else {
            IERC20(token).safeTransfer(to, amount);
        }

        emit Withdrawn(token, msg.sender, to, amount, usd6, _balances[token][msg.sender]);
    }

    // ========= Fallbacks (keep V1 behavior: force use of depositETH()) =========

    receive() external payable {
        revert TokenDisabled(ETH_ADDRESS); // disable direct sends, must call depositETH()
    }

    fallback() external payable {
        revert TokenDisabled(ETH_ADDRESS);
    }
}