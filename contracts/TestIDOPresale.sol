// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

// import "./SafeMath.sol";
// import "./IERC20.sol";
import "./TestStaking.sol";
// import "./MemePad.sol";

interface IPancakeRouter01 {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    )
    external
    payable
    returns (
        uint256 amountToken,
        uint256 amountETH,
        uint256 liquidity
    );
}

contract TestIDOPresale {
    using SafeMath for uint256;

    IPancakeRouter01 private constant ammRouter =
    IPancakeRouter01(address(0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3));

    address payable internal testIDOFactoryAddress; // address that creates the presale contracts
    address payable public testIDODevAddress; // address where dev fees will be transferred to
    address public testIDOLiqLockAddress; // address where LP tokens will be locked

    address payable public presaleCreatorAddress; // address where percentage of invested wei will be transferred to
    address public unsoldTokensDumpAddress; // address where unsold tokens will be transferred to
    address public ammLPTokenBeneficiary;

    IERC20 public token; // token that will be sold
    IERC20 public platformToken; // Platform token
    TestStaking public stakingContract;

    mapping(address => uint256) public investments; // total wei invested per address
    mapping(address => bool) public whitelistedAddresses; // addresses eligible in presale
    mapping(address => bool) public claimed; // if true, it means investor already claimed the tokens or got a refund

    uint256 private testIDODevFeePercentage; // dev fee to support the development of TestIDO Investments
    uint256 private testIDOMinDevFeeInWei; // minimum fixed dev fee to support the development of TestIDO Investments
    uint256 public testIDOId; // used for fetching presale without referencing its address

    uint256 public totalInvestorsCount; // total investors count
    uint256 public presaleCreatorClaimWei; // wei to transfer to presale creator per investor claim
    uint256 public presaleCreatorClaimTime; // time when presale creator can collect funds raise
    uint256 public totalCollectedWei; // total wei collected
    uint256 public totalTokens; // total tokens to be sold
    uint256 public tokensLeft; // available tokens to be sold
    uint256 public tokenPriceInWei; // token presale wei price per 1 token
    uint256 public hardCapInWei; // maximum wei amount that can be invested in presale
    uint256 public softCapInWei; // minimum wei amount to invest in presale, if not met, invested wei will be returned
    uint256 public maxInvestInWei; // maximum wei amount that can be invested per wallet address
    uint256 public minInvestInWei; // minimum wei amount that can be invested per wallet address
    uint256 public openTime; // time when presale starts, investing is allowed
    uint256 public closeTime; // time when presale closes, investing is not allowed
    uint256 public ammListingPriceInWei; // token price when listed in Pancakeswap
    uint256 public ammLiquidityAddingTime; // time when adding of liquidity in pancakeswap starts, investors can claim their tokens afterwards
    uint256 public ammLPTokensLockDurationInDays; // how many days after the liquity is added the presale creator can unlock the LP tokens
    uint256 public ammLiquidityPercentageAllocation; // how many percentage of the total invested wei that will be added as liquidity

    uint256 private minStaked1;
    uint256 private minStaked2;
    uint256 private minStaked3;
    uint256 private minStaked4;

    uint256 private maxInvestUser1 = 1000000000000000000;
    uint256 private maxInvestUser2 = 2000000000000000000;
    uint256 private maxInvestUser3 = 3000000000000000000;
    uint256 private maxInvestUser4 = 5000000000000000000;

    bool public ammLiquidityAdded = false; // if true, liquidity is added in Pancakeswap and lp tokens are locked
    bool public onlyWhitelistedAddressesAllowed = false; // if true, only whitelisted addresses can invest
    bool public testIDODevFeesExempted = false; // if true, presale will be exempted from dev fees
    bool public presaleCancelled = false; // if true, investing will not be allowed, investors can withdraw, presale creator can withdraw their tokens

    bytes32 public saleTitle;
    bytes32 public linkTelegram;
    bytes32 public linkTwitter;
    bytes32 public linkDiscord;
    bytes32 public linkWebsite;

    string public bannerURL;

    constructor(address _testIDOFactoryAddress, address _testIDODevAddress) public {
        require(_testIDOFactoryAddress != address(0));
        require(_testIDODevAddress != address(0));

        testIDOFactoryAddress = payable(_testIDOFactoryAddress);
        testIDODevAddress = payable(_testIDODevAddress);
    }

    modifier onlyTestIDODev() {
        require(testIDOFactoryAddress == msg.sender || testIDODevAddress == msg.sender);
        _;
    }

    modifier onlyTestIDOFactory() {
        require(testIDOFactoryAddress == msg.sender);
        _;
    }

    modifier onlyPresaleCreatorOrTestIDOFactory() {
        require(
            presaleCreatorAddress == msg.sender || testIDOFactoryAddress == msg.sender,
            "Not presale creator or factory"
        );
        _;
    }

    modifier onlyPresaleCreator() {
        require(presaleCreatorAddress == msg.sender, "Not presale creator");
        _;
    }

    modifier whitelistedAddressOnly() {
        require(
            !onlyWhitelistedAddressesAllowed || whitelistedAddresses[msg.sender],
            "Address not whitelisted"
        );
        _;
    }

    modifier presaleIsNotCancelled() {
        require(!presaleCancelled, "Cancelled");
        _;
    }

    modifier investorOnly() {
        require(investments[msg.sender] > 0, "Not an investor");
        _;
    }

    modifier notYetClaimedOrRefunded() {
        require(!claimed[msg.sender], "Already claimed or refunded");
        _;
    }

    function setAddressInfo(
        address _presaleCreator,
        address _tokenAddress,
        address _unsoldTokensDumpAddress
    ) external onlyTestIDOFactory {
        require(_presaleCreator != address(0));
        require(_tokenAddress != address(0));
        require(_unsoldTokensDumpAddress != address(0));

        presaleCreatorAddress = payable(_presaleCreator);
        token = IERC20(_tokenAddress);
        unsoldTokensDumpAddress = _unsoldTokensDumpAddress;
    }

    function setGeneralInfo(
        uint256 _totalTokens,
        uint256 _tokenPriceInWei,
        uint256 _hardCapInWei,
        uint256 _softCapInWei,
        uint256 _maxInvestInWei,
        uint256 _minInvestInWei,
        uint256 _openTime,
        uint256 _closeTime
    ) external onlyTestIDOFactory {
        require(_totalTokens > 0);
        require(_tokenPriceInWei > 0);
        require(_openTime > 0);
        require(_closeTime > 0);
        require(_closeTime >= block.timestamp);
        require(_hardCapInWei > 0);

        // Hard cap <= (token amount * token price)
        require(_hardCapInWei <= _totalTokens.mul(_tokenPriceInWei));
        // Soft cap <= to hard cap
        require(_softCapInWei <= _hardCapInWei);
        //  Min. wei investment <= max. wei investment
        require(_minInvestInWei <= _maxInvestInWei);
        // Open time < close time
        require(_openTime < _closeTime);

        totalTokens = _totalTokens;
        tokensLeft = _totalTokens;
        tokenPriceInWei = _tokenPriceInWei;
        hardCapInWei = _hardCapInWei;
        softCapInWei = _softCapInWei;
        maxInvestInWei = _maxInvestInWei;
        minInvestInWei = _minInvestInWei;
        openTime = _openTime;
        closeTime = _closeTime;
    }

    function setAMMInfo(
        uint256 _ammListingPriceInWei,
        uint256 _ammLiquidityAddingTime,
        uint256 _ammLPTokensLockDurationInDays,
        uint256 _ammLiquidityPercentageAllocation,
        address _ammLPTokenBeneficiary
    ) external onlyTestIDOFactory {
        require(_ammListingPriceInWei > 0);
        require(_ammLiquidityAddingTime > 0);
        require(_ammLPTokensLockDurationInDays > 0);
        require(_ammLiquidityPercentageAllocation > 0);
        // require(_ammLPTokenBeneficiary != address(0));

        require(closeTime > 0);
        // Listing time >= close time
        require(_ammLiquidityAddingTime >= closeTime);

        ammListingPriceInWei = _ammListingPriceInWei;
        ammLiquidityAddingTime = _ammLiquidityAddingTime;
        ammLPTokensLockDurationInDays = _ammLPTokensLockDurationInDays;
        ammLiquidityPercentageAllocation = _ammLiquidityPercentageAllocation;
        ammLPTokenBeneficiary = _ammLPTokenBeneficiary;
    }

    function setStringInfo(
        bytes32 _saleTitle,
        bytes32 _linkTelegram,
        bytes32 _linkDiscord,
        bytes32 _linkTwitter,
        bytes32 _linkWebsite,
        string memory _bannerURL
    ) external onlyPresaleCreatorOrTestIDOFactory {
        saleTitle = _saleTitle;
        linkTelegram = _linkTelegram;
        linkDiscord = _linkDiscord;
        linkTwitter = _linkTwitter;
        linkWebsite = _linkWebsite;
        bannerURL = _bannerURL;
    }

    function setTestIDOInfo(
        address _testIDOLiqLockAddress,
        uint256 _testIDODevFeePercentage,
        uint256 _testIDOMinDevFeeInWei,
        uint256 _testIDOId
    ) external onlyTestIDODev {
        require(_testIDOLiqLockAddress != address(0), "Address cannot be a zero address");

        testIDOLiqLockAddress = _testIDOLiqLockAddress;
        testIDODevFeePercentage = _testIDODevFeePercentage;
        testIDOMinDevFeeInWei = _testIDOMinDevFeeInWei;
        testIDOId = _testIDOId;
    }

    function setTestIDODevFeesExempted(bool _testIDODevFeesExempted)
    external
    onlyTestIDODev
    {
        testIDODevFeesExempted = _testIDODevFeesExempted;
    }

    function setOnlyWhitelistedAddressesAllowed(bool _onlyWhitelistedAddressesAllowed)
    external
    onlyPresaleCreatorOrTestIDOFactory
    {
        onlyWhitelistedAddressesAllowed = _onlyWhitelistedAddressesAllowed;
    }

    function addwhitelistedAddresses(address[] calldata _whitelistedAddresses)
    external
    onlyPresaleCreatorOrTestIDOFactory
    {
        uint256 local_variable = _whitelistedAddresses.length;
        onlyWhitelistedAddressesAllowed = _whitelistedAddresses.length > 0;
        for (uint256 i = 0; i < local_variable; i++) {
            whitelistedAddresses[_whitelistedAddresses[i]] = true;
        }
    }

    function setPlatformTokenAddress(address _platformToken) external onlyTestIDODev returns (bool) {
        platformToken = IERC20(_platformToken);
        return true;
    }

    function setStakingContract(address _stakingContract) external onlyTestIDODev returns (bool) {
        stakingContract = TestStaking(_stakingContract);
        return true;
    }

    function setMinStakeAmount(uint256 _minStaked1) external onlyTestIDODev {
        minStaked1 = _minStaked1;
        minStaked2 = (_minStaked1).mul(130).div(100);
        minStaked3 = (_minStaked1).mul(165).div(100);
        minStaked4 = (_minStaked1).mul(200).div(100);
    }

    function getMinStakeAmount() public view returns(uint256, uint256, uint256, uint256) {
       return (minStaked1, minStaked2, minStaked3, minStaked4);
    }

    function setMaxInvest(uint256 _maxInvestUser1, uint256 _maxInvestUser2, uint256 _maxInvestUser3, uint256 _maxInvestUser4) external onlyTestIDODev {
        maxInvestUser1 = _maxInvestUser1;
        maxInvestUser2 = _maxInvestUser2;
        maxInvestUser3 = _maxInvestUser3;
        maxInvestUser4 = _maxInvestUser4;
    }

    function getMaxInvest() public view returns(uint256, uint256, uint256, uint256) {
       return (maxInvestUser1, maxInvestUser2, maxInvestUser3, maxInvestUser4);
    }

    function getMaxInvestmentUser(address account) public view returns(uint256) {
        (uint256 m1, uint256 m2, uint256 m3, uint256 m4) = getMinStakeAmount();
        (uint256 i1, uint256 i2, uint256 i3, uint256 i4) = getMaxInvest();
        
        (, uint256 amount, , ) =  stakingContract.userInfo(account);

        if(amount >= m4)
            return i4;
        else if(amount >= m3)
            return i3;
        else if(amount >= m2)
            return i2;
        else if(amount >= m1)
            return i1;
    }

    function getTokenAmount(uint256 _weiAmount)
    internal
    view
    returns (uint256)
    {
        return _weiAmount.mul(1e18).div(tokenPriceInWei);
    }

    function invest()
    public
    payable
    whitelistedAddressOnly
    presaleIsNotCancelled
    {
        uint256 maxInvest = getMaxInvestmentUser(msg.sender);
        (, uint256 amount, , ) =  stakingContract.userInfo(msg.sender);

        require(block.timestamp >= openTime, "Not yet opened");
        require(block.timestamp < closeTime, "Closed");
        require(totalCollectedWei < hardCapInWei, "Hard cap reached");
        require(tokensLeft > 0);
        // require(amount >= minStaked1, "Not staked enough tokens");
        require(msg.value <= tokensLeft.mul(tokenPriceInWei));
        uint256 totalInvestmentInWei = investments[msg.sender].add(msg.value);
        require(totalInvestmentInWei >= minInvestInWei || totalCollectedWei >= hardCapInWei.sub(1 ether), "Min investment not reached");
        require(maxInvest == 0 || totalInvestmentInWei <= maxInvest, "Max investment reached");

        if (investments[msg.sender] == 0) {
            totalInvestorsCount = totalInvestorsCount.add(1);
        }

        totalCollectedWei = totalCollectedWei.add(msg.value);
        investments[msg.sender] = totalInvestmentInWei;
        tokensLeft = tokensLeft.sub(getTokenAmount(msg.value));
    }

    receive() external payable {
        invest();
    }

    function addLiquidityAndLockLPTokens() external presaleIsNotCancelled {
        require(totalCollectedWei > 0);
        require(!ammLiquidityAdded, "Liquidity already added");
        require(
            !onlyWhitelistedAddressesAllowed || whitelistedAddresses[msg.sender] || msg.sender == presaleCreatorAddress,
            "Not whitelisted or not presale creator"
        );

        if (totalCollectedWei >= hardCapInWei.sub(1 ether) && block.timestamp < ammLiquidityAddingTime) {
            require(msg.sender == presaleCreatorAddress, "Not presale creator");
        } else if (block.timestamp >= ammLiquidityAddingTime) {
            require(
                msg.sender == presaleCreatorAddress || investments[msg.sender] > 0,
                "Not presale creator or investor"
            );
            require(totalCollectedWei >= softCapInWei, "Soft cap not reached");
        } else {
            revert("Liquidity cannot be added yet");
        }

        ammLiquidityAdded = true;

        uint256 finalTotalCollectedWei = totalCollectedWei;
        uint256 testIDODevFeeInWei;
        if (!testIDODevFeesExempted) {
            uint256 pctDevFee = finalTotalCollectedWei.mul(testIDODevFeePercentage).div(100);
            testIDODevFeeInWei = pctDevFee > testIDOMinDevFeeInWei || testIDOMinDevFeeInWei >= finalTotalCollectedWei
            ? pctDevFee
            : testIDOMinDevFeeInWei;
        }
        if (testIDODevFeeInWei > 0) {
            finalTotalCollectedWei = finalTotalCollectedWei.sub(testIDODevFeeInWei);
            testIDODevAddress.transfer(testIDODevFeeInWei);
        }

        uint256 liqPoolEthAmount = finalTotalCollectedWei.mul(ammLiquidityPercentageAllocation).div(100);
        uint256 liqPoolTokenAmount = liqPoolEthAmount.mul(1e18).div(ammListingPriceInWei);

        token.approve(address(ammRouter), liqPoolTokenAmount);

        ammRouter.addLiquidityETH{value : liqPoolEthAmount}(
            address(token),
            liqPoolTokenAmount,
            0,
            0,
            testIDOLiqLockAddress,
            block.timestamp.add(15 minutes)
        );

        uint256 unsoldTokensAmount = token.balanceOf(address(this)).sub(getTokenAmount(totalCollectedWei));
        if (unsoldTokensAmount > 0) {
            token.transfer(unsoldTokensDumpAddress, unsoldTokensAmount);
        }

        presaleCreatorClaimWei = address(this).balance.mul(1e18).div(totalInvestorsCount.mul(1e18));
        presaleCreatorClaimTime = block.timestamp + 1 days;
    }

    function claimTokens()
    external
    whitelistedAddressOnly
    presaleIsNotCancelled
    investorOnly
    notYetClaimedOrRefunded
    {
        require(ammLiquidityAdded, "Liquidity not yet added");

        claimed[msg.sender] = true; // make sure this goes first before transfer to prevent reentrancy
        token.transfer(msg.sender, getTokenAmount(investments[msg.sender]));

        uint256 balance = address(this).balance;
        if (balance > 0) {
            uint256 funds = presaleCreatorClaimWei > balance ? balance : presaleCreatorClaimWei;
            presaleCreatorAddress.transfer(funds);
        }
    }

    function getRefund()
    external
    whitelistedAddressOnly
    investorOnly
    notYetClaimedOrRefunded
    {
        if (!presaleCancelled) {
            require(block.timestamp >= openTime, "Not yet opened");
            require(block.timestamp >= closeTime, "Not yet closed");
            require(softCapInWei > 0, "No soft cap");
            require(totalCollectedWei < softCapInWei, "Soft cap reached");
        }

        claimed[msg.sender] = true; // make sure this goes first before transfer to prevent reentrancy
        uint256 investment = investments[msg.sender];
        uint256 presaleBalance =  address(this).balance;
        require(presaleBalance > 0);

        if (investment > presaleBalance) {
            investment = presaleBalance;
        }

        if (investment > 0) {
            msg.sender.transfer(investment);
        }
    }

    function cancelAndTransferTokensToPresaleCreator() external {
        if (!ammLiquidityAdded && presaleCreatorAddress != msg.sender && testIDODevAddress != msg.sender) {
            revert();
        }
        if (ammLiquidityAdded && testIDODevAddress != msg.sender) {
            revert();
        }

        require(!presaleCancelled);
        presaleCancelled = true;

        uint256 balance = token.balanceOf(address(this));
        if (balance > 0) {
            token.transfer(presaleCreatorAddress, balance);
        }
    }

    function collectFundsRaised() onlyPresaleCreator external {
        require(ammLiquidityAdded);
        require(!presaleCancelled);
        require(block.timestamp >= presaleCreatorClaimTime);

        if (address(this).balance > 0) {
            presaleCreatorAddress.transfer(address(this).balance);
        }
    }
}