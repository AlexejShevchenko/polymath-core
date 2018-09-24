pragma solidity ^0.4.24;

import "./DividendCheckpoint.sol";

/**
 * @title Checkpoint module for issuing ether dividends
 */
contract EtherDividendCheckpoint is DividendCheckpoint {
    using SafeMath for uint256;

    uint256 public EXCLUDED_ADDRESS_LIMIT = 50;
    bytes32 public constant DISTRIBUTE = "DISTRIBUTE";

    struct Dividend {
      uint256 checkpointId;
      uint256 created; // Time at which the dividend was created
      uint256 maturity; // Time after which dividend can be claimed - set to 0 to bypass
      uint256 expiry;  // Time until which dividend can be claimed - after this time any remaining amount can be withdrawn by issuer - set to very high value to bypass
      uint256 amount; // Dividend amount in WEI
      uint256 claimedAmount; // Amount of dividend claimed so far
      uint256 totalSupply; // Total supply at the associated checkpoint (avoids recalculating this)
      bool reclaimed;  // True if expiry has passed and issuer has reclaimed remaining dividend
      uint256 dividendWithheld;
      uint256 dividendWithheldReclaimed;
      mapping (address => bool) claimed; // List of addresses which have claimed dividend
      mapping (address => bool) excluded; // List of addresses which cannot claim dividends
    }

    // List of all dividends
    Dividend[] public dividends;

    // Mapping from address to withholding tax as a percentage * 10**16
    mapping (address => uint256) public withholdingTax;

    // Total amount of ETH withheld per investor
    mapping (address => uint256) public investorWithheld;

    event EtherDividendDeposited(address indexed _depositor, uint256 _checkpointId, uint256 _created, uint256 _maturity, uint256 _expiry, uint256 _amount, uint256 _totalSupply, uint256 _dividendIndex);
    event EtherDividendClaimed(address indexed _payee, uint256 _dividendIndex, uint256 _amount, uint256 _withheld);
    event EtherDividendReclaimed(address indexed _claimer, uint256 _dividendIndex, uint256 _claimedAmount);
    event EtherDividendClaimFailed(address indexed _payee, uint256 _dividendIndex, uint256 _amount, uint256 _withheld);
    event EtherDividendWithholdingWithdrawn(address indexed _claimer, uint256 _dividendIndex, uint256 _withheldAmount);

    modifier validDividendIndex(uint256 _dividendIndex) {
        require(_dividendIndex < dividends.length, "Incorrect dividend index");
        require(now >= dividends[_dividendIndex].maturity, "Dividend maturity is in the future");
        require(now < dividends[_dividendIndex].expiry, "Dividend expiry is in the past");
        require(!dividends[_dividendIndex].reclaimed, "Dividend has been reclaimed by issuer");
        _;
    }

    /**
     * @notice Constructor
     * @param _securityToken Address of the security token
     * @param _polyAddress Address of the polytoken
     */
    constructor (address _securityToken, address _polyAddress) public
    Module(_securityToken, _polyAddress)
    {
    }

    /**
    * @notice Init function i.e generalise function to maintain the structure of the module contract
    * @return bytes4
    */
    function getInitFunction() public pure returns (bytes4) {
        return bytes4(0);
    }

    /**
     * @notice Function to set withholding tax rates for investors
     * @param _investors addresses of investor
     * @param _withholding withholding tax for individual investors (multiplied by 10**16)
     */
    function setWithholding(address[] _investors, uint256[] _withholding) public onlyOwner {
        require(_investors.length == _withholding.length);
        for (uint256 i = 0; i < _investors.length; i++) {
            require(_withholding[i] <= 10**18);
            withholdingTax[_investors[i]] = _withholding[i];
        }
    }

    /**
     * @notice Function to set withholding tax rates for investors
     * @param _investors addresses of investor
     * @param _withholding withholding tax for all investors (multiplied by 10**16)
     */
    function setWithholdingFixed(address[] _investors, uint256 _withholding) public onlyOwner {
        require(_withholding <= 10**18);
        for (uint256 i = 0; i < _investors.length; i++) {
            withholdingTax[_investors[i]] = _withholding;
        }
    }

    /**
     * @notice Creates a dividend and checkpoint for the dividend
     * @param _maturity Time from which dividend can be paid
     * @param _expiry Time until dividend can no longer be paid, and can be reclaimed by issuer
     */
    function createDividend(uint256 _maturity, uint256 _expiry, address[] _excluded) payable public onlyOwner {
        uint256 checkpointId = ISecurityToken(securityToken).createCheckpoint();
        createDividendWithCheckpoint(_maturity, _expiry, checkpointId, _excluded);
    }

    /**
     * @notice Creates a dividend with a provided checkpoint
     * @param _maturity Time from which dividend can be paid
     * @param _expiry Time until dividend can no longer be paid, and can be reclaimed by issuer
     * @param _checkpointId Id of the checkpoint from which to issue dividend
     */
    function createDividendWithCheckpoint(uint256 _maturity, uint256 _expiry, uint256 _checkpointId, address[] _excluded) payable public onlyOwner {
        require(_excluded.length <= EXCLUDED_ADDRESS_LIMIT, "Too many addresses excluded");
        require(_expiry > _maturity, "Expiry is before maturity");
        require(_expiry > now), "Expiry is in the past");
        require(msg.value > 0, "No dividend sent");
        require(_checkpointId <= ISecurityToken(securityToken).currentCheckpointId());
        uint256 dividendIndex = dividends.length;
        uint256 currentSupply = ISecurityToken(securityToken).totalSupplyAt(_checkpointId);
        uint256 excludedSupply = 0;
        for (uint256 i = 0; i < _excluded.length; i++) {
            excludedSupply = excludedSupply.add(ISecurityToken(securityToken).balanceOf(_excluded[i]));
        }
        dividends.push(
          Dividend(
            _checkpointId,
            now,
            _maturity,
            _expiry,
            msg.value,
            0,
            currentSupply.sub(excludedSupply),
            false
          )
        );
        for (uint256 j = 0; j < _excluded.length; j++) {
            dividends[dividends.length - 1].excluded[_excluded[j]] = true;
        }
        emit EtherDividendDeposited(msg.sender, _checkpointId, now, _maturity, _expiry, msg.value, currentSupply, dividendIndex);
    }

    /**
     * @notice Issuer can push dividends to provided addresses
     * @param _dividendIndex Dividend to push
     * @param _payees Addresses to which to push the dividend
     */
    function pushDividendPaymentToAddresses(uint256 _dividendIndex, address[] _payees) public withPerm(DISTRIBUTE) validDividendIndex(_dividendIndex) {
        Dividend storage dividend = dividends[_dividendIndex];
        for (uint256 i = 0; i < _payees.length; i++) {
            if ((!dividend.claimed[_payees[i]]) && (!dividend.excluded[_payees[i]])) {
                _payDividend(_payees[i], dividend, _dividendIndex);
            }
        }
    }

    /**
     * @notice Issuer can push dividends using the investor list from the security token
     * @param _dividendIndex Dividend to push
     * @param _start Index in investor list at which to start pushing dividends
     * @param _iterations Number of addresses to push dividends for
     */
    function pushDividendPayment(uint256 _dividendIndex, uint256 _start, uint256 _iterations) public withPerm(DISTRIBUTE) validDividendIndex(_dividendIndex) {
        Dividend storage dividend = dividends[_dividendIndex];
        uint256 numberInvestors = ISecurityToken(securityToken).getInvestorsLength();
        for (uint256 i = _start; i < Math.min256(numberInvestors, _start.add(_iterations)); i++) {
            address payee = ISecurityToken(securityToken).investors(i);
            if ((!dividend.claimed[payee]) && (!dividend.excluded[payee])) {
                _payDividend(payee, dividend, _dividendIndex);
            }
        }
    }

    /**
     * @notice Investors can pull their own dividends
     * @param _dividendIndex Dividend to pull
     */
    function pullDividendPayment(uint256 _dividendIndex) public validDividendIndex(_dividendIndex)
    {
        Dividend storage dividend = dividends[_dividendIndex];
        require(!dividend.claimed[msg.sender], "Dividend already claimed by msg.sender");
        require(!dividend.excluded[msg.sender], "msg.sender excluded from Dividend");
        _payDividend(msg.sender, dividend, _dividendIndex);
    }

    /**
     * @notice Internal function for paying dividends
     * @param _payee address of investor
     * @param _dividend storage with previously issued dividends
     * @param _dividendIndex Dividend to pay
     */
    function _payDividend(address _payee, Dividend storage _dividend, uint256 _dividendIndex) internal {
        (uint256 claim, uint256 withheld) = calculateDividend(_dividendIndex, _payee);
        _dividend.claimed[_payee] = true;
        _dividend.claimedAmount = claim.add(_dividend.claimedAmount);
        uint256 claimAfterWithheld = claim.sub(withheld);
        if (claimAfterWithheld > 0) {
            if (_payee.send(claimAfterWithheld)) {
              _dividend.dividendWithheld = _dividend.dividendWithheld.add(withheld);
              investorWithheld[_payee] = investorWithheld[_payee].add(withheld);
              emit EtherDividendClaimed(_payee, _dividendIndex, claim, withheld);
            } else {
              _dividend.claimed[_payee] = false;
              emit EtherDividendClaimFailed(_payee, _dividendIndex, claim, withheld);
            }
        }
    }

    /**
     * @notice Issuer can reclaim remaining unclaimed dividend amounts, for expired dividends
     * @param _dividendIndex Dividend to reclaim
     */
    function reclaimDividend(uint256 _dividendIndex) public onlyOwner {
        require(_dividendIndex < dividends.length, "Incorrect dividend index");
        require(now >= dividends[_dividendIndex].expiry, "Dividend expiry is in the future");
        require(!dividends[_dividendIndex].reclaimed, "Dividend already claimed");
        Dividend storage dividend = dividends[_dividendIndex];
        dividend.reclaimed = true;
        uint256 remainingAmount = dividend.amount.sub(dividend.claimedAmount);
        msg.sender.transfer(remainingAmount);
        emit EtherDividendReclaimed(msg.sender, _dividendIndex, remainingAmount);
    }

    /**
     * @notice Calculate amount of dividends claimable
     * @param _dividendIndex Dividend to calculate
     * @param _payee Affected investor address
     * @return unit256
     */
    function calculateDividend(uint256 _dividendIndex, address _payee) public view returns(uint256, uint256) {
        require(_dividendIndex < dividends.length, "Incorrect dividend index");
        Dividend storage dividend = dividends[_dividendIndex];
        if (dividend.claimed[_payee] || dividend.excluded[_payee]) {
            return (0, 0);
        }
        uint256 balance = ISecurityToken(securityToken).balanceOfAt(_payee, dividend.checkpointId);
        uint256 claim = balance.mul(dividend.amount).div(dividend.totalSupply);
        uint256 withheld = claim.mul(withholdingTax[_payee]).div(uint256(10**18));
        return (claim, withheld);
    }

    /**
     * @notice Get the index according to the checkpoint id
     * @param _checkpointId Checkpoint id to query
     * @return uint256[]
     */
    function getDividendIndex(uint256 _checkpointId) public view returns(uint256[]) {
        uint256 counter = 0;
        for(uint256 i = 0; i < dividends.length; i++) {
            if (dividends[i].checkpointId == _checkpointId) {
                counter++;
            }
        }

       uint256[] memory index = new uint256[](counter);
       counter = 0;
       for(uint256 j = 0; j < dividends.length; j++) {
           if (dividends[j].checkpointId == _checkpointId) {
               index[counter] = j;
               counter++;
           }
       }
       return index;
    }

    /**
     * @notice Allows issuer to withdraw withheld tax
     * @param _dividendIndex Dividend to withdraw from
     */
    function withdrawWithholding(uint256 _dividendIndex) public onlyOwner {
        require(_dividendIndex < dividends.length, "Incorrect dividend index");
        Dividend storage dividend = dividends[_dividendIndex];
        uint256 remainingWithheld = dividend.dividendWithheld.sub(dividend.dividendWithheldReclaimed);
        dividend.dividendWithheldReclaimed = dividend.dividendWithheld;
        msg.sender.transfer(remainingWithheld);
        emit EtherDividendWithholdingWithdrawn(msg.sender, _dividendIndex, remainingWithheld);
    }

    /**
     * @notice Return the permissions flag that are associated with STO
     * @return bytes32 array
     */
    function getPermissions() public view returns(bytes32[]) {
        bytes32[] memory allPermissions = new bytes32[](1);
        allPermissions[0] = DISTRIBUTE;
        return allPermissions;
    }

}
