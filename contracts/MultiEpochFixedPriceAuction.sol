// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MultiEpochFixedPriceAuction {
    uint256 public constant TOKEN_SCALE = 1e18;
    uint256 public constant BPS = 10_000;
    uint16 public constant MIN_TIP_BPS = 20; // 0.2%
    uint16 public constant MAX_TIP_BPS = 9_000; // 90%

    error NotOwner();
    error ContractPaused();
    error InvalidAddress();
    error InvalidConfig();
    error InvalidEpoch();
    error ListingNotActive();
    error AttestationNotVerified();
    error EpochNotOpen();
    error EpochNotFinished();
    error EpochAlreadyFinalized();
    error EpochNotFinalized();
    error OrderAlreadyPlaced();
    error InvalidQuantity();
    error InvalidTipBps();
    error IncorrectPayment(uint256 requiredAmount, uint256 providedAmount);
    error NothingToClaim();
    error NothingToWithdraw();
    error RefundAlreadyWithdrawn();
    error TokensAlreadyClaimed();
    error TransferFailed();

    struct ListingMeta {
        uint256 agentId;
        address agentOwner;
        string ticker;
        string projectWebsite;
        string projectX;
        string agentURI;
        bytes32 attestationHash;
        bool attestationVerified;
        uint64 attestationVerifiedAt;
        bool active;
    }

    struct Order {
        bool placed;
        uint256 quantity;
        uint16 tipBps;
        uint256 collateral;
        uint256 paymentMax;
        uint256 tipMax;

        uint256 allocatedQuantity;
        uint256 paymentDue;
        uint256 tipPaid;
        uint256 refundDue;

        bool settled;
        bool refunded;
        bool claimed;
    }

    struct EpochResult {
        uint256 pricePerToken;
        uint256 tokensSold;
        uint256 totalPayment;
        uint256 totalTip;
        bool finalized;
    }

    IERC20 public immutable saleToken;

    address public owner;
    address public treasury;

    uint256 public immutable auctionStartTime;
    uint256 public immutable totalEpochs;
    uint256 public immutable epochDuration;
    uint256 public immutable tokensPerEpoch;
    uint256 public immutable maxQuantityPerOrder;
    uint256 public immutable initialPricePerToken;
    uint16 public immutable priceDecayBps;

    bool public paused;

    ListingMeta public listing;

    mapping(uint256 => uint256) private _epochPriceOverride;
    mapping(uint256 => EpochResult) private _epochResults;
    mapping(uint256 => mapping(address => Order)) private _orders;
    mapping(uint256 => address[]) private _epochParticipants;

    uint256 public treasuryAccrued;
    uint256 public saleProceedsAccrued;
    uint256 public tipsAccrued;

    uint256 private _lockState = 1;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PauseStateChanged(bool paused);
    event TreasuryUpdated(address indexed treasury);

    event ListingConfigured(uint256 indexed agentId, address indexed agentOwner, bytes32 attestationHash);
    event ListingActivationChanged(bool active);
    event AttestationVerificationUpdated(bool verified, uint64 verifiedAt);

    event EpochPriceOverrideSet(uint256 indexed epochId, uint256 pricePerToken);

    event OrderPlaced(
        uint256 indexed epochId,
        address indexed bidder,
        uint256 quantity,
        uint256 pricePerToken,
        uint16 tipBps,
        uint256 paymentMax,
        uint256 tipMax,
        uint256 collateral
    );

    event EpochFinalized(
        uint256 indexed epochId,
        uint256 pricePerToken,
        uint256 tokensSold,
        uint256 totalPayment,
        uint256 totalTip
    );

    event TokensClaimed(address indexed bidder, uint256 amount);
    event RefundWithdrawn(uint256 indexed epochId, address indexed bidder, uint256 amount);
    event TreasuryWithdrawn(address indexed to, uint256 amount);
    event UnsoldTokensRecovered(address indexed to, uint256 amount);

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

    constructor(
        address saleToken_,
        address treasury_,
        uint256 auctionStartTime_,
        uint256 totalEpochs_,
        uint256 epochDuration_,
        uint256 tokensPerEpoch_,
        uint256 maxQuantityPerOrder_,
        uint256 initialPricePerToken_,
        uint16 priceDecayBps_
    ) {
        if (saleToken_ == address(0) || treasury_ == address(0)) revert InvalidAddress();
        if (
            totalEpochs_ == 0 ||
            epochDuration_ == 0 ||
            tokensPerEpoch_ == 0 ||
            maxQuantityPerOrder_ == 0 ||
            initialPricePerToken_ == 0 ||
            priceDecayBps_ > BPS
        ) {
            revert InvalidConfig();
        }

        saleToken = IERC20(saleToken_);
        treasury = treasury_;

        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        auctionStartTime = auctionStartTime_;
        totalEpochs = totalEpochs_;
        epochDuration = epochDuration_;

        tokensPerEpoch = tokensPerEpoch_;
        maxQuantityPerOrder = maxQuantityPerOrder_;
        initialPricePerToken = initialPricePerToken_;
        priceDecayBps = priceDecayBps_;
    }

    receive() external payable {}

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

    function configureListing(
        uint256 agentId,
        address agentOwner,
        string calldata ticker,
        string calldata projectWebsite,
        string calldata projectX,
        string calldata agentURI,
        bytes32 attestationHash
    ) external onlyOwner {
        if (agentId == 0 || agentOwner == address(0)) revert InvalidConfig();

        listing.agentId = agentId;
        listing.agentOwner = agentOwner;
        listing.ticker = ticker;
        listing.projectWebsite = projectWebsite;
        listing.projectX = projectX;
        listing.agentURI = agentURI;
        listing.attestationHash = attestationHash;
        listing.active = false;

        emit ListingConfigured(agentId, agentOwner, attestationHash);
    }

    function setAttestationVerification(bool verified, uint64 verifiedAt) external onlyOwner {
        listing.attestationVerified = verified;
        listing.attestationVerifiedAt = verifiedAt;

        emit AttestationVerificationUpdated(verified, verifiedAt);
    }

    function activateListing() external onlyOwner {
        if (listing.agentId == 0 || listing.agentOwner == address(0)) revert InvalidConfig();
        if (!listing.attestationVerified) revert AttestationNotVerified();

        listing.active = true;
        emit ListingActivationChanged(true);
    }

    function deactivateListing() external onlyOwner {
        listing.active = false;
        emit ListingActivationChanged(false);
    }

    function setEpochPriceOverride(uint256 epochId, uint256 pricePerToken) external onlyOwner {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        if (pricePerToken == 0) revert InvalidConfig();

        (uint256 startTime, ) = getEpochWindow(epochId);
        if (block.timestamp >= startTime) revert InvalidConfig();

        _epochPriceOverride[epochId] = pricePerToken;
        emit EpochPriceOverrideSet(epochId, pricePerToken);
    }

    function currentEpoch() public view returns (uint256) {
        if (block.timestamp < auctionStartTime) {
            return 1;
        }

        uint256 elapsed = block.timestamp - auctionStartTime;
        uint256 epochId = (elapsed / epochDuration) + 1;
        if (epochId > totalEpochs) {
            return totalEpochs;
        }

        return epochId;
    }

    function auctionEndTime() public view returns (uint256) {
        return auctionStartTime + totalEpochs * epochDuration;
    }

    function getEpochWindow(uint256 epochId) public view returns (uint256 startTime, uint256 endTime) {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        startTime = auctionStartTime + (epochId - 1) * epochDuration;
        endTime = startTime + epochDuration;
    }

    function isEpochOpen(uint256 epochId) public view returns (bool) {
        (uint256 startTime, uint256 endTime) = getEpochWindow(epochId);
        return block.timestamp >= startTime && block.timestamp < endTime;
    }

    function epochPriceFor(uint256 epochId) public view returns (uint256) {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();

        uint256 overridePrice = _epochPriceOverride[epochId];
        if (overridePrice != 0) {
            return overridePrice;
        }

        if (epochId == 1) {
            return initialPricePerToken;
        }

        uint256 discount = uint256(priceDecayBps) * (epochId - 1);
        if (discount >= BPS) {
            return 1;
        }

        uint256 price = (initialPricePerToken * (BPS - discount)) / BPS;
        return price == 0 ? 1 : price;
    }

    function placeOrder(uint256 epochId, uint256 quantity, uint16 tipBps)
        external
        payable
        whenNotPaused
    {
        if (!listing.active) revert ListingNotActive();
        if (!listing.attestationVerified) revert AttestationNotVerified();
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        if (!isEpochOpen(epochId)) revert EpochNotOpen();
        if (quantity == 0 || quantity > maxQuantityPerOrder) revert InvalidQuantity();
        if (tipBps < MIN_TIP_BPS || tipBps > MAX_TIP_BPS) revert InvalidTipBps();

        Order storage order = _orders[epochId][msg.sender];
        if (order.placed) revert OrderAlreadyPlaced();

        uint256 pricePerToken = epochPriceFor(epochId);
        uint256 paymentMax = _quotePayment(quantity, pricePerToken);
        uint256 tipMax = (paymentMax * tipBps) / BPS;
        uint256 required = paymentMax + tipMax;

        if (msg.value != required) {
            revert IncorrectPayment(required, msg.value);
        }

        order.placed = true;
        order.quantity = quantity;
        order.tipBps = tipBps;
        order.collateral = msg.value;
        order.paymentMax = paymentMax;
        order.tipMax = tipMax;

        _epochParticipants[epochId].push(msg.sender);

        emit OrderPlaced(epochId, msg.sender, quantity, pricePerToken, tipBps, paymentMax, tipMax, msg.value);
    }

    function finalizeEpoch(uint256 epochId) external whenNotPaused {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();

        EpochResult storage result = _epochResults[epochId];
        if (result.finalized) revert EpochAlreadyFinalized();

        (, uint256 endTime) = getEpochWindow(epochId);
        if (block.timestamp < endTime) revert EpochNotFinished();

        uint256 pricePerToken = epochPriceFor(epochId);
        address[] memory ranked = _rankByTip(epochId);

        uint256 remaining = tokensPerEpoch;
        uint256 totalPayment;
        uint256 totalTip;

        for (uint256 i = 0; i < ranked.length; i++) {
            address bidder = ranked[i];
            Order storage order = _orders[epochId][bidder];

            uint256 allocation;
            if (remaining > 0) {
                allocation = order.quantity;
                if (allocation > remaining) {
                    allocation = remaining;
                }
            }

            uint256 paymentDue;
            uint256 tipPaid;
            if (allocation > 0) {
                paymentDue = _quotePayment(allocation, pricePerToken);
                tipPaid = (paymentDue * order.tipBps) / BPS;
                remaining -= allocation;
            }

            uint256 refundDue = order.collateral - paymentDue - tipPaid;

            order.allocatedQuantity = allocation;
            order.paymentDue = paymentDue;
            order.tipPaid = tipPaid;
            order.refundDue = refundDue;
            order.settled = true;

            totalPayment += paymentDue;
            totalTip += tipPaid;
        }

        uint256 sold = tokensPerEpoch - remaining;

        result.finalized = true;
        result.pricePerToken = pricePerToken;
        result.tokensSold = sold;
        result.totalPayment = totalPayment;
        result.totalTip = totalTip;

        saleProceedsAccrued += totalPayment;
        tipsAccrued += totalTip;
        treasuryAccrued += totalPayment + totalTip;

        emit EpochFinalized(epochId, pricePerToken, sold, totalPayment, totalTip);
    }

    function claimTokens(uint256[] calldata epochIds) external nonReentrant {
        uint256 totalClaim;

        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 epochId = epochIds[i];
            if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
            if (!_epochResults[epochId].finalized) revert EpochNotFinalized();

            Order storage order = _orders[epochId][msg.sender];
            if (!order.placed || order.allocatedQuantity == 0) {
                continue;
            }
            if (order.claimed) revert TokensAlreadyClaimed();

            order.claimed = true;
            totalClaim += order.allocatedQuantity;
        }

        if (totalClaim == 0) revert NothingToClaim();

        bool ok = saleToken.transfer(msg.sender, totalClaim);
        if (!ok) revert TransferFailed();

        emit TokensClaimed(msg.sender, totalClaim);
    }

    function withdrawRefund(uint256 epochId) external nonReentrant {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        if (!_epochResults[epochId].finalized) revert EpochNotFinalized();

        Order storage order = _orders[epochId][msg.sender];
        if (order.refunded) revert RefundAlreadyWithdrawn();

        uint256 amount = order.refundDue;
        if (amount == 0) revert NothingToWithdraw();

        order.refunded = true;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit RefundWithdrawn(epochId, msg.sender, amount);
    }

    function withdrawTreasury(address payable to, uint256 amount)
        external
        onlyOwner
        nonReentrant
    {
        if (to == address(0)) revert InvalidAddress();
        if (amount == 0 || amount > treasuryAccrued) revert InvalidConfig();

        treasuryAccrued -= amount;
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();

        emit TreasuryWithdrawn(to, amount);
    }

    function recoverUnsoldTokens(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidAddress();
        if (block.timestamp < auctionEndTime()) revert EpochNotFinished();

        bool ok = saleToken.transfer(to, amount);
        if (!ok) revert TransferFailed();

        emit UnsoldTokensRecovered(to, amount);
    }

    function getOrder(address user, uint256 epochId)
        external
        view
        returns (Order memory)
    {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        return _orders[epochId][user];
    }

    function getEpochSummary(uint256 epochId)
        external
        view
        returns (EpochResult memory)
    {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        return _epochResults[epochId];
    }

    function getEpochParticipants(uint256 epochId) external view returns (address[] memory) {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        return _epochParticipants[epochId];
    }

    function _rankByTip(uint256 epochId) internal view returns (address[] memory ranked) {
        address[] storage source = _epochParticipants[epochId];
        ranked = new address[](source.length);

        for (uint256 i = 0; i < source.length; i++) {
            address candidate = source[i];
            Order storage candidateOrder = _orders[epochId][candidate];

            uint256 j = i;
            while (j > 0) {
                address prior = ranked[j - 1];
                Order storage priorOrder = _orders[epochId][prior];

                bool keepPriorAhead =
                    priorOrder.tipBps > candidateOrder.tipBps ||
                    (
                        priorOrder.tipBps == candidateOrder.tipBps &&
                        priorOrder.tipMax >= candidateOrder.tipMax
                    );

                if (keepPriorAhead) {
                    break;
                }

                ranked[j] = prior;
                unchecked {
                    j--;
                }
            }

            ranked[j] = candidate;
        }
    }

    function _quotePayment(uint256 quantity, uint256 pricePerToken)
        internal
        pure
        returns (uint256)
    {
        return (quantity * pricePerToken) / TOKEN_SCALE;
    }
}
