// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract MultiEpochVickreyAuction {
    uint256 public constant TOKEN_SCALE = 1e18;

    error NotOwner();
    error ContractPaused();
    error InvalidAddress();
    error InvalidEpoch();
    error InvalidConfig();
    error CommitWindowClosed();
    error RevealWindowClosed();
    error BidAlreadyCommitted();
    error BidNotCommitted();
    error BidAlreadyRevealed();
    error InvalidCommitment();
    error InvalidReveal();
    error InvalidQuantity();
    error PriceBelowFloor(uint256 pricePerToken, uint256 floorPrice);
    error InsufficientCollateral(uint256 requiredAmount, uint256 providedAmount);
    error EpochNotFinished();
    error EpochAlreadyFinalized();
    error PreviousEpochNotFinalized(uint256 epochId);
    error EpochNotFinalized();
    error NothingToClaim();
    error NothingToWithdraw();
    error RefundAlreadyWithdrawn();
    error TokensAlreadyClaimed();
    error TransferFailed();

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
    }

    struct EpochResult {
        uint256 winningPrice;
        uint256 tokensSold;
        uint256 nextFloorPrice;
        uint256 revealedBidCount;
        bool finalized;
    }

    IERC20 public immutable saleToken;

    address public owner;
    address public treasury;

    uint256 public immutable auctionStartTime;
    uint256 public immutable totalEpochs;
    uint256 public immutable commitDuration;
    uint256 public immutable revealDuration;
    uint256 public immutable epochSpan;

    uint256 public immutable tokensPerEpoch;
    uint256 public immutable maxQuantityPerBid;
    uint256 public immutable initialFloorPrice;

    uint16 public penaltyBps;
    uint256 public treasuryAccrued;
    bool public paused;

    mapping(uint256 => uint256) private _epochFloorPrice;
    mapping(uint256 => EpochResult) private _epochResults;
    mapping(uint256 => mapping(address => Bid)) private _bids;

    mapping(uint256 => address[]) private _epochCommitters;
    mapping(uint256 => address[]) private _epochRevealed;

    uint256 private _lockState = 1;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PauseStateChanged(bool paused);
    event TreasuryUpdated(address indexed treasury);
    event PenaltyBpsUpdated(uint16 penaltyBps);

    event BidCommitted(uint256 indexed epochId, address indexed bidder, uint256 collateral, bytes32 commitment);
    event BidRevealed(
        uint256 indexed epochId,
        address indexed bidder,
        uint256 quantity,
        uint256 pricePerToken
    );
    event RevealMissed(uint256 indexed epochId, address indexed bidder, uint256 penaltyTaken);
    event EpochFinalized(
        uint256 indexed epochId,
        uint256 winningPrice,
        uint256 tokensSold,
        uint256 nextFloorPrice,
        uint256 revealedBidCount
    );

    event TokensClaimed(address indexed bidder, uint256 totalClaimed);
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
        uint256 commitDuration_,
        uint256 revealDuration_,
        uint256 tokensPerEpoch_,
        uint256 maxQuantityPerBid_,
        uint256 initialFloorPrice_,
        uint16 penaltyBps_
    ) {
        if (saleToken_ == address(0) || treasury_ == address(0)) revert InvalidAddress();
        if (
            totalEpochs_ == 0 ||
            commitDuration_ == 0 ||
            revealDuration_ == 0 ||
            tokensPerEpoch_ == 0 ||
            maxQuantityPerBid_ == 0 ||
            initialFloorPrice_ == 0 ||
            penaltyBps_ > 10_000
        ) {
            revert InvalidConfig();
        }

        saleToken = IERC20(saleToken_);
        treasury = treasury_;

        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        auctionStartTime = auctionStartTime_;
        totalEpochs = totalEpochs_;
        commitDuration = commitDuration_;
        revealDuration = revealDuration_;
        epochSpan = commitDuration_ + revealDuration_;

        tokensPerEpoch = tokensPerEpoch_;
        maxQuantityPerBid = maxQuantityPerBid_;
        initialFloorPrice = initialFloorPrice_;

        penaltyBps = penaltyBps_;
        _epochFloorPrice[1] = initialFloorPrice_;
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

    function setPenaltyBps(uint16 newPenaltyBps) external onlyOwner {
        if (newPenaltyBps > 10_000) revert InvalidConfig();
        penaltyBps = newPenaltyBps;
        emit PenaltyBpsUpdated(newPenaltyBps);
    }

    function pause() external onlyOwner {
        paused = true;
        emit PauseStateChanged(true);
    }

    function unpause() external onlyOwner {
        paused = false;
        emit PauseStateChanged(false);
    }

    function currentEpoch() public view returns (uint256) {
        if (block.timestamp < auctionStartTime) {
            return 1;
        }

        uint256 elapsed = block.timestamp - auctionStartTime;
        uint256 epochId = (elapsed / epochSpan) + 1;
        if (epochId > totalEpochs) {
            return totalEpochs;
        }

        return epochId;
    }

    function epochDuration() external view returns (uint256) {
        return epochSpan;
    }

    function getEpochWindows(uint256 epochId)
        public
        view
        returns (uint256 startTime, uint256 commitEnd, uint256 revealEnd)
    {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();

        startTime = auctionStartTime + ((epochId - 1) * epochSpan);
        commitEnd = startTime + commitDuration;
        revealEnd = commitEnd + revealDuration;
    }

    function isCommitPhase(uint256 epochId) public view returns (bool) {
        (uint256 startTime, uint256 commitEnd, ) = getEpochWindows(epochId);
        return block.timestamp >= startTime && block.timestamp < commitEnd;
    }

    function isRevealPhase(uint256 epochId) public view returns (bool) {
        (, uint256 commitEnd, uint256 revealEnd) = getEpochWindows(epochId);
        return block.timestamp >= commitEnd && block.timestamp < revealEnd;
    }

    function floorPrice() external view returns (uint256) {
        return floorPriceForEpoch(currentEpoch());
    }

    function floorPriceForEpoch(uint256 epochId) public view returns (uint256) {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();

        uint256 configured = _epochFloorPrice[epochId];
        if (configured != 0) {
            return configured;
        }

        if (epochId == 1) {
            return initialFloorPrice;
        }

        EpochResult storage prev = _epochResults[epochId - 1];
        if (!prev.finalized) {
            return 0;
        }

        uint256 derived = prev.winningPrice / 2;
        return derived == 0 ? 1 : derived;
    }

    function previousWinningPrice() external view returns (uint256) {
        uint256 epochId = currentEpoch();
        if (epochId <= 1) {
            return 0;
        }

        EpochResult storage prev = _epochResults[epochId - 1];
        if (!prev.finalized) {
            return 0;
        }

        return prev.winningPrice;
    }

    function getEpochSummary(uint256 epochId)
        external
        view
        returns (uint256 winningPrice, uint256 tokensSold, uint256 nextFloorPrice)
    {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();

        EpochResult storage result = _epochResults[epochId];
        winningPrice = result.winningPrice;
        tokensSold = result.tokensSold;
        nextFloorPrice = result.nextFloorPrice;
    }

    function getUserBid(address user, uint256 epochId)
        external
        view
        returns (
            bytes32 commitment,
            uint256 collateral,
            uint256 quantity,
            uint256 pricePerToken,
            uint256 allocatedQuantity,
            uint256 paymentDue,
            uint256 refundDue,
            bool revealed,
            bool winner,
            bool refundWithdrawn,
            bool tokensClaimed
        )
    {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();

        Bid storage bid = _bids[epochId][user];

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

    function commitBid(uint256 epochId, bytes32 commitment)
        external
        payable
        whenNotPaused
    {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        if (!isCommitPhase(epochId)) revert CommitWindowClosed();
        if (commitment == bytes32(0)) revert InvalidCommitment();

        if (epochId > 1 && !_epochResults[epochId - 1].finalized) {
            revert PreviousEpochNotFinalized(epochId - 1);
        }

        Bid storage bid = _bids[epochId][msg.sender];
        if (bid.commitment != bytes32(0)) revert BidAlreadyCommitted();
        if (msg.value == 0) revert InsufficientCollateral(1, 0);

        _materializeEpochFloor(epochId);

        bid.commitment = commitment;
        bid.collateral = msg.value;
        _epochCommitters[epochId].push(msg.sender);

        emit BidCommitted(epochId, msg.sender, msg.value, commitment);
    }

    function revealBid(
        uint256 epochId,
        uint256 quantity,
        uint256 pricePerToken,
        bytes32 salt
    ) external whenNotPaused {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        if (!isRevealPhase(epochId)) revert RevealWindowClosed();

        Bid storage bid = _bids[epochId][msg.sender];
        if (bid.commitment == bytes32(0)) revert BidNotCommitted();
        if (bid.revealed) revert BidAlreadyRevealed();
        if (quantity == 0 || quantity > maxQuantityPerBid) revert InvalidQuantity();

        uint256 floor = floorPriceForEpoch(epochId);
        if (floor == 0) revert PreviousEpochNotFinalized(epochId - 1);
        if (pricePerToken < floor) revert PriceBelowFloor(pricePerToken, floor);

        bytes32 digest = keccak256(abi.encodePacked(epochId, msg.sender, quantity, pricePerToken, salt));
        if (digest != bid.commitment) revert InvalidReveal();

        uint256 requiredCollateral = _quotePayment(quantity, pricePerToken);
        if (requiredCollateral > bid.collateral) {
            revert InsufficientCollateral(requiredCollateral, bid.collateral);
        }

        bid.revealed = true;
        bid.quantity = quantity;
        bid.pricePerToken = pricePerToken;

        _epochRevealed[epochId].push(msg.sender);

        emit BidRevealed(epochId, msg.sender, quantity, pricePerToken);
    }

    function finalizeEpoch(uint256 epochId)
        external
        whenNotPaused
    {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();

        EpochResult storage result = _epochResults[epochId];
        if (result.finalized) revert EpochAlreadyFinalized();

        (, , uint256 revealEnd) = getEpochWindows(epochId);
        if (block.timestamp < revealEnd) revert EpochNotFinished();

        if (epochId > 1 && !_epochResults[epochId - 1].finalized) {
            revert PreviousEpochNotFinalized(epochId - 1);
        }

        uint256 floor = _materializeEpochFloor(epochId);

        address[] memory ranked = _rankRevealedBids(epochId);
        uint256 remaining = tokensPerEpoch;
        uint256 highestLosing = 0;

        for (uint256 i = 0; i < ranked.length; i++) {
            address bidder = ranked[i];
            Bid storage bid = _bids[epochId][bidder];

            if (remaining == 0) {
                if (bid.pricePerToken > highestLosing) {
                    highestLosing = bid.pricePerToken;
                }
                continue;
            }

            uint256 allocation = bid.quantity;
            if (allocation > remaining) {
                allocation = remaining;
            }

            if (allocation > 0) {
                bid.winner = true;
                bid.allocatedQuantity = allocation;
                remaining -= allocation;
            }

            if (allocation < bid.quantity && bid.pricePerToken > highestLosing) {
                highestLosing = bid.pricePerToken;
            }
        }

        uint256 tokensSold = tokensPerEpoch - remaining;
        uint256 clearingPrice = floor;

        if (tokensSold > 0 && highestLosing > floor) {
            clearingPrice = highestLosing;
        }

        uint256 epochRevenue = 0;
        address[] storage committers = _epochCommitters[epochId];

        for (uint256 i = 0; i < committers.length; i++) {
            address bidder = committers[i];
            Bid storage bid = _bids[epochId][bidder];

            if (bid.revealed) {
                if (bid.winner && bid.allocatedQuantity > 0) {
                    uint256 payment = _quotePayment(bid.allocatedQuantity, clearingPrice);
                    bid.paymentDue = payment;
                    bid.refundDue = bid.collateral - payment;
                    epochRevenue += payment;
                } else {
                    bid.refundDue = bid.collateral;
                }
            } else {
                uint256 penalty = (bid.collateral * penaltyBps) / 10_000;
                bid.refundDue = bid.collateral - penalty;
                epochRevenue += penalty;
                emit RevealMissed(epochId, bidder, penalty);
            }
        }

        treasuryAccrued += epochRevenue;

        result.finalized = true;
        result.winningPrice = clearingPrice;
        result.tokensSold = tokensSold;
        result.revealedBidCount = ranked.length;

        if (epochId < totalEpochs) {
            uint256 nextFloor = clearingPrice / 2;
            if (nextFloor == 0) {
                nextFloor = 1;
            }
            result.nextFloorPrice = nextFloor;
            _epochFloorPrice[epochId + 1] = nextFloor;
        }

        emit EpochFinalized(
            epochId,
            result.winningPrice,
            result.tokensSold,
            result.nextFloorPrice,
            result.revealedBidCount
        );
    }

    function claimTokens(uint256[] calldata epochIds)
        external
        nonReentrant
    {
        uint256 totalClaim;

        for (uint256 i = 0; i < epochIds.length; i++) {
            uint256 epochId = epochIds[i];
            if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
            if (!_epochResults[epochId].finalized) revert EpochNotFinalized();

            Bid storage bid = _bids[epochId][msg.sender];
            if (!bid.winner || bid.allocatedQuantity == 0) {
                continue;
            }
            if (bid.tokensClaimed) {
                revert TokensAlreadyClaimed();
            }

            bid.tokensClaimed = true;
            totalClaim += bid.allocatedQuantity;
        }

        if (totalClaim == 0) revert NothingToClaim();

        bool ok = saleToken.transfer(msg.sender, totalClaim);
        if (!ok) revert TransferFailed();

        emit TokensClaimed(msg.sender, totalClaim);
    }

    function withdrawRefund(uint256 epochId)
        external
        nonReentrant
    {
        if (epochId == 0 || epochId > totalEpochs) revert InvalidEpoch();
        if (!_epochResults[epochId].finalized) revert EpochNotFinalized();

        Bid storage bid = _bids[epochId][msg.sender];

        if (bid.refundWithdrawn) revert RefundAlreadyWithdrawn();
        uint256 amount = bid.refundDue;
        if (amount == 0) revert NothingToWithdraw();

        bid.refundWithdrawn = true;

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

    function recoverUnsoldTokens(address to, uint256 amount)
        external
        onlyOwner
    {
        if (to == address(0)) revert InvalidAddress();

        (, , uint256 finalRevealEnd) = getEpochWindows(totalEpochs);
        if (block.timestamp < finalRevealEnd) revert EpochNotFinished();

        bool ok = saleToken.transfer(to, amount);
        if (!ok) revert TransferFailed();

        emit UnsoldTokensRecovered(to, amount);
    }

    function _materializeEpochFloor(uint256 epochId) internal returns (uint256) {
        uint256 configured = _epochFloorPrice[epochId];
        if (configured != 0) {
            return configured;
        }

        if (epochId == 1) {
            _epochFloorPrice[1] = initialFloorPrice;
            return initialFloorPrice;
        }

        EpochResult storage prev = _epochResults[epochId - 1];
        if (!prev.finalized) revert PreviousEpochNotFinalized(epochId - 1);

        uint256 nextFloor = prev.winningPrice / 2;
        if (nextFloor == 0) {
            nextFloor = 1;
        }
        _epochFloorPrice[epochId] = nextFloor;
        return nextFloor;
    }

    function _rankRevealedBids(uint256 epochId)
        internal
        view
        returns (address[] memory ranked)
    {
        address[] storage source = _epochRevealed[epochId];
        ranked = new address[](source.length);

        for (uint256 i = 0; i < source.length; i++) {
            address candidate = source[i];
            uint256 candidatePrice = _bids[epochId][candidate].pricePerToken;

            uint256 j = i;
            while (j > 0) {
                address prior = ranked[j - 1];
                if (_bids[epochId][prior].pricePerToken >= candidatePrice) {
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
