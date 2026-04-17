// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

/// @title MultiEpochAuctionApplicationMVP
/// @notice Launchpad-oriented MVP for TrustNet frontend integration.
/// @dev Quantity is treated as whole-token units (not 1e18 base units) to align with current frontend inputs.
///      Payment is quoted in wei as: `quantity * pricePerTokenWei`.
contract MultiEpochAuctionApplicationMVP {
    uint256 public constant BPS = 10_000;
    uint256 public constant TOKEN_DECIMALS_SCALE = 1e18;

    uint256 public constant DEFAULT_TOTAL_EPOCHS = 20;
    uint256 public constant DEFAULT_EPOCH_DURATION = 180; // 3 minutes
    uint256 public constant DEFAULT_COMMIT_DURATION = 120;
    uint256 public constant DEFAULT_REVEAL_DURATION = 60;

    error NotOwner();
    error ContractPaused();
    error InvalidAddress();
    error InvalidConfig();
    error InvalidApplication();
    error InvalidApplicationStatus();
    error AuctionNotLive();
    error InvalidEpoch();
    error CommitWindowClosed();
    error RevealWindowClosed();
    error BidAlreadyCommitted();
    error BidNotCommitted();
    error BidAlreadyRevealed();
    error InvalidCommitment();
    error InvalidReveal();
    error InvalidQuantity();
    error PriceBelowEpochPrice(uint256 bidPrice, uint256 epochPrice);
    error IncorrectPayment(uint256 requiredAmount, uint256 providedAmount);
    error EpochNotFinished();
    error EpochAlreadyFinalized();
    error EpochNotFinalized();
    error NothingToClaim();
    error NothingToWithdraw();
    error RefundAlreadyWithdrawn();
    error TokensAlreadyClaimed();
    error TransferFailed();

    enum Phase {
        Commit,
        Reveal,
        Closed
    }

    enum ApplicationStatus {
        Draft,
        Submitted,
        Approved,
        Rejected,
        Live,
        Closed
    }

    struct AuctionApplication {
        uint256 id;
        address applicant;
        string metadataURI;
        ApplicationStatus status;
        uint64 createdAt;
        uint64 submittedAt;
        uint64 approvedAt;
        uint64 reviewedAt;
        uint64 liveAt;
        uint64 closedAt;
        string rejectReason;

        uint256 startTime;
        uint256 totalEpochs;
        uint256 epochDuration;
        uint256 commitDuration;
        uint256 revealDuration;
        uint256 maxQuantityPerBid;
    }

    struct EpochConfig {
        uint256 pricePerTokenWei;
        uint256 supplyTokens;
    }

    struct EpochRuntime {
        uint256 tokensSold;
        uint256 totalPaymentWei;
        bool finalized;
    }

    /// @dev Compatibility layout with existing `getUserBid` ABI from frontend.
    struct Bid {
        bytes32 commitment;
        uint256 collateral;
        uint256 quantity;
        uint256 pricePerToken;
        uint256 allocatedQuantity;
        uint256 paymentDue;
        uint256 refundDue;
        bool revealed;
        bool winner;
        bool refundWithdrawn;
        bool tokensClaimed;
        bool processed;
    }

    IERC20Like public immutable saleToken;

    address public owner;
    address public treasury;
    bool public paused;

    uint256 public nextApplicationId = 1;
    uint256 public activeApplicationId;

    uint256 public treasuryAccrued;

    mapping(uint256 => AuctionApplication) private _applications;
    mapping(uint256 => mapping(uint256 => EpochConfig)) private _epochConfigs;
    mapping(uint256 => mapping(uint256 => EpochRuntime)) private _epochRuntime;

    mapping(uint256 => mapping(uint256 => mapping(address => Bid))) private _bids;
    mapping(uint256 => mapping(uint256 => address[])) private _epochParticipants;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) private _isEpochParticipant;

    uint256 private _lockState = 1;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PauseStateChanged(bool paused);
    event TreasuryUpdated(address indexed treasury);

    event AuctionApplicationCreated(uint256 indexed applicationId, address indexed applicant, string metadataURI);
    event AuctionApplicationSubmitted(uint256 indexed applicationId);
    event AuctionApplicationApproved(uint256 indexed applicationId);
    event AuctionApplicationRejected(uint256 indexed applicationId, string reason);
    event AuctionApplicationLive(uint256 indexed applicationId, uint256 startTime);
    event AuctionApplicationClosed(uint256 indexed applicationId);

    event EpochConfigSet(uint256 indexed applicationId, uint256 indexed epochId, uint256 pricePerTokenWei, uint256 supplyTokens);
    event EpochCurveInitialized(
        uint256 indexed applicationId,
        uint256 firstEpochPriceWei,
        uint16 lastEpochPriceBps,
        uint256 totalSupplyTokens,
        uint16 lastEpochSupplyBps
    );

    event BidCommitted(
        uint256 indexed applicationId,
        uint256 indexed epochId,
        address indexed bidder,
        bytes32 commitment,
        uint256 collateral,
        bool legacyCommitOnly
    );

    event BidRevealed(
        uint256 indexed applicationId,
        uint256 indexed epochId,
        address indexed bidder,
        uint256 quantity,
        uint256 pricePerToken,
        uint256 allocatedQuantity,
        uint256 paymentDue,
        uint256 refundDue
    );

    event EpochFinalized(
        uint256 indexed applicationId,
        uint256 indexed epochId,
        uint256 pricePerTokenWei,
        uint256 supplyTokens,
        uint256 tokensSold,
        uint256 remainingTokens
    );

    event TokensClaimed(address indexed bidder, uint256 totalTokenUnits);
    event RefundWithdrawn(uint256 indexed applicationId, uint256 indexed epochId, address indexed bidder, uint256 amount);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event UnsoldTokensRecovered(address indexed to, uint256 amountTokenUnits);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier nonReentrant() {
        if (_lockState != 1) revert TransferFailed();
        _lockState = 2;
        _;
        _lockState = 1;
    }

    constructor(address saleToken_, address treasury_) {
        if (saleToken_ == address(0) || treasury_ == address(0)) revert InvalidAddress();

        saleToken = IERC20Like(saleToken_);
        treasury = treasury_;

        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    receive() external payable {}

    // ---------------------------------------------------------------------
    // Ownership & safety
    // ---------------------------------------------------------------------

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        address previous = owner;
        owner = newOwner;
        emit OwnershipTransferred(previous, newOwner);
    }

    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert InvalidAddress();
        treasury = newTreasury;
        emit TreasuryUpdated(newTreasury);
    }

    function pause() external onlyOwner {
        paused = true;
        emit PauseStateChanged(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PauseStateChanged(false);
    }

    // ---------------------------------------------------------------------
    // Auction applications (draft -> submitted -> approved -> live -> closed)
    // ---------------------------------------------------------------------

    function createAuctionApplication(
        address applicant,
        string calldata metadataURI,
        uint256 totalEpochs_,
        uint256 epochDuration_,
        uint256 commitDuration_,
        uint256 revealDuration_,
        uint256 maxQuantityPerBid_
    ) external onlyOwner returns (uint256 applicationId) {
        if (applicant == address(0)) revert InvalidAddress();

        uint256 normalizedTotalEpochs = totalEpochs_ == 0 ? DEFAULT_TOTAL_EPOCHS : totalEpochs_;
        uint256 normalizedEpochDuration = epochDuration_ == 0 ? DEFAULT_EPOCH_DURATION : epochDuration_;
        uint256 normalizedCommitDuration = commitDuration_ == 0 ? DEFAULT_COMMIT_DURATION : commitDuration_;
        uint256 normalizedRevealDuration = revealDuration_ == 0 ? DEFAULT_REVEAL_DURATION : revealDuration_;

        if (
            normalizedTotalEpochs == 0 ||
            normalizedEpochDuration == 0 ||
            normalizedCommitDuration + normalizedRevealDuration > normalizedEpochDuration ||
            maxQuantityPerBid_ == 0
        ) {
            revert InvalidConfig();
        }

        applicationId = nextApplicationId++;

        AuctionApplication storage app = _applications[applicationId];
        app.id = applicationId;
        app.applicant = applicant;
        app.metadataURI = metadataURI;
        app.status = ApplicationStatus.Draft;
        app.createdAt = uint64(block.timestamp);

        app.totalEpochs = normalizedTotalEpochs;
        app.epochDuration = normalizedEpochDuration;
        app.commitDuration = normalizedCommitDuration;
        app.revealDuration = normalizedRevealDuration;
        app.maxQuantityPerBid = maxQuantityPerBid_;

        emit AuctionApplicationCreated(applicationId, applicant, metadataURI);
    }

    function submitAuctionApplication(uint256 applicationId) external onlyOwner {
        AuctionApplication storage app = _requireApplication(applicationId);
        if (app.status != ApplicationStatus.Draft) revert InvalidApplicationStatus();

        app.status = ApplicationStatus.Submitted;
        app.submittedAt = uint64(block.timestamp);

        emit AuctionApplicationSubmitted(applicationId);
    }

    function approveAuctionApplication(uint256 applicationId) external onlyOwner {
        AuctionApplication storage app = _requireApplication(applicationId);
        if (app.status != ApplicationStatus.Submitted) revert InvalidApplicationStatus();
        if (!_isApplicationEpochConfigured(applicationId)) revert InvalidConfig();

        app.status = ApplicationStatus.Approved;
        app.approvedAt = uint64(block.timestamp);
        app.reviewedAt = uint64(block.timestamp);

        emit AuctionApplicationApproved(applicationId);
    }

    function rejectAuctionApplication(uint256 applicationId, string calldata reason) external onlyOwner {
        AuctionApplication storage app = _requireApplication(applicationId);
        if (app.status != ApplicationStatus.Submitted && app.status != ApplicationStatus.Approved) {
            revert InvalidApplicationStatus();
        }

        app.status = ApplicationStatus.Rejected;
        app.reviewedAt = uint64(block.timestamp);
        app.rejectReason = reason;

        emit AuctionApplicationRejected(applicationId, reason);
    }

    function launchAuctionApplication(uint256 applicationId, uint256 startTime) external onlyOwner {
        AuctionApplication storage app = _requireApplication(applicationId);
        if (app.status != ApplicationStatus.Approved) revert InvalidApplicationStatus();
        if (!_isApplicationEpochConfigured(applicationId)) revert InvalidConfig();

        if (activeApplicationId != 0) {
            AuctionApplication storage active = _applications[activeApplicationId];
            if (active.status == ApplicationStatus.Live) revert InvalidApplicationStatus();
        }

        app.status = ApplicationStatus.Live;
        app.startTime = startTime;
        app.liveAt = uint64(block.timestamp);

        activeApplicationId = applicationId;

        emit AuctionApplicationLive(applicationId, startTime);
    }

    function closeAuctionApplication(uint256 applicationId) external onlyOwner {
        AuctionApplication storage app = _requireApplication(applicationId);
        if (app.status != ApplicationStatus.Live) revert InvalidApplicationStatus();

        app.status = ApplicationStatus.Closed;
        app.closedAt = uint64(block.timestamp);

        if (activeApplicationId == applicationId) {
            activeApplicationId = 0;
        }

        emit AuctionApplicationClosed(applicationId);
    }

    function getApplication(uint256 applicationId) external view returns (AuctionApplication memory) {
        AuctionApplication storage app = _applications[applicationId];
        if (app.id == 0) revert InvalidApplication();
        return app;
    }

    function applicationIsFullyConfigured(uint256 applicationId) external view returns (bool) {
        return _isApplicationEpochConfigured(applicationId);
    }

    // ---------------------------------------------------------------------
    // Epoch configuration
    // ---------------------------------------------------------------------

    function setEpochConfig(
        uint256 applicationId,
        uint256 epochId,
        uint256 pricePerTokenWei,
        uint256 supplyTokens
    ) external onlyOwner {
        AuctionApplication storage app = _requireApplication(applicationId);
        _requireConfigurableStatus(app.status);

        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        if (pricePerTokenWei == 0 || supplyTokens == 0) revert InvalidConfig();

        _epochConfigs[applicationId][epochId] = EpochConfig({pricePerTokenWei: pricePerTokenWei, supplyTokens: supplyTokens});

        emit EpochConfigSet(applicationId, epochId, pricePerTokenWei, supplyTokens);
    }

    function setEpochConfigs(
        uint256 applicationId,
        uint256[] calldata pricesPerTokenWei,
        uint256[] calldata supplyTokens
    ) external onlyOwner {
        AuctionApplication storage app = _requireApplication(applicationId);
        _requireConfigurableStatus(app.status);

        uint256 n = app.totalEpochs;
        if (pricesPerTokenWei.length != n || supplyTokens.length != n) revert InvalidConfig();

        for (uint256 i = 0; i < n; i++) {
            uint256 epochId = i + 1;
            uint256 price = pricesPerTokenWei[i];
            uint256 supply = supplyTokens[i];
            if (price == 0 || supply == 0) revert InvalidConfig();

            _epochConfigs[applicationId][epochId] = EpochConfig({pricePerTokenWei: price, supplyTokens: supply});
            emit EpochConfigSet(applicationId, epochId, price, supply);
        }
    }

    /// @notice Initializes per-epoch price+supply using a front-high/back-low model.
    /// @dev Example target model: `lastEpochPriceBps = 5000` (50% of first), `lastEpochSupplyBps = 200` (2% of total).
    function initializeEpochCurve(
        uint256 applicationId,
        uint256 firstEpochPriceWei,
        uint16 lastEpochPriceBps,
        uint256 totalSupplyTokens,
        uint16 lastEpochSupplyBps
    ) external onlyOwner {
        AuctionApplication storage app = _requireApplication(applicationId);
        _requireConfigurableStatus(app.status);

        if (
            firstEpochPriceWei == 0 ||
            totalSupplyTokens == 0 ||
            lastEpochPriceBps == 0 ||
            lastEpochPriceBps > BPS ||
            lastEpochSupplyBps > BPS
        ) {
            revert InvalidConfig();
        }

        uint256 n = app.totalEpochs;
        if (n == 0) revert InvalidConfig();

        uint256 lastEpochPriceWei = (firstEpochPriceWei * uint256(lastEpochPriceBps)) / BPS;
        if (lastEpochPriceWei == 0) revert InvalidConfig();

        if (n == 1) {
            _epochConfigs[applicationId][1] = EpochConfig({pricePerTokenWei: firstEpochPriceWei, supplyTokens: totalSupplyTokens});
            emit EpochConfigSet(applicationId, 1, firstEpochPriceWei, totalSupplyTokens);

            emit EpochCurveInitialized(applicationId, firstEpochPriceWei, lastEpochPriceBps, totalSupplyTokens, lastEpochSupplyBps);
            return;
        }

        uint256 lastEpochSupply = (totalSupplyTokens * uint256(lastEpochSupplyBps)) / BPS;
        uint256 frontSupply = totalSupplyTokens - lastEpochSupply;

        uint256 frontEpochs = n - 1;
        uint256 weightSum = (frontEpochs * (frontEpochs + 1)) / 2; // descending weights
        uint256 assignedFrontSupply;

        for (uint256 i = 1; i <= n; i++) {
            uint256 price = firstEpochPriceWei - ((firstEpochPriceWei - lastEpochPriceWei) * (i - 1)) / (n - 1);
            uint256 supply;

            if (i == n) {
                supply = lastEpochSupply;
            } else {
                uint256 weight = n - i;
                supply = weightSum == 0 ? frontSupply : (frontSupply * weight) / weightSum;
                assignedFrontSupply += supply;
            }

            _epochConfigs[applicationId][i] = EpochConfig({pricePerTokenWei: price, supplyTokens: supply});
            emit EpochConfigSet(applicationId, i, price, supply);
        }

        // Keep total supply exact by assigning rounding dust to epoch 1.
        if (assignedFrontSupply < frontSupply) {
            _epochConfigs[applicationId][1].supplyTokens += (frontSupply - assignedFrontSupply);
            emit EpochConfigSet(
                applicationId,
                1,
                _epochConfigs[applicationId][1].pricePerTokenWei,
                _epochConfigs[applicationId][1].supplyTokens
            );
        }

        emit EpochCurveInitialized(applicationId, firstEpochPriceWei, lastEpochPriceBps, totalSupplyTokens, lastEpochSupplyBps);
    }

    function epochConfigFor(uint256 applicationId, uint256 epochId) external view returns (EpochConfig memory) {
        AuctionApplication storage app = _applications[applicationId];
        if (app.id == 0) revert InvalidApplication();
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        return _epochConfigs[applicationId][epochId];
    }

    // ---------------------------------------------------------------------
    // Runtime views (frontend compatibility + extra state)
    // ---------------------------------------------------------------------

    function auctionStartTime() public view returns (uint256) {
        if (activeApplicationId == 0) return 0;
        return _applications[activeApplicationId].startTime;
    }

    function totalEpochs() public view returns (uint256) {
        if (activeApplicationId == 0) return DEFAULT_TOTAL_EPOCHS;
        return _applications[activeApplicationId].totalEpochs;
    }

    function epochDuration() public view returns (uint256) {
        if (activeApplicationId == 0) return DEFAULT_EPOCH_DURATION;
        return _applications[activeApplicationId].epochDuration;
    }

    function commitDuration() public view returns (uint256) {
        if (activeApplicationId == 0) return DEFAULT_COMMIT_DURATION;
        return _applications[activeApplicationId].commitDuration;
    }

    function revealDuration() public view returns (uint256) {
        if (activeApplicationId == 0) return DEFAULT_REVEAL_DURATION;
        return _applications[activeApplicationId].revealDuration;
    }

    function maxQuantityPerBid() public view returns (uint256) {
        if (activeApplicationId == 0) return 0;
        return _applications[activeApplicationId].maxQuantityPerBid;
    }

    function currentEpoch() public view returns (uint256) {
        if (activeApplicationId == 0) return 1;

        AuctionApplication storage app = _applications[activeApplicationId];
        uint256 start = app.startTime;

        if (start == 0 || block.timestamp < start) {
            return 1;
        }

        uint256 elapsed = block.timestamp - start;
        uint256 epochId = (elapsed / app.epochDuration) + 1;
        if (epochId > app.totalEpochs) {
            return app.totalEpochs;
        }

        return epochId;
    }

    function getEpochWindows(uint256 epochId)
        public
        view
        returns (uint256 startTime, uint256 commitEnd, uint256 revealEnd)
    {
        uint256 appId = _requireActiveApplication();
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        startTime = app.startTime + (epochId - 1) * app.epochDuration;
        commitEnd = startTime + app.commitDuration;
        revealEnd = commitEnd + app.revealDuration;
    }

    function getEpochPhase(uint256 epochId) public view returns (Phase) {
        uint256 appId = _requireActiveApplication();
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        if (app.status != ApplicationStatus.Live) {
            return Phase.Closed;
        }

        (uint256 startTime, uint256 commitEnd, uint256 revealEnd) = getEpochWindows(epochId);

        if (block.timestamp < startTime) {
            return Phase.Closed;
        }

        if (block.timestamp < commitEnd) {
            return Phase.Commit;
        }

        if (block.timestamp < revealEnd) {
            return Phase.Reveal;
        }

        return Phase.Closed;
    }

    function currentPhase() external view returns (Phase) {
        if (activeApplicationId == 0) return Phase.Closed;
        return getEpochPhase(currentEpoch());
    }

    function floorPrice() external view returns (uint256) {
        return floorPriceForEpoch(currentEpoch());
    }

    function floorPriceForEpoch(uint256 epochId) public view returns (uint256) {
        uint256 appId = _requireActiveApplication();
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        return _epochConfigs[appId][epochId].pricePerTokenWei;
    }

    function previousWinningPrice() external view returns (uint256) {
        if (activeApplicationId == 0) return 0;

        uint256 epochId = currentEpoch();
        if (epochId <= 1) {
            return 0;
        }

        uint256 appId = activeApplicationId;
        if (!_epochRuntime[appId][epochId - 1].finalized) {
            return 0;
        }

        return _epochConfigs[appId][epochId - 1].pricePerTokenWei;
    }

    function tokensPerEpoch() external view returns (uint256) {
        if (activeApplicationId == 0) return 0;
        uint256 epochId = currentEpoch();
        return _epochConfigs[activeApplicationId][epochId].supplyTokens;
    }

    function getEpochRemainingTokens(uint256 epochId) public view returns (uint256) {
        uint256 appId = _requireActiveApplication();
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        EpochConfig storage cfg = _epochConfigs[appId][epochId];
        EpochRuntime storage rt = _epochRuntime[appId][epochId];
        if (rt.tokensSold >= cfg.supplyTokens) {
            return 0;
        }

        return cfg.supplyTokens - rt.tokensSold;
    }

    function currentEpochRemainingTokens() external view returns (uint256) {
        return getEpochRemainingTokens(currentEpoch());
    }

    function getCurrentEpochState() external view returns (uint256 epochId, Phase phase, uint256 remainingTokens) {
        if (activeApplicationId == 0) {
            return (1, Phase.Closed, 0);
        }

        epochId = currentEpoch();
        phase = getEpochPhase(epochId);
        remainingTokens = getEpochRemainingTokens(epochId);
    }

    /// @dev Frontend compatibility shape: (winningPrice, tokensSold, nextFloorPrice).
    function getEpochSummary(uint256 epochId)
        external
        view
        returns (uint256 winningPrice, uint256 tokensSold, uint256 nextFloorPrice)
    {
        uint256 appId = _requireActiveApplication();
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        winningPrice = _epochConfigs[appId][epochId].pricePerTokenWei;
        tokensSold = _epochRuntime[appId][epochId].tokensSold;
        nextFloorPrice = epochId < app.totalEpochs ? _epochConfigs[appId][epochId + 1].pricePerTokenWei : 0;
    }

    function getEpochSummaryDetailed(uint256 epochId)
        external
        view
        returns (
            uint256 pricePerTokenWei,
            uint256 supplyTokens,
            uint256 soldTokens,
            uint256 remainingTokens,
            bool finalized,
            Phase phase
        )
    {
        uint256 appId = _requireActiveApplication();
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        EpochConfig storage cfg = _epochConfigs[appId][epochId];
        EpochRuntime storage rt = _epochRuntime[appId][epochId];

        pricePerTokenWei = cfg.pricePerTokenWei;
        supplyTokens = cfg.supplyTokens;
        soldTokens = rt.tokensSold;
        remainingTokens = supplyTokens > soldTokens ? supplyTokens - soldTokens : 0;
        finalized = rt.finalized;
        phase = getEpochPhase(epochId);
    }

    function getUserBid(address user, uint256 epochId)
        external
        view
        returns (
            bytes32,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            bool,
            bool,
            bool
        )
    {
        uint256 appId = _requireActiveApplication();
        if (epochId == 0 || epochId > _applications[appId].totalEpochs) revert InvalidEpoch();

        Bid memory bid = _bids[appId][epochId][user];

        return (
            bid.commitment,
            bid.collateral,
            bid.quantity,
            bid.pricePerToken,
            bid.allocatedQuantity,
            bid.paymentDue,
            bid.refundDue,
            bid.revealed,
            bid.winner,
            bid.refundWithdrawn,
            bid.tokensClaimed
        );
    }

    // ---------------------------------------------------------------------
    // Bid flow
    // ---------------------------------------------------------------------

    /// @notice Legacy commit-only interface kept for existing frontend ABI.
    /// @dev User must call `revealBid` during reveal phase to materialize quantity/price/salt.
    function commitBid(uint256 epochId, bytes32 commitment) external payable whenNotPaused {
        uint256 appId = _requireLiveApplication();
        _requireEpochInCommitPhase(appId, epochId);

        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (msg.value == 0) revert IncorrectPayment(1, 0);

        Bid storage bid = _bids[appId][epochId][msg.sender];
        if (bid.commitment != bytes32(0)) revert BidAlreadyCommitted();

        bid.commitment = commitment;
        bid.collateral = msg.value;

        _trackParticipant(appId, epochId, msg.sender);

        emit BidCommitted(appId, epochId, msg.sender, commitment, msg.value, true);
    }

    /// @notice One-step commit interface matching frontend model `(epochId, quantity, priceEth, salt)`.
    function commitBid(
        uint256 epochId,
        uint256 quantity,
        uint256 pricePerToken,
        bytes32 salt
    ) external payable whenNotPaused {
        uint256 appId = _requireLiveApplication();
        _requireEpochInCommitPhase(appId, epochId);

        if (quantity == 0 || quantity > _applications[appId].maxQuantityPerBid) revert InvalidQuantity();

        Bid storage bid = _bids[appId][epochId][msg.sender];
        if (bid.commitment != bytes32(0)) revert BidAlreadyCommitted();

        bytes32 commitment = keccak256(abi.encodePacked(epochId, msg.sender, quantity, pricePerToken, salt));

        bid.commitment = commitment;
        bid.collateral = msg.value;

        _trackParticipant(appId, epochId, msg.sender);

        _materializeBid(appId, epochId, msg.sender, quantity, pricePerToken, true);

        emit BidCommitted(appId, epochId, msg.sender, commitment, msg.value, false);
    }

    function revealBid(
        uint256 epochId,
        uint256 quantity,
        uint256 pricePerToken,
        bytes32 salt
    ) external whenNotPaused {
        uint256 appId = _requireLiveApplication();
        _requireEpochInRevealPhase(appId, epochId);

        Bid storage bid = _bids[appId][epochId][msg.sender];
        if (bid.commitment == bytes32(0)) revert BidNotCommitted();
        if (bid.revealed) revert BidAlreadyRevealed();

        bytes32 digest = keccak256(abi.encodePacked(epochId, msg.sender, quantity, pricePerToken, salt));
        if (digest != bid.commitment) revert InvalidReveal();

        _materializeBid(appId, epochId, msg.sender, quantity, pricePerToken, false);
    }

    function finalizeEpoch(uint256 epochId) external whenNotPaused {
        uint256 appId = _requireLiveApplication();
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        EpochRuntime storage rt = _epochRuntime[appId][epochId];
        if (rt.finalized) revert EpochAlreadyFinalized();

        (, , uint256 revealEnd) = getEpochWindows(epochId);
        if (block.timestamp < revealEnd) revert EpochNotFinished();

        address[] storage participants = _epochParticipants[appId][epochId];
        for (uint256 i = 0; i < participants.length; i++) {
            address bidder = participants[i];
            Bid storage bid = _bids[appId][epochId][bidder];

            if (!bid.processed && bid.collateral > 0) {
                // Legacy commit-only bids not revealed in reveal window: full refund.
                bid.refundDue = bid.collateral;
                bid.processed = true;
            }
        }

        rt.finalized = true;

        EpochConfig storage cfg = _epochConfigs[appId][epochId];
        uint256 remaining = cfg.supplyTokens > rt.tokensSold ? cfg.supplyTokens - rt.tokensSold : 0;

        emit EpochFinalized(
            appId,
            epochId,
            cfg.pricePerTokenWei,
            cfg.supplyTokens,
            rt.tokensSold,
            remaining
        );
    }

    function claimTokens(uint256[] calldata epochIds) external nonReentrant {
        uint256 appId = _requireActiveApplication();
        AuctionApplication storage app = _applications[appId];

        uint256 totalWholeTokens;

        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 epochId = epochIds[i];
            if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
            if (!_epochRuntime[appId][epochId].finalized) revert EpochNotFinalized();

            Bid storage bid = _bids[appId][epochId][msg.sender];
            if (!bid.winner || bid.allocatedQuantity == 0) {
                continue;
            }
            if (bid.tokensClaimed) revert TokensAlreadyClaimed();

            bid.tokensClaimed = true;
            totalWholeTokens += bid.allocatedQuantity;
        }

        if (totalWholeTokens == 0) revert NothingToClaim();

        uint256 transferAmount = totalWholeTokens * TOKEN_DECIMALS_SCALE;
        bool ok = saleToken.transfer(msg.sender, transferAmount);
        if (!ok) revert TransferFailed();

        emit TokensClaimed(msg.sender, transferAmount);
    }

    function withdrawRefund(uint256 epochId) external nonReentrant {
        uint256 appId = _requireActiveApplication();
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        if (!_epochRuntime[appId][epochId].finalized) revert EpochNotFinalized();

        Bid storage bid = _bids[appId][epochId][msg.sender];

        if (bid.refundWithdrawn) revert RefundAlreadyWithdrawn();
        uint256 amount = bid.refundDue;
        if (amount == 0) revert NothingToWithdraw();

        bid.refundWithdrawn = true;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit RefundWithdrawn(appId, epochId, msg.sender, amount);
    }

    function withdrawTreasury(address payable to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0 || amount > treasuryAccrued) revert InvalidConfig();

        treasuryAccrued -= amount;

        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit TreasuryWithdrawn(to, amount);
    }

    /// @notice Allows owner to recover remaining auction inventory after the active auction is closed.
    function recoverUnsoldTokens(address to, uint256 amountTokenUnits) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();

        bool ok = saleToken.transfer(to, amountTokenUnits);
        if (!ok) revert TransferFailed();

        emit UnsoldTokensRecovered(to, amountTokenUnits);
    }

    // ---------------------------------------------------------------------
    // Internal helpers
    // ---------------------------------------------------------------------

    function _materializeBid(
        uint256 appId,
        uint256 epochId,
        address bidder,
        uint256 quantity,
        uint256 pricePerToken,
        bool commitPath
    ) internal {
        AuctionApplication storage app = _applications[appId];
        if (quantity == 0 || quantity > app.maxQuantityPerBid) revert InvalidQuantity();

        EpochConfig storage cfg = _epochConfigs[appId][epochId];
        if (cfg.pricePerTokenWei == 0 || cfg.supplyTokens == 0) revert InvalidConfig();

        if (pricePerToken < cfg.pricePerTokenWei) {
            revert PriceBelowEpochPrice(pricePerToken, cfg.pricePerTokenWei);
        }

        Bid storage bid = _bids[appId][epochId][bidder];

        uint256 maxAffordable = bid.collateral / cfg.pricePerTokenWei;
        if (maxAffordable == 0) revert IncorrectPayment(cfg.pricePerTokenWei, bid.collateral);

        uint256 remaining = _remainingTokens(appId, epochId);

        uint256 allocation = quantity;
        if (allocation > remaining) {
            allocation = remaining;
        }
        if (allocation > maxAffordable) {
            allocation = maxAffordable;
        }

        uint256 paymentDue = allocation * cfg.pricePerTokenWei;
        uint256 refundDue = bid.collateral - paymentDue;

        bid.quantity = quantity;
        bid.pricePerToken = pricePerToken;
        bid.allocatedQuantity = allocation;
        bid.paymentDue = paymentDue;
        bid.refundDue = refundDue;
        bid.revealed = true;
        bid.winner = allocation > 0;
        bid.processed = true;

        EpochRuntime storage rt = _epochRuntime[appId][epochId];
        rt.tokensSold += allocation;
        rt.totalPaymentWei += paymentDue;

        treasuryAccrued += paymentDue;

        emit BidRevealed(appId, epochId, bidder, quantity, pricePerToken, allocation, paymentDue, refundDue);

        // keep linter quiet about intentionally unused semantic flag
        if (commitPath) {
            // no-op: indicates this materialization happened during commit phase.
        }
    }

    function _remainingTokens(uint256 appId, uint256 epochId) internal view returns (uint256) {
        EpochConfig storage cfg = _epochConfigs[appId][epochId];
        EpochRuntime storage rt = _epochRuntime[appId][epochId];

        if (rt.tokensSold >= cfg.supplyTokens) {
            return 0;
        }

        return cfg.supplyTokens - rt.tokensSold;
    }

    function _trackParticipant(uint256 appId, uint256 epochId, address bidder) internal {
        if (!_isEpochParticipant[appId][epochId][bidder]) {
            _isEpochParticipant[appId][epochId][bidder] = true;
            _epochParticipants[appId][epochId].push(bidder);
        }
    }

    function _requireActiveApplication() internal view returns (uint256 appId) {
        appId = activeApplicationId;
        if (appId == 0) revert AuctionNotLive();

        AuctionApplication storage app = _applications[appId];
        if (app.status != ApplicationStatus.Live) revert AuctionNotLive();
    }

    function _requireLiveApplication() internal view returns (uint256 appId) {
        appId = _requireActiveApplication();

        // Additional guard: start time must be configured.
        if (_applications[appId].startTime == 0) revert AuctionNotLive();
    }

    function _requireEpochInCommitPhase(uint256 appId, uint256 epochId) internal view {
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        if (epochId != currentEpoch()) revert CommitWindowClosed();
        if (getEpochPhase(epochId) != Phase.Commit) revert CommitWindowClosed();
    }

    function _requireEpochInRevealPhase(uint256 appId, uint256 epochId) internal view {
        AuctionApplication storage app = _applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        if (epochId != currentEpoch()) revert RevealWindowClosed();
        if (getEpochPhase(epochId) != Phase.Reveal) revert RevealWindowClosed();
    }

    function _requireApplication(uint256 applicationId) internal view returns (AuctionApplication storage app) {
        app = _applications[applicationId];
        if (app.id == 0) revert InvalidApplication();
    }

    function _requireConfigurableStatus(ApplicationStatus status) internal pure {
        if (
            status != ApplicationStatus.Draft &&
            status != ApplicationStatus.Submitted &&
            status != ApplicationStatus.Approved
        ) {
            revert InvalidApplicationStatus();
        }
    }

    function _isApplicationEpochConfigured(uint256 applicationId) internal view returns (bool) {
        AuctionApplication storage app = _applications[applicationId];
        if (app.id == 0) return false;

        for (uint256 i = 1; i <= app.totalEpochs; i++) {
            EpochConfig storage cfg = _epochConfigs[applicationId][i];
            if (cfg.pricePerTokenWei == 0 || cfg.supplyTokens == 0) {
                return false;
            }
        }

        return true;
    }
}
