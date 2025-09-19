// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/* OZ IMPORTS */
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {
    ERC165Upgradeable, IERC165
} from "@openzeppelin/contracts-upgradeable/utils/introspection/ERC165Upgradeable.sol";

/* UNISWAP V4 IMPORTS */
import {BaseDynamicFee} from "../../../src/BaseDynamicFee.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/* LOCAL IMPORTS */
import {IAlphixLogic} from "../../../src/interfaces/IAlphixLogic.sol";
import {DynamicFeeLib} from "../../../src/libraries/DynamicFee.sol";

/**
 * @title MockAlphixLogic
 * @author Alphix
 * @notice Layout-compatible mock for AlphixLogic that appends a new storage var and uses it in compute paths
 * @dev Mirrors v1 storage order, appends `mockFee`, and shrinks the gap to keep alignment for UUPS upgrade tests
 */
contract MockAlphixLogic is
    Initializable,
    Ownable2StepUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    ERC165Upgradeable,
    IAlphixLogic
{
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;

    /* CONSTANTS (kept same as logic for validation paths) */
    uint256 internal constant ONE = 1e18;
    uint256 internal constant TEN = 1e19;
    uint256 private constant MAX_ADJUSTMENT_RATE =
        (uint256(type(uint24).max) * ONE) / uint256(LPFeeLibrary.MAX_LP_FEE) - 1;
    uint256 internal constant MIN_PERIOD = 1 hours;
    uint256 internal constant MIN_RATIO_TOLERANCE = 1e15;
    uint256 internal constant MIN_LINEAR_SLOPE = 1e17;
    uint24 internal constant MIN_LOOKBACK_PERIOD = 7;
    uint24 internal constant MAX_LOOKBACK_PERIOD = 365;
    uint24 internal constant MIN_FEE = 1;

    /* MATCHING STORAGE (must mirror AlphixLogic order) */

    // 1. Global cap for adjustment rate
    uint256 private globalMaxAdjRate;

    // 2. Alphix Hook address
    address private alphixHook;

    // 3. Pool active flag
    mapping(PoolId => bool) private poolActive;

    // 4. Pool config
    mapping(PoolId => PoolConfig) private poolConfig;

    // 5. OOB state
    mapping(PoolId => DynamicFeeLib.OOBState) private oobState;

    // 6. Target ratio
    mapping(PoolId => uint256) private targetRatio;

    // 7. Last fee update timestamp
    mapping(PoolId => uint256) private lastFeeUpdate;

    // 8. Per-type parameters
    mapping(PoolType => DynamicFeeLib.PoolTypeParams) private poolTypeParams;

    /* NEW APPENDED STORAGE (v2) */
    uint24 private mockFee;

    /* GAP SHRUNK BY ONE SLOT (from 50 to 49) */
    uint256[49] private __gap;

    /* MODIFIERS */

    modifier onlyAlphixHook() {
        if (msg.sender != alphixHook) revert InvalidCaller();
        _;
    }

    modifier poolActivated(PoolKey calldata key) {
        PoolId id = key.toId();
        if (!poolActive[id]) revert PoolPaused();
        _;
    }

    modifier poolUnconfigured(PoolKey calldata key) {
        PoolId id = key.toId();
        if (poolConfig[id].isConfigured) revert PoolAlreadyConfigured();
        _;
    }

    modifier poolConfigured(PoolKey calldata key) {
        PoolId id = key.toId();
        if (!poolConfig[id].isConfigured) revert PoolNotConfigured();
        _;
    }

    /* CONSTRUCTOR */

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /* INITIALIZER (aligned with current logic) */

    /**
     * @notice Initialize the logic with owner, hook, and per-type params
     * @dev Sets default globalMaxAdjRate and seeds per-type params, mirroring production logic’s behavior
     */
    function initialize(
        address _owner,
        address _alphixHook,
        DynamicFeeLib.PoolTypeParams memory _stableParams,
        DynamicFeeLib.PoolTypeParams memory _standardParams,
        DynamicFeeLib.PoolTypeParams memory _volatileParams
    ) public initializer {
        __Ownable2Step_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __ERC165_init();

        if (_owner == address(0) || _alphixHook == address(0)) revert InvalidAddress();

        _transferOwnership(_owner);
        alphixHook = _alphixHook;

        // Set default global cap (same as logic)
        _setGlobalMaxAdjRate(TEN);

        // Initialize params for each pool type
        _setPoolTypeParams(PoolType.STABLE, _stableParams);
        _setPoolTypeParams(PoolType.STANDARD, _standardParams);
        _setPoolTypeParams(PoolType.VOLATILE, _volatileParams);
    }

    /* ERC165 */

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IAlphixLogic).interfaceId || super.supportsInterface(interfaceId);
    }

    /* CORE HOOK LOGIC (stubs) */

    function beforeInitialize(address, PoolKey calldata, uint160)
        external
        view
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata key, uint160, int24)
        external
        view
        override
        onlyAlphixHook
        whenNotPaused
        returns (bytes4)
    {
        if (!key.fee.isDynamicFee()) revert BaseDynamicFee.NotDynamicFee();
        return this.afterInitialize.selector;
    }

    function beforeAddLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4)
    {
        return this.beforeAddLiquidity.selector;
    }

    function beforeRemoveLiquidity(address, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4)
    {
        return this.beforeRemoveLiquidity.selector;
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivated(key) whenNotPaused returns (bytes4, BalanceDelta) {
        return (this.afterAddLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view override onlyAlphixHook poolActivated(key) whenNotPaused returns (bytes4, BalanceDelta) {
        return (this.afterRemoveLiquidity.selector, BalanceDeltaLibrary.ZERO_DELTA);
    }

    function beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, BalanceDelta, bytes calldata)
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (bytes4, int128)
    {
        return (this.afterSwap.selector, 0);
    }

    /* FEE COMPUTE/FINALIZE (ratio-aware, view + write) */

    /**
     * @notice Compute fee and target ratio using mockFee if set; return no-op EMA and passthrough OOB state
     * @dev View-only compute to maintain “compute, then manager update, then finalize” ordering in hook
     */
    function computeFeeAndTargetRatio(PoolKey calldata key, uint256 /* currentRatio */ )
        external
        view
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
        returns (uint24 newFee, uint256 oldTarget, uint256 newTarget, DynamicFeeLib.OOBState memory sOut)
    {
        PoolId poolId = key.toId();
        PoolConfig memory cfg = poolConfig[poolId];
        DynamicFeeLib.PoolTypeParams memory pp = poolTypeParams[cfg.poolType];

        // Cooldown check mirrors production logic
        uint256 nextTs = lastFeeUpdate[poolId] + pp.minPeriod;
        if (block.timestamp < nextTs) revert CooldownNotElapsed(poolId, nextTs);

        // Read current fee from PoolManager
        (,,, uint24 currentFee) = BaseDynamicFee(alphixHook).poolManager().getSlot0(poolId);

        // If mockFee is set, prefer it; otherwise reflect the current live fee
        uint24 mf = mockFee;
        newFee = mf == 0 ? currentFee : mf;

        oldTarget = targetRatio[poolId];
        newTarget = oldTarget; // no-op EMA for the mock
        sOut = oobState[poolId]; // passthrough
    }

    /**
     * @notice Finalize after fee update by persisting target ratio, OOB state, and timestamp
     * @dev This matches the hook’s post-manager-update finalize step
     */
    function finalizeAfterFeeUpdate(PoolKey calldata key, uint256 newTarget, DynamicFeeLib.OOBState calldata sOut)
        external
        override
        onlyAlphixHook
        poolActivated(key)
        whenNotPaused
    {
        PoolId poolId = key.toId();
        targetRatio[poolId] = newTarget;
        oobState[poolId] = sOut;
        lastFeeUpdate[poolId] = block.timestamp;
    }

    /* POOL MANAGEMENT */

    function activateAndConfigurePool(
        PoolKey calldata key,
        uint24 _initialFee,
        uint256 _initialTargetRatio,
        PoolType _poolType
    ) external override onlyAlphixHook poolUnconfigured(key) whenNotPaused {
        PoolId id = key.toId();
        lastFeeUpdate[id] = block.timestamp;
        targetRatio[id] = _initialTargetRatio;
        poolConfig[id].initialFee = _initialFee;
        poolConfig[id].initialTargetRatio = _initialTargetRatio;
        poolConfig[id].poolType = _poolType;
        poolConfig[id].isConfigured = true;
        poolActive[id] = true;
    }

    function activatePool(PoolKey calldata key) external override onlyAlphixHook whenNotPaused poolConfigured(key) {
        poolActive[key.toId()] = true;
    }

    function deactivatePool(PoolKey calldata key) external override onlyAlphixHook whenNotPaused {
        poolActive[key.toId()] = false;
    }

    function setPoolTypeParams(PoolType poolType, DynamicFeeLib.PoolTypeParams calldata params)
        external
        override
        onlyAlphixHook
        whenNotPaused
    {
        _setPoolTypeParams(poolType, params);
    }

    function isValidFeeForPoolType(PoolType poolType, uint24 fee)
        external
        view
        override
        onlyAlphixHook
        returns (bool)
    {
        DynamicFeeLib.PoolTypeParams memory p = poolTypeParams[poolType];
        return fee >= p.minFee && fee <= p.maxFee;
    }

    /* GLOBAL PARAMS */

    function setGlobalMaxAdjRate(uint256 _globalMaxAdjRate) external override onlyAlphixHook whenNotPaused {
        _setGlobalMaxAdjRate(_globalMaxAdjRate);
    }

    /* ADMIN */

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /* GETTERS */

    function getAlphixHook() external view override returns (address) {
        return alphixHook;
    }

    function getPoolConfig(PoolId id) external view override returns (PoolConfig memory) {
        return poolConfig[id];
    }

    function getPoolTypeParams(PoolType poolType)
        external
        view
        override
        returns (DynamicFeeLib.PoolTypeParams memory)
    {
        return poolTypeParams[poolType];
    }

    function getGlobalMaxAdjRate() external view override returns (uint256) {
        return globalMaxAdjRate;
    }

    /* INTERNAL */

    function _setPoolTypeParams(PoolType poolType, DynamicFeeLib.PoolTypeParams memory params) internal {
        // Fee bounds
        if (params.minFee < MIN_FEE || params.minFee > params.maxFee || params.maxFee > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidFeeBounds(params.minFee, params.maxFee);
        }
        // baseMaxFeeDelta
        if (params.baseMaxFeeDelta < MIN_FEE || params.baseMaxFeeDelta > LPFeeLibrary.MAX_LP_FEE) {
            revert InvalidParameter();
        }
        // minPeriod
        if (params.minPeriod < MIN_PERIOD) revert InvalidParameter();
        // lookbackPeriod
        if (params.lookbackPeriod < MIN_LOOKBACK_PERIOD || params.lookbackPeriod > MAX_LOOKBACK_PERIOD) {
            revert InvalidParameter();
        }
        // ratioTolerance
        if (params.ratioTolerance < MIN_RATIO_TOLERANCE || params.ratioTolerance > TEN) {
            revert InvalidParameter();
        }
        // linearSlope
        if (params.linearSlope < MIN_LINEAR_SLOPE || params.linearSlope > TEN) {
            revert InvalidParameter();
        }
        // side multipliers
        if (params.upperSideFactor < ONE || params.upperSideFactor > TEN) revert InvalidParameter();
        if (params.lowerSideFactor < ONE || params.lowerSideFactor > TEN) revert InvalidParameter();

        poolTypeParams[poolType] = params;
        emit PoolTypeParamsUpdated(
            poolType,
            params.minFee,
            params.maxFee,
            params.lookbackPeriod,
            params.minPeriod,
            params.ratioTolerance,
            params.linearSlope,
            params.lowerSideFactor,
            params.upperSideFactor
        );
    }

    function _setGlobalMaxAdjRate(uint256 _globalMaxAdjRate) internal {
        if (_globalMaxAdjRate == 0 || _globalMaxAdjRate > MAX_ADJUSTMENT_RATE) revert InvalidParameter();
        uint256 old = globalMaxAdjRate;
        globalMaxAdjRate = _globalMaxAdjRate;
        emit GlobalMaxAdjRateUpdated(old, globalMaxAdjRate);
    }

    /* UUPS AUTHORIZATION */

    function _authorizeUpgrade(address newImplementation) internal view override onlyOwner {
        if (!IERC165(newImplementation).supportsInterface(type(IAlphixLogic).interfaceId)) {
            revert InvalidLogicContract();
        }
    }

    /* MOCK API */

    /**
     * @notice Reinitializer for mock-only fee override
     * @dev Allows setting a mock fee post-deploy without changing v1 storage
     */
    function initializeV2(uint24 _mockFee) public reinitializer(2) {
        mockFee = _mockFee;
    }
}
