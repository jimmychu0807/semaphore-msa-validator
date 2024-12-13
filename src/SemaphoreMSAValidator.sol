// SPDX-License-Identifier: MIT
pragma solidity >=0.8.23 <=0.8.29;

import { ERC7579ValidatorBase } from "modulekit/Modules.sol";
import { PackedUserOperation } from "modulekit/external/ERC4337.sol";
import { SignatureCheckerLib } from "solady/utils/SignatureCheckerLib.sol";
import { LibSort } from "solady/utils/LibSort.sol";
import { ECDSA } from "solady/utils/ECDSA.sol";

import { ISemaphore, ISemaphoreGroups } from "./utils/Semaphore.sol";

contract SemaphoreMSAValidator is ERC7579ValidatorBase {
    using LibSort for *;

    // Constants
    uint8 constant MAX_MEMBERS = 32;

    // Errors
    error CannotRemoveOwner();
    error InvalidIdCommitment();
    error InvalidThreshold();
    error MaxMemberReached();
    error NotSortedAndUnique();
    error MemberNotExists(address account, uint256 cmt);
    error IsMemberAlready(address acount, uint256 cmt);
    error TxHasBeenInitiated(address account, bytes32 txHash);
    error TxNotExist(address account, bytes32 txHash);
    error ThresholdNotReach(address account, uint8 threshold, uint8 current);

    // Events
    event ModuleInitialized(address indexed account);
    event ModuleUninitialized(address indexed account);
    event AddedMember(address indexed, uint256 indexed commitment);
    event RemovedMember(address indexed, uint256 indexed commitment);
    event ThresholdSet(address indexed account, uint8 indexed threshold);
    event InitiatedTx(address indexed account, bytes32 indexed txHash);
    event SignedTx(address indexed account, bytes32 indexed txHash);
    event ExecutedTx(address indexed account, bytes32 indexed txHash);

    /**
     * Storage
     */
    ISemaphore public semaphore;
    ISemaphoreGroups public groups;
    mapping(address account => uint256 groupId) public groupMapping;
    mapping(address account => uint8 threshold) public thresholds;

    // commitments(users) count for each smart account
    mapping(address account => uint8 count) public memberCount;

    // smart account -> hash(call(params)) -> valid proof count
    mapping(address account => mapping(bytes32 txHash => uint8 count)) public acctTxCount;

    // keep track of seqNum of txs that require threshold signature
    mapping(address account => uint256 seqNum) public acctSeqNum;

    constructor(ISemaphore _semaphore) {
        semaphore = _semaphore;
        groups = ISemaphoreGroups(address(_semaphore));
    }

    modifier moduleInstalled() {
        if (thresholds[msg.sender] == 0) revert NotInitialized(msg.sender);
        _;
    }

    /**
     * Config
     */
    function isInitialized(address account) external view override returns (bool) {
        return thresholds[account] > 0;
    }

    function onInstall(bytes calldata data) external override {
        // create a new group
        // msg.sender is the smart account that call this contract
        // the address in data is the EOA owner of the smart account
        // you often have to parse the passed in parameters to get the original caller
        // The address of the original caller (the one who sends http request to the bundler) must
        // be passed in from data

        // Ensure the module isn't installed already for the smart account
        address account = msg.sender;
        if (thresholds[account] > 0) revert AlreadyInitialized(account);

        // OwnableValidator
        (uint8 threshold, uint256[] memory cmts) = abi.decode(data, (uint8, uint256[]));

        // Check all address are valid
        (bool found,) = cmts.searchSorted(uint256(0));
        if (found) revert InvalidIdCommitment();

        if (!cmts.isSortedAndUniquified()) revert NotSortedAndUnique();

        // Check the relation between threshold and ownersLen are valid
        if (cmts.length > MAX_MEMBERS) revert MaxMemberReached();

        uint8 cmtLen = uint8(cmts.length);
        if (cmtLen == 0 || cmtLen < threshold) revert InvalidThreshold();

        // Completed all checks by this point. Write to the storage.
        thresholds[account] = threshold;
        memberCount[account] = cmtLen;

        uint256 groupId = semaphore.createGroup();
        groupMapping[account] = groupId;

        // Add members to the group
        semaphore.addMembers(groupId, cmts);

        emit ModuleInitialized(account);
    }

    function onUninstall(bytes calldata) external override moduleInstalled {
        // remove from our data structure
        address account = msg.sender;
        delete thresholds[account];
        delete memberCount[account];
        delete groupMapping[account];
        delete acctSeqNum[account];

        // TODO: what is a good way to delete entries associated to `acctTxCount[account]`,
        //   The following line is not a valid solidity code.
        // delete acctTxCount[account];

        emit ModuleUninitialized(account);
    }

    function setThreshold(uint8 newThreshold) external moduleInstalled {
        address account = msg.sender;
        if (newThreshold == 0 || newThreshold > memberCount[account]) revert InvalidThreshold();

        thresholds[account] = newThreshold;
        emit ThresholdSet(account, newThreshold);
    }

    function addMember(uint256 cmt) external moduleInstalled {
        address account = msg.sender;
        // 0. check the module is initialized for the acct
        // 1. check newOwner != 0
        // 2. check ownerCount < MAX_MEMBERS
        // 3. cehck owner not existed yet
        if (cmt == uint256(0)) revert InvalidIdCommitment();
        if (memberCount[account] == MAX_MEMBERS) revert MaxMemberReached();

        uint256 groupId = groupMapping[account];

        if (groups.hasMember(groupId, cmt)) revert IsMemberAlready(account, cmt);

        semaphore.addMember(groupId, cmt);
        memberCount[account] += 1;

        emit AddedMember(account, cmt);
    }

    function removeMember(uint256 rmOwner) external moduleInstalled {
        address account = msg.sender;

        if (memberCount[account] == thresholds[account]) revert CannotRemoveOwner();
        uint256 groupId = groupMapping[account];
        if (!groups.hasMember(groupId, rmOwner)) revert MemberNotExists(account, rmOwner);

        memberCount[account] -= 1;

        // TODO: add the 3rd param: merkleProofSiblings
        semaphore.removeMember(groupId, rmOwner, new uint256[](0));

        emit RemovedMember(account, rmOwner);
    }

    function initiateTx(
        bytes calldata txParams,
        ISemaphore.SemaphoreProof calldata proof,
        bool execute
    )
        external
        moduleInstalled
        returns (bytes32 txHash)
    {
        // retrieve the group ID
        address account = msg.sender;
        uint256 groupId = groupMapping[account];

        // TODO: validate txParams are a valid tx call with propoer parameters. How?

        // By this point, txParams should be validated.
        // combine the txParams with the account nonce and compute its hash
        uint256 seq = acctSeqNum[account];
        txHash = keccak256(abi.encode(txParams, seq));

        if (acctTxCount[account][txHash] != 0) revert TxHasBeenInitiated(account, txHash);

        semaphore.validateProof(groupId, proof);

        // By this point, the proof also passed semaphore check.
        // Start writing to the storage
        acctSeqNum[account] += 1;
        acctTxCount[account][txHash] = 1;

        emit InitiatedTx(account, txHash);

        // execute the transaction if condition allows
        if (execute && acctTxCount[account][txHash] >= thresholds[account]) executeTx(txHash);
    }

    function signTx(
        bytes32 txHash,
        ISemaphore.SemaphoreProof calldata proof,
        bool execute
    )
        external
        moduleInstalled
    {
        // retrieve the group ID
        address account = msg.sender;
        uint256 groupId = groupMapping[account];

        // Check if the txHash exist
        if (acctTxCount[account][txHash] == 0) revert TxNotExist(account, txHash);

        semaphore.validateProof(groupId, proof);

        acctTxCount[account][txHash] += 1;

        emit SignedTx(account, txHash);

        // execute the transaction if condition allows
        if (execute && acctTxCount[account][txHash] >= thresholds[account]) executeTx(txHash);
    }

    function executeTx(bytes32 txHash) public moduleInstalled {
        // retrieve the group ID
        address account = msg.sender;
        uint256 groupId = groupMapping[account];

        uint8 threshold = thresholds[account];
        uint8 current = acctTxCount[account][txHash];

        if (current < threshold) revert ThresholdNotReach(account, threshold, current);

        // TODO: make the actual contract call here

        emit ExecutedTx(account, txHash);

        // Clean up the storage
        delete acctTxCount[account][txHash];
    }

    /**
     * Module logic
     *
     */
    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    )
        external
        view
        override
        returns (ValidationData)
    {
        // you want to exclude initiateTx, signTx, executeTx from needing tx count.
        // you just need to ensure they are a valid proof from the semaphore group members

        bool sigFailed = false;
        (uint256 sender, bytes memory _signature) = abi.decode(userOp.signature, (uint256, bytes));

        return _packValidationData(!sigFailed, type(uint48).max, 0);
    }

    function isValidSignatureWithSender(
        address sender,
        bytes32 hash,
        bytes calldata signature
    )
        external
        view
        virtual
        override
        returns (bytes4 sugValidationResult)
    {
        return EIP1271_SUCCESS;
    }

    function validateSignatureWithData(
        bytes32,
        bytes calldata,
        bytes calldata
    )
        external
        view
        virtual
        returns (bool validSig)
    {
        return true;
    }

    /*//////////////////////////////////////////////////////////////////////////
                                   METADATA
    //////////////////////////////////////////////////////////////////////////*/

    /**
     * The name of the module
     *
     * @return name The name of the module
     */
    function name() external pure returns (string memory) {
        return "SemaphoreMSAValidator";
    }

    /**
     * The version of the module
     *
     * @return version The version of the module
     */
    function version() external pure returns (string memory) {
        return "0.1.0";
    }

    /**
     * Check if the module is of a certain type
     *
     * @param typeID The type ID to check
     *
     * @return true if the module is of the given type, false otherwise
     */
    function isModuleType(uint256 typeID) external pure override returns (bool) {
        return typeID == TYPE_VALIDATOR;
    }
}
