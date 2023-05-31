contract testcontract is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    uint256 public developerFee = 500; // 500 : 5 %. 10000 : 100 %
    uint256 public referrerReward = 300; // 300 : 3 %. 10000 : 100 %
    uint256 public rewardPeriod = 1 days;
    uint256 public withdrawPeriod = 60 * 60 * 24 * 30; // 30 days
    uint256 public apr = 50; // 50 : 0.5 %. 10000 : 100 %
    uint256 public percentRate = 10000;
    address private devWallet;
    address public BUSDContract;
    uint256 public _currentDepositID = 0;

    uint256 public totalInvestors = 0;
    uint256 public totalReward = 0;
    uint256 public totalInvested = 0;

    bool public launched = false;

    address private signer;

    struct DepositStruct {
        address investor;
        uint256 depositAmount;
        uint256 depositAt; // deposit timestamp
        uint256 claimedAmount; // claimed busd amount
        uint256 rewardAmount; // total rewards earned at the time of deposit
        bool state; // withdraw capital state. false if withdraw capital
        bool claimed;
    }

    struct InvestorStruct {
        address investor;
        address referrer;
        uint256 totalLocked;
        uint256 startTime;
        uint256 lastCalculationDate;
        uint256 claimableAmount;
        uint256 claimedAmount;
        uint256 referAmount;
        uint256 finishedAmount;
        uint256 rewards; // total rewards earned by the investor
    }

    event Deposit(uint256 id, address investor);

    // mapping from deposit ID to DepositStruct
    mapping(uint256 => DepositStruct) public depositState;

    // mapping from investor to deposit IDs
    mapping(address => uint256[]) public ownedDeposits;
    // mapping from address to investor
    mapping(address => InvestorStruct) public investors;
    // mapping from deposit ID to bool
    mapping(uint256 => bool) public signedIds;

    constructor(address _signer, address _devWallet, address _busdContract) {
        require(_devWallet != address(0), "Please provide a valid dev wallet address");
        require(_busdContract != address(0), "Please provide a valid busd contract address");
        require(_signer != address(0), "Please provide signer");
        signer = _signer;
        devWallet = _devWallet;
        BUSDContract = _busdContract;
    }

    function launchContract() public onlyOwner {
        launched = true;
    }

    function resetContract(address _devWallet) public onlyOwner {
        require(_devWallet != address(0), "Please provide a valid dev wallet address");
        devWallet = _devWallet;
    }

    function setSigner(address _signer) public onlyOwner {
        require(_signer != address(0), "Please provide signer");
        signer = _signer;
    }

    function _getNextDepositID() private view returns (uint256) {
        return _currentDepositID.add(1);
    }

    function _incrementDepositID() private {
        _currentDepositID++;
    }

    function adjustROI(uint256 _newApr) external onlyOwner {
        require(_newApr <= 10000, "Invalid APR value");
        apr = _newApr;
    }

    function deposit(uint256 _amount, address _referrer) external nonReentrant {
        require(launched, "Contract not launched");
        require(_amount > 0, "Deposit amount must be greater than 0");
        require(_amount <= IERC20(BUSDContract).balanceOf(msg.sender), "Insufficient BUSD balance");

        IERC20(BUSDContract).safeTransferFrom(msg.sender, address(this), _amount);

        uint256 devFee = _amount.mul(developerFee).div(percentRate);
        uint256 investorAmount = _amount.sub(devFee);

        if (investors[msg.sender].investor == address(0)) {
            // New investor
            totalInvestors++;
            investors[msg.sender] = InvestorStruct(
                msg.sender,
                _referrer,
                0,
                block.timestamp,
                block.timestamp,
                0,
                0,
                0,
                0,
                0
            );
        } else {
            // Existing investor
            InvestorStruct storage investor = investors[msg.sender];
            investor.claimableAmount = getAllClaimableReward(msg.sender);
            investor.claimedAmount = investor.claimedAmount.add(investor.claimableAmount);
            investor.totalLocked = investor.totalLocked.sub(investor.claimableAmount);
            investor.lastCalculationDate = block.timestamp;
            investor.rewards = investor.rewards.add(investor.claimableAmount);
            investor.claimableAmount = 0;
        }

        depositState[_currentDepositID] = DepositStruct(
            msg.sender,
            investorAmount,
            block.timestamp,
            0,
            investors[msg.sender].rewards,
            true,
            false
        );
        ownedDeposits[msg.sender].push(_currentDepositID);

        totalInvested = totalInvested.add(investorAmount);
        totalReward = totalReward.add(devFee);
        investors[msg.sender].totalLocked = investors[msg.sender].totalLocked.add(investorAmount);

        emit Deposit(_currentDepositID, msg.sender);

        _incrementDepositID();

        IERC20(BUSDContract).safeTransfer(devWallet, devFee);
    }

    function claimAllReward() external nonReentrant {
        require(launched, "Contract not launched");

        InvestorStruct storage investor = investors[msg.sender];
        require(investor.investor != address(0), "You are not an investor");

        uint256 claimableAmount = getAllClaimableReward(msg.sender);
        require(claimableAmount > 0, "No claimable reward");

        investor.claimableAmount = 0;
        investor.claimedAmount = investor.claimedAmount.add(claimableAmount);
        investor.totalLocked = investor.totalLocked.sub(claimableAmount);
        investor.lastCalculationDate = block.timestamp;
        investor.rewards = investor.rewards.add(claimableAmount);

        IERC20(BUSDContract).safeTransfer(msg.sender, claimableAmount);
    }

    function withdrawCapital() external nonReentrant {
        require(launched, "Contract not launched");

        InvestorStruct storage investor = investors[msg.sender];
        require(investor.investor != address(0), "You are not an investor");
        require(investor.totalLocked > 0, "No locked capital");

        require(
            block.timestamp > investor.startTime.add(withdrawPeriod),
            "You can only withdraw capital after the lock period"
        );

        uint256 capitalAmount = investor.totalLocked;
        uint256 claimableAmount = getAllClaimableReward(msg.sender);

        investor.claimableAmount = 0;
        investor.claimedAmount = investor.claimedAmount.add(claimableAmount);
        investor.totalLocked = 0;
        investor.lastCalculationDate = block.timestamp;
        investor.finishedAmount = investor.finishedAmount.add(capitalAmount);
        investor.rewards = investor.rewards.add(claimableAmount);

        uint256 amountToSend = capitalAmount.add(claimableAmount);
        IERC20(BUSDContract).safeTransfer(msg.sender, amountToSend);
    }

    function getAllClaimableReward(address _investor) public view returns (uint256) {
        InvestorStruct storage investor = investors[_investor];
        require(investor.investor != address(0), "You are not an investor");

        uint256 claimableAmount = 0;

        uint256 depositCount = ownedDeposits[_investor].length;
        for (uint256 i = 0; i < depositCount; i++) {
            DepositStruct storage deposit = depositState[ownedDeposits[_investor][i]];
            if (!deposit.claimed && deposit.state) {
                uint256 rewardDuration = block.timestamp.sub(deposit.depositAt);
                uint256 calculatedReward = deposit.depositAmount.mul(rewardDuration).mul(apr).div(
                    percentRate.mul(rewardPeriod)
                );
                claimableAmount = claimableAmount.add(calculatedReward.sub(deposit.claimedAmount));
            }
        }

        return claimableAmount;
    }

    function getDepositCount(address _investor) external view returns (uint256) {
        return ownedDeposits[_investor].length;
    }

    function getDepositInfo(address _investor, uint256 _depositID)
        external
        view
        returns (
            uint256,
            uint256,
            uint256,
            uint256,
            bool,
            bool
        )
    {
        DepositStruct storage deposit = depositState[_depositID];
        require(deposit.investor == _investor, "Deposit not found");

        return (
            deposit.depositAmount,
            deposit.depositAt,
            deposit.claimedAmount,
            deposit.rewardAmount,
            deposit.state,
            deposit.claimed
        );
    }

    function getInvestorInfo(address _investor)
        external
        view
        returns (
            address,
            address,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256,
            uint256
        )
    {
        InvestorStruct storage investor = investors[_investor];
        require(investor.investor == _investor, "Investor not found");

        return (
            investor.investor,
            investor.referrer,
            investor.totalLocked,
            investor.startTime,
            investor.lastCalculationDate,
            investor.claimableAmount,
            investor.claimedAmount,
            investor.referAmount,
            investor.finishedAmount
        );
    }
}
