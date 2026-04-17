// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20Like {
    function transfer(address to, uint256 amount) external returns (bool);
}

contract MultiEpochAuctionApplicationMVP {
    uint256 public constant BPS = 10_000;
    uint256 public constant TOKEN_DECIMALS_SCALE = 1e18;

    uint256 public constant DEFAULT_TOTAL_EPOCHS = 20;
    uint256 public constant DEFAULT_EPOCH_DURATION = 180;
    uint256 public constant DEFAULT_COMMIT_DURATION = 120;
    uint256 public constant DEFAULT_REVEAL_DURATION = 60;

    error Unauthorized();
    error ContractPaused();
    error InvalidAddress();
    error InvalidConfig();
    error InvalidStatus();
    error InvalidApplication();
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
    error IncorrectPayment(uint256 requiredAmount, uint256 providedAmount);
    error PriceBelowEpochPrice(uint256 bidPrice, uint256 epochPrice);
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
        string rejectReason;
        ApplicationStatus status;
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

    mapping(uint256 => AuctionApplication) private applications;
    mapping(uint256 => mapping(uint256 => EpochConfig)) private epochConfigs;
    mapping(uint256 => mapping(uint256 => EpochRuntime)) private epochRuntime;
    mapping(uint256 => mapping(uint256 => mapping(address => Bid))) private bids;
    mapping(uint256 => mapping(uint256 => address[])) private epochParticipants;
    mapping(uint256 => mapping(uint256 => mapping(address => bool))) private isEpochParticipant;

    uint256 private lockState = 1;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PauseStateChanged(bool paused);
    event TreasuryUpdated(address indexed newTreasury);

    event AuctionApplicationCreated(uint256 indexed applicationId, address indexed applicant, string metadataURI);
    event AuctionApplicationStatusChanged(uint256 indexed applicationId, ApplicationStatus status);
    event AuctionApplicationRejected(uint256 indexed applicationId, string reason);

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

    event TokensClaimed(address indexed bidder, uint256 tokenUnits);
    event RefundWithdrawn(uint256 indexed applicationId, uint256 indexed epochId, address indexed bidder, uint256 amountWei);
    event TreasuryWithdrawn(address indexed to, uint256 amountWei);
    event UnsoldTokensRecovered(address indexed to, uint256 tokenUnits);

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert ContractPaused();
        _;
    }

    modifier nonReentrant() {
        if (lockState != 1) revert TransferFailed();
        lockState = 2;
        _;
        lockState = 1;
    }

    constructor(address saleToken_, address treasury_) {
        if (saleToken_ == address(0) || treasury_ == address(0)) revert InvalidAddress();
        saleToken = IERC20Like(saleToken_);
        owner = msg.sender;
        treasury = treasury_;
        emit OwnershipTransferred(address(0), msg.sender);
    }

    receive() external payable {}

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        address prev = owner;
        owner = newOwner;
        emit OwnershipTransferred(prev, newOwner);
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
            maxQuantityPerBid_ == 0 ||
            normalizedCommitDuration + normalizedRevealDuration > normalizedEpochDuration
        ) revert InvalidConfig();

        applicationId = nextApplicationId++;
        applications[applicationId] = AuctionApplication({
            id: applicationId,
            applicant: applicant,
            metadataURI: metadataURI,
            rejectReason: "",
            status: ApplicationStatus.Draft,
            startTime: 0,
            totalEpochs: normalizedTotalEpochs,
            epochDuration: normalizedEpochDuration,
            commitDuration: normalizedCommitDuration,
            revealDuration: normalizedRevealDuration,
            maxQuantityPerBid: maxQuantityPerBid_
        });

        emit AuctionApplicationCreated(applicationId, applicant, metadataURI);
    }

    function submitAuctionApplication(uint256 applicationId) external onlyOwner {
        AuctionApplication storage app = _application(applicationId);
        if (app.status != ApplicationStatus.Draft) revert InvalidStatus();
        app.status = ApplicationStatus.Submitted;
        emit AuctionApplicationStatusChanged(applicationId, app.status);
    }

    function approveAuctionApplication(uint256 applicationId) external onlyOwner {
        AuctionApplication storage app = _application(applicationId);
        if (app.status != ApplicationStatus.Submitted) revert InvalidStatus();
        if (!_isApplicationEpochConfigured(applicationId)) revert InvalidConfig();
        app.status = ApplicationStatus.Approved;
        emit AuctionApplicationStatusChanged(applicationId, app.status);
    }

    function rejectAuctionApplication(uint256 applicationId, string calldata reason) external onlyOwner {
        AuctionApplication storage app = _application(applicationId);
        if (app.status != ApplicationStatus.Submitted && app.status != ApplicationStatus.Approved) revert InvalidStatus();
        app.status = ApplicationStatus.Rejected;
        app.rejectReason = reason;
        emit AuctionApplicationRejected(applicationId, reason);
        emit AuctionApplicationStatusChanged(applicationId, app.status);
    }

    function launchAuctionApplication(uint256 applicationId, uint256 startTime) external onlyOwner {
        AuctionApplication storage app = _application(applicationId);
        if (app.status != ApplicationStatus.Approved) revert InvalidStatus();
        if (!_isApplicationEpochConfigured(applicationId)) revert InvalidConfig();

        if (activeApplicationId != 0 && applications[activeApplicationId].status == ApplicationStatus.Live) {
            revert InvalidStatus();
        }

        app.status = ApplicationStatus.Live;
        app.startTime = startTime;
        activeApplicationId = applicationId;
        emit AuctionApplicationStatusChanged(applicationId, app.status);
    }

    function closeAuctionApplication(uint256 applicationId) external onlyOwner {
        AuctionApplication storage app = _application(applicationId);
        if (app.status != ApplicationStatus.Live) revert InvalidStatus();
        app.status = ApplicationStatus.Closed;
        if (activeApplicationId == applicationId) activeApplicationId = 0;
        emit AuctionApplicationStatusChanged(applicationId, app.status);
    }

    function getApplication(uint256 applicationId) external view returns (AuctionApplication memory) {
        return _application(applicationId);
    }

    function applicationIsFullyConfigured(uint256 applicationId) external view returns (bool) {
        return _isApplicationEpochConfigured(applicationId);
    }

    function setEpochConfig(uint256 applicationId, uint256 epochId, uint256 pricePerTokenWei, uint256 supplyTokens) external onlyOwner {
        AuctionApplication storage app = _application(applicationId);
        _requireConfigurableStatus(app.status);
        if (epochId == 0 || epochId > app.totalEpochs || pricePerTokenWei == 0 || supplyTokens == 0) revert InvalidConfig();

        epochConfigs[applicationId][epochId] = EpochConfig(pricePerTokenWei, supplyTokens);
        emit EpochConfigSet(applicationId, epochId, pricePerTokenWei, supplyTokens);
    }

    function setEpochConfigs(uint256 applicationId, uint256[] calldata pricesPerTokenWei, uint256[] calldata supplyTokens) external onlyOwner {
        AuctionApplication storage app = _application(applicationId);
        _requireConfigurableStatus(app.status);
        if (pricesPerTokenWei.length != app.totalEpochs || supplyTokens.length != app.totalEpochs) revert InvalidConfig();

        for (uint256 i = 0; i < app.totalEpochs; i++) {
            if (pricesPerTokenWei[i] == 0 || supplyTokens[i] == 0) revert InvalidConfig();
            uint256 epochId = i + 1;
            epochConfigs[applicationId][epochId] = EpochConfig(pricesPerTokenWei[i], supplyTokens[i]);
            emit EpochConfigSet(applicationId, epochId, pricesPerTokenWei[i], supplyTokens[i]);
        }
    }

    function initializeEpochCurve(
        uint256 applicationId,
        uint256 firstEpochPriceWei,
        uint16 lastEpochPriceBps,
        uint256 totalSupplyTokens,
        uint16 lastEpochSupplyBps
    ) external onlyOwner {
        AuctionApplication storage app = _application(applicationId);
        _requireConfigurableStatus(app.status);
        if (
            firstEpochPriceWei == 0 ||
            totalSupplyTokens == 0 ||
            lastEpochPriceBps == 0 ||
            lastEpochPriceBps > BPS ||
            lastEpochSupplyBps > BPS
        ) revert InvalidConfig();

        uint256 n = app.totalEpochs;
        uint256 lastEpochPriceWei = (firstEpochPriceWei * lastEpochPriceBps) / BPS;
        if (lastEpochPriceWei == 0) revert InvalidConfig();

        if (n == 1) {
            epochConfigs[applicationId][1] = EpochConfig(firstEpochPriceWei, totalSupplyTokens);
            emit EpochConfigSet(applicationId, 1, firstEpochPriceWei, totalSupplyTokens);
            emit EpochCurveInitialized(applicationId, firstEpochPriceWei, lastEpochPriceBps, totalSupplyTokens, lastEpochSupplyBps);
            return;
        }

        uint256 lastSupply = (totalSupplyTokens * lastEpochSupplyBps) / BPS;
        uint256 frontSupply = totalSupplyTokens - lastSupply;

        uint256 frontEpochs = n - 1;
        uint256 weightSum = (frontEpochs * (frontEpochs + 1)) / 2;
        uint256 assigned;

        for (uint256 i = 1; i <= n; i++) {
            uint256 price = firstEpochPriceWei - ((firstEpochPriceWei - lastEpochPriceWei) * (i - 1)) / (n - 1);
            uint256 supply;
            if (i == n) {
                supply = lastSupply;
            } else {
                uint256 weight = n - i;
                supply = weightSum == 0 ? frontSupply : (frontSupply * weight) / weightSum;
                assigned += supply;
            }

            epochConfigs[applicationId][i] = EpochConfig(price, supply);
            emit EpochConfigSet(applicationId, i, price, supply);
        }

        if (assigned < frontSupply) {
            EpochConfig storage cfg = epochConfigs[applicationId][1];
            cfg.supplyTokens += (frontSupply - assigned);
            emit EpochConfigSet(applicationId, 1, cfg.pricePerTokenWei, cfg.supplyTokens);
        }

        emit EpochCurveInitialized(applicationId, firstEpochPriceWei, lastEpochPriceBps, totalSupplyTokens, lastEpochSupplyBps);
    }

    function epochConfigFor(uint256 applicationId, uint256 epochId) external view returns (EpochConfig memory) {
        AuctionApplication storage app = _application(applicationId);
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        return epochConfigs[applicationId][epochId];
    }

    function auctionStartTime() public view returns (uint256) {
        if (activeApplicationId == 0) return 0;
        return applications[activeApplicationId].startTime;
    }

    function totalEpochs() public view returns (uint256) {
        if (activeApplicationId == 0) return DEFAULT_TOTAL_EPOCHS;
        return applications[activeApplicationId].totalEpochs;
    }

    function epochDuration() public view returns (uint256) {
        if (activeApplicationId == 0) return DEFAULT_EPOCH_DURATION;
        return applications[activeApplicationId].epochDuration;
    }

    function commitDuration() public view returns (uint256) {
        if (activeApplicationId == 0) return DEFAULT_COMMIT_DURATION;
        return applications[activeApplicationId].commitDuration;
    }

    function revealDuration() public view returns (uint256) {
        if (activeApplicationId == 0) return DEFAULT_REVEAL_DURATION;
        return applications[activeApplicationId].revealDuration;
    }

    function maxQuantityPerBid() public view returns (uint256) {
        if (activeApplicationId == 0) return 0;
        return applications[activeApplicationId].maxQuantityPerBid;
    }

    function currentEpoch() public view returns (uint256) {
        if (activeApplicationId == 0) return 1;
        AuctionApplication storage app = applications[activeApplicationId];
        if (app.startTime == 0 || block.timestamp < app.startTime) return 1;

        uint256 elapsed = block.timestamp - app.startTime;
        uint256 epochId = elapsed / app.epochDuration + 1;
        return epochId > app.totalEpochs ? app.totalEpochs : epochId;
    }

    function getEpochWindows(uint256 epochId) public view returns (uint256 startTime, uint256 commitEnd, uint256 revealEnd) {
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        startTime = app.startTime + (epochId - 1) * app.epochDuration;
        commitEnd = startTime + app.commitDuration;
        revealEnd = commitEnd + app.revealDuration;
    }

    function getEpochPhase(uint256 epochId) public view returns (Phase) {
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        if (app.status != ApplicationStatus.Live) return Phase.Closed;

        (uint256 startTime, uint256 commitEnd, uint256 revealEnd) = getEpochWindows(epochId);
        if (block.timestamp < startTime) return Phase.Closed;
        if (block.timestamp < commitEnd) return Phase.Commit;
        if (block.timestamp < revealEnd) return Phase.Reveal;
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
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        return epochConfigs[appId][epochId].pricePerTokenWei;
    }

    function previousWinningPrice() external view returns (uint256) {
        if (activeApplicationId == 0) return 0;
        uint256 epochId = currentEpoch();
        if (epochId <= 1) return 0;

        uint256 appId = activeApplicationId;
        if (!epochRuntime[appId][epochId - 1].finalized) return 0;
        return epochConfigs[appId][epochId - 1].pricePerTokenWei;
    }

    function tokensPerEpoch() external view returns (uint256) {
        if (activeApplicationId == 0) return 0;
        return epochConfigs[activeApplicationId][currentEpoch()].supplyTokens;
    }

    function getEpochRemainingTokens(uint256 epochId) public view returns (uint256) {
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        EpochConfig storage cfg = epochConfigs[appId][epochId];
        EpochRuntime storage rt = epochRuntime[appId][epochId];
        return rt.tokensSold >= cfg.supplyTokens ? 0 : cfg.supplyTokens - rt.tokensSold;
    }

    function currentEpochRemainingTokens() external view returns (uint256) {
        return getEpochRemainingTokens(currentEpoch());
    }

    function getCurrentEpochState() external view returns (uint256 epochId, Phase phase, uint256 remainingTokens) {
        if (activeApplicationId == 0) return (1, Phase.Closed, 0);
        epochId = currentEpoch();
        phase = getEpochPhase(epochId);
        remainingTokens = getEpochRemainingTokens(epochId);
    }

    function getEpochSummary(uint256 epochId) external view returns (uint256 winningPrice, uint256 tokensSold, uint256 nextFloorPrice) {
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        winningPrice = epochConfigs[appId][epochId].pricePerTokenWei;
        tokensSold = epochRuntime[appId][epochId].tokensSold;
        nextFloorPrice = epochId < app.totalEpochs ? epochConfigs[appId][epochId + 1].pricePerTokenWei : 0;
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
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        EpochConfig storage cfg = epochConfigs[appId][epochId];
        EpochRuntime storage rt = epochRuntime[appId][epochId];

        pricePerTokenWei = cfg.pricePerTokenWei;
        supplyTokens = cfg.supplyTokens;
        soldTokens = rt.tokensSold;
        remainingTokens = rt.tokensSold >= cfg.supplyTokens ? 0 : cfg.supplyTokens - rt.tokensSold;
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
        uint256 appId = _liveApplicationId();
        if (epochId == 0 || epochId > applications[appId].totalEpochs) revert InvalidEpoch();

        Bid memory bid = bids[appId][epochId][user];
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

    function commitBid(uint256 epochId, bytes32 commitment) external payable whenNotPaused {
        uint256 appId = _liveApplicationId();
        _requireCommitWindow(appId, epochId);
        if (commitment == bytes32(0)) revert InvalidCommitment();
        if (msg.value == 0) revert IncorrectPayment(1, 0);

        Bid storage bid = bids[appId][epochId][msg.sender];
        if (bid.commitment != bytes32(0)) revert BidAlreadyCommitted();

        bid.commitment = commitment;
        bid.collateral = msg.value;
        _trackParticipant(appId, epochId, msg.sender);

        emit BidCommitted(appId, epochId, msg.sender, commitment, msg.value, true);
    }

    function commitBid(uint256 epochId, uint256 quantity, uint256 pricePerToken, bytes32 salt) external payable whenNotPaused {
        uint256 appId = _liveApplicationId();
        _requireCommitWindow(appId, epochId);

        Bid storage bid = bids[appId][epochId][msg.sender];
        if (bid.commitment != bytes32(0)) revert BidAlreadyCommitted();

        bytes32 commitment = keccak256(abi.encodePacked(epochId, msg.sender, quantity, pricePerToken, salt));
        bid.commitment = commitment;
        bid.collateral = msg.value;
        _trackParticipant(appId, epochId, msg.sender);
        _materializeBid(appId, epochId, msg.sender, quantity, pricePerToken);

        emit BidCommitted(appId, epochId, msg.sender, commitment, msg.value, false);
    }

    function revealBid(uint256 epochId, uint256 quantity, uint256 pricePerToken, bytes32 salt) external whenNotPaused {
        uint256 appId = _liveApplicationId();
        _requireRevealWindow(appId, epochId);

        Bid storage bid = bids[appId][epochId][msg.sender];
        if (bid.commitment == bytes32(0)) revert BidNotCommitted();
        if (bid.revealed) revert BidAlreadyRevealed();

        bytes32 digest = keccak256(abi.encodePacked(epochId, msg.sender, quantity, pricePerToken, salt));
        if (digest != bid.commitment) revert InvalidReveal();

        _materializeBid(appId, epochId, msg.sender, quantity, pricePerToken);
    }

    function finalizeEpoch(uint256 epochId) external whenNotPaused {
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();

        EpochRuntime storage rt = epochRuntime[appId][epochId];
        if (rt.finalized) revert EpochAlreadyFinalized();

        (, , uint256 revealEnd) = getEpochWindows(epochId);
        if (block.timestamp < revealEnd) revert EpochNotFinished();

        address[] storage participants = epochParticipants[appId][epochId];
        for (uint256 i = 0; i < participants.length; i++) {
            Bid storage bid = bids[appId][epochId][participants[i]];
            if (!bid.processed && bid.collateral > 0) {
                bid.refundDue = bid.collateral;
                bid.processed = true;
            }
        }

        rt.finalized = true;
        EpochConfig storage cfg = epochConfigs[appId][epochId];
        uint256 remaining = rt.tokensSold >= cfg.supplyTokens ? 0 : cfg.supplyTokens - rt.tokensSold;
        emit EpochFinalized(appId, epochId, cfg.pricePerTokenWei, cfg.supplyTokens, rt.tokensSold, remaining);
    }

    function claimTokens(uint256[] calldata epochIds) external nonReentrant {
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];

        uint256 wholeTokens;
        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 epochId = epochIds[i];
            if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
            if (!epochRuntime[appId][epochId].finalized) revert EpochNotFinalized();

            Bid storage bid = bids[appId][epochId][msg.sender];
            if (!bid.winner || bid.allocatedQuantity == 0) continue;
            if (bid.tokensClaimed) revert TokensAlreadyClaimed();

            bid.tokensClaimed = true;
            wholeTokens += bid.allocatedQuantity;
        }

        if (wholeTokens == 0) revert NothingToClaim();
        uint256 tokenUnits = wholeTokens * TOKEN_DECIMALS_SCALE;

        if (!saleToken.transfer(msg.sender, tokenUnits)) revert TransferFailed();
        emit TokensClaimed(msg.sender, tokenUnits);
    }

    function withdrawRefund(uint256 epochId) external nonReentrant {
        uint256 appId = _liveApplicationId();
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        if (!epochRuntime[appId][epochId].finalized) revert EpochNotFinalized();

        Bid storage bid = bids[appId][epochId][msg.sender];
        if (bid.refundWithdrawn) revert RefundAlreadyWithdrawn();
        if (bid.refundDue == 0) revert NothingToWithdraw();

        uint256 amount = bid.refundDue;
        bid.refundWithdrawn = true;

        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit RefundWithdrawn(appId, epochId, msg.sender, amount);
    }

    function withdrawTreasury(address payable to, uint256 amountWei) external onlyOwner nonReentrant {
        if (to == address(0)) revert InvalidAddress();
        if (amountWei == 0 || amountWei > treasuryAccrued) revert InvalidConfig();

        treasuryAccrued -= amountWei;
        (bool ok, ) = to.call{value: amountWei}("");
        if (!ok) revert TransferFailed();

        emit TreasuryWithdrawn(to, amountWei);
    }

    function recoverUnsoldTokens(address to, uint256 tokenUnits) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (!saleToken.transfer(to, tokenUnits)) revert TransferFailed();
        emit UnsoldTokensRecovered(to, tokenUnits);
    }

    function _materializeBid(uint256 appId, uint256 epochId, address bidder, uint256 quantity, uint256 bidPrice) internal {
        AuctionApplication storage app = applications[appId];
        if (quantity == 0 || quantity > app.maxQuantityPerBid) revert InvalidQuantity();

        EpochConfig storage cfg = epochConfigs[appId][epochId];
        if (cfg.pricePerTokenWei == 0 || cfg.supplyTokens == 0) revert InvalidConfig();
        if (bidPrice < cfg.pricePerTokenWei) revert PriceBelowEpochPrice(bidPrice, cfg.pricePerTokenWei);

        Bid storage bid = bids[appId][epochId][bidder];
        uint256 maxAffordable = bid.collateral / cfg.pricePerTokenWei;
        if (maxAffordable == 0) revert IncorrectPayment(cfg.pricePerTokenWei, bid.collateral);

        uint256 allocation = quantity;
        uint256 remaining = _remaining(appId, epochId);
        if (allocation > remaining) allocation = remaining;
        if (allocation > maxAffordable) allocation = maxAffordable;

        uint256 paymentDue = allocation * cfg.pricePerTokenWei;
        uint256 refundDue = bid.collateral - paymentDue;

        bid.quantity = quantity;
        bid.pricePerToken = bidPrice;
        bid.allocatedQuantity = allocation;
        bid.paymentDue = paymentDue;
        bid.refundDue = refundDue;
        bid.revealed = true;
        bid.winner = allocation > 0;
        bid.processed = true;

        epochRuntime[appId][epochId].tokensSold += allocation;
        epochRuntime[appId][epochId].totalPaymentWei += paymentDue;
        treasuryAccrued += paymentDue;

        emit BidRevealed(appId, epochId, bidder, quantity, bidPrice, allocation, paymentDue, refundDue);
    }

    function _remaining(uint256 appId, uint256 epochId) internal view returns (uint256) {
        EpochConfig storage cfg = epochConfigs[appId][epochId];
        EpochRuntime storage rt = epochRuntime[appId][epochId];
        return rt.tokensSold >= cfg.supplyTokens ? 0 : cfg.supplyTokens - rt.tokensSold;
    }

    function _trackParticipant(uint256 appId, uint256 epochId, address bidder) internal {
        if (isEpochParticipant[appId][epochId][bidder]) return;
        isEpochParticipant[appId][epochId][bidder] = true;
        epochParticipants[appId][epochId].push(bidder);
    }

    function _application(uint256 applicationId) internal view returns (AuctionApplication storage app) {
        app = applications[applicationId];
        if (app.id == 0) revert InvalidApplication();
    }

    function _liveApplicationId() internal view returns (uint256 appId) {
        appId = activeApplicationId;
        if (appId == 0 || applications[appId].status != ApplicationStatus.Live) revert AuctionNotLive();
    }

    function _requireCommitWindow(uint256 appId, uint256 epochId) internal view {
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        if (epochId != currentEpoch()) revert CommitWindowClosed();
        if (getEpochPhase(epochId) != Phase.Commit) revert CommitWindowClosed();
    }

    function _requireRevealWindow(uint256 appId, uint256 epochId) internal view {
        AuctionApplication storage app = applications[appId];
        if (epochId == 0 || epochId > app.totalEpochs) revert InvalidEpoch();
        if (epochId != currentEpoch()) revert RevealWindowClosed();
        if (getEpochPhase(epochId) != Phase.Reveal) revert RevealWindowClosed();
    }

    function _requireConfigurableStatus(ApplicationStatus status) internal pure {
        if (status != ApplicationStatus.Draft && status != ApplicationStatus.Submitted && status != ApplicationStatus.Approved) {
            revert InvalidStatus();
        }
    }

    function _isApplicationEpochConfigured(uint256 applicationId) internal view returns (bool) {
        AuctionApplication storage app = applications[applicationId];
        if (app.id == 0) return false;

        for (uint256 i = 1; i <= app.totalEpochs; i++) {
            EpochConfig storage cfg = epochConfigs[applicationId][i];
            if (cfg.pricePerTokenWei == 0 || cfg.supplyTokens == 0) return false;
        }
        return true;
    }
}
