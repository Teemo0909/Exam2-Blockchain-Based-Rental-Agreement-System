// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Smart Property Rental & Deposit Management.
/// Money moves by pull-payment (credit + withdraw) so a hostile wallet cannot block settlement.
contract RentalAgreement {
    enum Status { Created, Active, Pending, Disputed, Closed, Cancelled }

    struct Property { address owner; string name; uint256 rent; uint256 deposit; }
    struct Payment { uint256 amount; uint256 time; }
    struct Agreement {
        uint256 propertyId;
        address owner;
        address tenant;
        address arbiter;      // authority who resolves disputes
        uint64 start;
        uint64 end;
        uint256 rent;
        uint256 deposit;
        uint256 held;         // remaining deposit balance in the contract
        uint256 deduction;    // proposed/approved deduction
        string terms;         // key conditions (text or IPFS/hash)
        string reason;        // reason for deduction / dispute outcome
        bool ownerOk;
        bool tenantOk;
        bool deposited;
        Status status;
        uint64 deadline;      // while Pending/Disputed: when the silent party's turn times out
    }

    // How long each party has to act before the other side can close the agreement without them.
    uint256 public constant CLAIM_WINDOW = 14 days;

    Property[] public properties;
    Agreement[] private agreements; // read via getAgreement: a public getter of 16 fields is "stack too deep" without viaIR
    mapping(uint256 => Payment[]) private _payments;
    mapping(address => uint256) public credit; // withdrawable balance

    event PropertyRegistered(uint256 indexed id, address indexed owner, uint256 rent, uint256 deposit);
    event PropertyUpdated(uint256 indexed id, uint256 rent, uint256 deposit);
    event AgreementCreated(uint256 indexed id, uint256 indexed propertyId, address tenant, address arbiter);
    event Confirmed(uint256 indexed id, address indexed by);
    event DepositPaid(uint256 indexed id, uint256 amount);
    event RentPaid(uint256 indexed id, uint256 period, uint256 amount, uint256 time);
    event DeductionProposed(uint256 indexed id, uint256 amount, string reason);
    event Disputed(uint256 indexed id, string reason);
    event Settled(uint256 indexed id, uint256 toOwner, uint256 toTenant, string reason);
    event Cancelled(uint256 indexed id, address indexed by);

    // 1. Register property
    function registerProperty(string calldata name, uint256 rent, uint256 deposit) external returns (uint256 id) {
        require(rent > 0, "rent=0");
        properties.push(Property(msg.sender, name, rent, deposit));
        id = properties.length - 1;
        emit PropertyRegistered(id, msg.sender, rent, deposit);
    }

    // 2. Create agreement (property owner only; rent/deposit copied so later edits can't change terms)
    function createAgreement(uint256 propertyId, address tenant, address arbiter, uint64 start, uint64 end, string calldata terms)
        external returns (uint256 id)
    {
        Property storage p = properties[propertyId];
        require(msg.sender == p.owner, "not owner");
        require(tenant != address(0) && tenant != msg.sender, "bad tenant");
        require(arbiter != address(0) && arbiter != msg.sender && arbiter != tenant, "bad arbiter");
        require(end > start && end > block.timestamp, "bad dates");
        agreements.push(Agreement(propertyId, msg.sender, tenant, arbiter, start, end, p.rent, p.deposit, 0, 0, terms, "", false, false, false, Status.Created, 0));
        id = agreements.length - 1;
        emit AgreementCreated(id, propertyId, tenant, arbiter);
    }

    // 3. Both parties confirm with their wallet
    function confirmAgreement(uint256 id) external {
        Agreement storage a = agreements[id];
        require(a.status == Status.Created, "not open");
        if (msg.sender == a.owner) a.ownerOk = true;
        else if (msg.sender == a.tenant) a.tenantOk = true;
        else revert("not party");
        if (a.ownerOk && a.tenantOk) a.status = Status.Active;
        emit Confirmed(id, msg.sender);
    }

    // Either party can walk away while no money is in the contract (before the deposit is paid).
    function cancelAgreement(uint256 id) external {
        Agreement storage a = agreements[id];
        require(msg.sender == a.owner || msg.sender == a.tenant, "not party");
        require(a.status == Status.Created || (a.status == Status.Active && !a.deposited), "cannot cancel");
        a.status = Status.Cancelled;
        emit Cancelled(id, msg.sender);
    }

    // 4. Tenant deposits the exact security deposit in ETH
    function depositSecurity(uint256 id) external payable {
        Agreement storage a = agreements[id];
        require(a.status == Status.Active && !a.deposited, "cannot deposit");
        require(msg.sender == a.tenant && msg.value == a.deposit, "bad sender/amount");
        a.deposited = true;
        a.held = msg.value;
        emit DepositPaid(id, msg.value);
    }

    // 5. Tenant pays one period of rent (30 days each); credited to owner
    function payRent(uint256 id) external payable {
        Agreement storage a = agreements[id];
        require(a.status == Status.Active && a.deposited, "not payable");
        require(msg.sender == a.tenant && msg.value == a.rent, "bad sender/amount");
        uint256 n = _payments[id].length;
        require(n < _periods(a), "all paid");
        _payments[id].push(Payment(msg.value, block.timestamp));
        credit[a.owner] += msg.value;
        emit RentPaid(id, n + 1, msg.value, block.timestamp);
    }

    function getAgreement(uint256 id) external view returns (Agreement memory) { return agreements[id]; }

    function getPayments(uint256 id) external view returns (Payment[] memory) { return _payments[id]; }

    // Added: owner edits rent/deposit of a room. Existing agreements keep the terms they copied.
    function updateProperty(uint256 id, uint256 rent, uint256 deposit) external {
        Property storage p = properties[id];
        require(msg.sender == p.owner, "not owner");
        require(rent > 0, "rent=0");
        p.rent = rent;
        p.deposit = deposit;
        emit PropertyUpdated(id, rent, deposit);
    }

    // Added: every agreement id where `user` is owner, tenant or arbiter.
    // shortcut: loops over all agreements, fine for hundreds; add a per-user index if it grows to thousands.
    function agreementsOf(address user) external view returns (uint256[] memory ids) {
        uint256 n;
        for (uint256 i; i < agreements.length; i++) if (_isParty(agreements[i], user)) n++;
        ids = new uint256[](n);
        n = 0;
        for (uint256 i; i < agreements.length; i++) if (_isParty(agreements[i], user)) ids[n++] = i;
    }

    function _isParty(Agreement storage a, address user) private view returns (bool) {
        return a.owner == user || a.tenant == user || a.arbiter == user;
    }

    // Added: rent progress of one agreement.
    function rentSummary(uint256 id) external view returns (uint256 paidPeriods, uint256 totalPeriods, uint256 totalPaid) {
        Agreement storage a = agreements[id];
        Payment[] storage ps = _payments[id];
        for (uint256 i; i < ps.length; i++) totalPaid += ps[i].amount;
        return (ps.length, _periods(a), totalPaid);
    }

    // Number of 30-day rent periods in the lease, rounded up.
    function _periods(Agreement storage a) private view returns (uint256) {
        return (a.end - a.start + 30 days - 1) / 30 days;
    }

    // 6. After the lease ends and the inspection, owner states the deduction (0 = full refund).
    function proposeDeduction(uint256 id, uint256 amount, string calldata reason) external {
        Agreement storage a = agreements[id];
        require(msg.sender == a.owner && a.status == Status.Active && a.deposited, "not allowed");
        require(block.timestamp >= a.end, "lease not ended");
        require(amount <= a.held, "exceeds deposit");
        require(amount == 0 || bytes(reason).length > 0, "reason required");
        a.deduction = amount;
        a.reason = reason;
        emit DeductionProposed(id, amount, reason);
        if (amount == 0) _settle(a, id);
        else { a.status = Status.Pending; a.deadline = uint64(block.timestamp + CLAIM_WINDOW); }
    }

    // Tenant agrees to the deduction -> release
    function acceptDeduction(uint256 id) external {
        Agreement storage a = agreements[id];
        require(msg.sender == a.tenant && a.status == Status.Pending, "not allowed");
        _settle(a, id);
    }

    // 7. Tenant disputes; arbiter decides before any money is released
    function disputeDeduction(uint256 id, string calldata reason) external {
        Agreement storage a = agreements[id];
        require(msg.sender == a.tenant && a.status == Status.Pending, "not allowed");
        a.status = Status.Disputed;
        a.deadline = uint64(block.timestamp + CLAIM_WINDOW);
        emit Disputed(id, reason);
    }

    function resolveDispute(uint256 id, uint256 deduction, string calldata reason) external {
        Agreement storage a = agreements[id];
        require(msg.sender == a.arbiter && a.status == Status.Disputed, "not allowed");
        require(deduction <= a.held, "exceeds deposit");
        a.deduction = deduction;
        a.reason = reason;
        _settle(a, id);
    }

    // 8. Nobody can lock the deposit by staying silent. After CLAIM_WINDOW:
    //    - owner never settled after the lease  -> tenant takes a full refund
    //    - tenant never answered a deduction    -> owner closes with the proposed deduction
    //    - arbiter never ruled on a dispute     -> full refund (an unproven deduction is not paid)
    function claimTimeout(uint256 id) external {
        Agreement storage a = agreements[id];
        if (a.status == Status.Active) {
            require(msg.sender == a.tenant && a.deposited, "not allowed");
            require(block.timestamp >= a.end + CLAIM_WINDOW, "too early");
            a.deduction = 0;
            a.reason = "owner did not settle in time";
        } else if (a.status == Status.Pending) {
            require(msg.sender == a.owner, "not allowed");
            require(block.timestamp >= a.deadline, "too early");
        } else if (a.status == Status.Disputed) {
            require(msg.sender == a.owner || msg.sender == a.tenant, "not allowed");
            require(block.timestamp >= a.deadline, "too early");
            a.deduction = 0;
            a.reason = "arbiter did not rule in time";
        } else revert("not allowed");
        _settle(a, id);
    }

    function _settle(Agreement storage a, uint256 id) private {
        uint256 toOwner = a.deduction;
        uint256 toTenant = a.held - toOwner;
        a.held = 0;
        a.status = Status.Closed;
        credit[a.owner] += toOwner;
        credit[a.tenant] += toTenant;
        emit Settled(id, toOwner, toTenant, a.reason);
    }

    function withdraw() external {
        uint256 amt = credit[msg.sender];
        require(amt > 0, "nothing");
        credit[msg.sender] = 0;
        (bool ok, ) = msg.sender.call{value: amt}("");
        require(ok, "send failed");
    }
}
