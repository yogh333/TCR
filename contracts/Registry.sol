pragma solidity^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";
import "./Parameterizer.sol";
import "../../PLCRVoting/contracts/PLCRVoting.sol";


contract Registry {

    // ------
    // EVENTS
    // ------

    event _Application(bytes32 indexed listingHash, uint256 deposit, uint256 appEndDate, string data, address indexed applicant);
    event _Challenge(bytes32 indexed listingHash, uint256 challengeID, string data, uint256 commitEndDate, uint256 revealEndDate, address indexed challenger);
    event _Deposit(bytes32 indexed listingHash, uint256 added, uint256 newTotal, address indexed owner);
    event _Withdrawal(bytes32 indexed listingHash, uint256 withdrew, uint256 newTotal, address indexed owner);
    event _ApplicationWhitelisted(bytes32 indexed listingHash);
    event _ApplicationRemoved(bytes32 indexed listingHash);
    event _ListingRemoved(bytes32 indexed listingHash);
    event _ListingWithdrawn(bytes32 indexed listingHash, address indexed owner);
    event _TouchAndRemoved(bytes32 indexed listingHash);
    event _ChallengeFailed(bytes32 indexed listingHash, uint256 indexed challengeID, uint256 rewardPool, uint256 totalTokens);
    event _ChallengeSucceeded(bytes32 indexed listingHash, uint256 indexed challengeID, uint256 rewardPool, uint256 totalTokens);
    event _RewardClaimed(uint256 indexed challengeID, uint256 reward, address indexed voter);
    event _ExitInitialized(bytes32 indexed listingHash, uint256 exitTime, uint256 exitDelayEndDate, address indexed owner);

    using SafeMath for uint256;

    struct Listing {
        uint256 applicationExpiry; // Expiration date of apply stage
        bool whitelisted;       // Indicates registry status
        address owner;          // Owner of Listing
        uint256 unstakedDeposit;   // Number of tokens in the listing not locked in a challenge
        uint256 challengeID;       // Corresponds to a PollID in PLCRVoting
	    uint256 exitTime;		// Time the listing may leave the registry
        uint256 exitTimeExpiry;    // Expiration date of exit period
    }

    struct Challenge {
        uint256 rewardPool;        // (remaining) Pool of tokens to be distributed to winning voters
        address challenger;     // Owner of Challenge
        bool resolved;          // Indication of if challenge is resolved
        uint256 stake;             // Number of tokens at stake for either party during challenge
        uint256 totalTokens;       // (remaining) Number of tokens used in voting by the winning side
        mapping(address => bool) tokenClaims; // Indicates whether a voter has claimed a reward yet
    }

    // Maps challengeIDs to associated challenge data
    mapping(uint256 => Challenge) public challenges;

    // Maps listingHashes to associated listingHash data
    mapping(bytes32 => Listing) public listings;

    // Global Variables
    IERC20 public token;
    PLCRVoting public voting;
    Parameterizer public parameterizer;
    string public name;

    /**
    @dev Initializer. Can only be called once.
    @param _token The address where the ERC20 token contract is deployed
    */
    function init(address _token, address _voting, address _parameterizer, string memory _name) public {
        require(_token != address(0) && address(token) == address(0));
        require(_voting != address(0) && address(voting) == address(0));
        require(_parameterizer != address(0) && address(parameterizer) == address(0));

        token = IERC20(_token);
        voting = PLCRVoting(_voting);
        parameterizer = Parameterizer(_parameterizer);
        name = _name;
    }

    // --------------------
    // PUBLISHER INTERFACE:
    // --------------------

    /**
    @dev                Allows a user to start an application. Takes tokens from user and sets
                        apply stage end time.
    @param _listingHash The hash of a potential listing a user is applying to add to the registry
    @param _amount      The number of ERC20 tokens a user is willing to potentially stake
    @param _data        Extra data relevant to the application. Think IPFS hashes.
    */
    function apply_(bytes32 _listingHash, uint256 _amount, string memory _data) external {
        require(!isWhitelisted(_listingHash));
        require(!appWasMade(_listingHash));
        require(_amount >= parameterizer.get("minDeposit"));

        // Sets owner
        Listing storage listing = listings[_listingHash];
        listing.owner = msg.sender;

        // Sets apply stage end time
        listing.applicationExpiry = block.timestamp.add(parameterizer.get("applyStageLen"));
        listing.unstakedDeposit = _amount;

        // Transfers tokens from user to Registry contract
        require(token.transferFrom(listing.owner, address(this), _amount));

        emit _Application(_listingHash, _amount, listing.applicationExpiry, _data, msg.sender);
    }

    /**
    @dev                Allows the owner of a listingHash to increase their unstaked deposit.
    @param _listingHash A listingHash msg.sender is the owner of
    @param _amount      The number of ERC20 tokens to increase a user's unstaked deposit
    */
    function deposit(bytes32 _listingHash, uint256 _amount) external {
        Listing storage listing = listings[_listingHash];

        require(listing.owner == msg.sender);

        listing.unstakedDeposit += _amount;
        require(token.transferFrom(msg.sender, address(this), _amount));

        emit _Deposit(_listingHash, _amount, listing.unstakedDeposit, msg.sender);
    }

    /**
    @dev                Allows the owner of a listingHash to decrease their unstaked deposit.
    @param _listingHash A listingHash msg.sender is the owner of.
    @param _amount      The number of ERC20 tokens to withdraw from the unstaked deposit.
    */
    function withdraw(bytes32 _listingHash, uint256 _amount) external {
        Listing storage listing = listings[_listingHash];

        require(listing.owner == msg.sender);
        require(_amount <= listing.unstakedDeposit);
        require(listing.unstakedDeposit - _amount >= parameterizer.get("minDeposit"));

        listing.unstakedDeposit -= _amount;
        require(token.transfer(msg.sender, _amount));

        emit _Withdrawal(_listingHash, _amount, listing.unstakedDeposit, msg.sender);
    }

    /**
    @dev		Initialize an exit timer for a listing to leave the whitelist
    @param _listingHash	A listing hash msg.sender is the owner of
    */
    function initExit(bytes32 _listingHash) external {	
        Listing storage listing = listings[_listingHash];

        require(msg.sender == listing.owner);
        require(isWhitelisted(_listingHash));
        // Cannot exit during ongoing challenge
        require(listing.challengeID == 0 || challenges[listing.challengeID].resolved);

        // Ensure user never initializedExit or exitPeriodLen passed
        require(listing.exitTime == 0 || block.timestamp > listing.exitTimeExpiry);

        // Set when the listing may be removed from the whitelist
        listing.exitTime = block.timestamp.add(parameterizer.get("exitTimeDelay"));
	// Set exit period end time
	listing.exitTimeExpiry = listing.exitTime.add(parameterizer.get("exitPeriodLen"));
        emit _ExitInitialized(_listingHash, listing.exitTime,
            listing.exitTimeExpiry, msg.sender);
    }

    /**
    @dev		Allow a listing to leave the whitelist
    @param _listingHash A listing hash msg.sender is the owner of
    */
    function finalizeExit(bytes32 _listingHash) external {
        Listing storage listing = listings[_listingHash];

        require(msg.sender == listing.owner);
        require(isWhitelisted(_listingHash));
        // Cannot exit during ongoing challenge
        require(listing.challengeID == 0 || challenges[listing.challengeID].resolved);

        // Make sure the exit was initialized
        require(listing.exitTime > 0);
        // Time to exit has to be after exit delay but before the exitPeriodLen is over 
	require(listing.exitTime < block.timestamp && block.timestamp < listing.exitTimeExpiry);

        resetListing(_listingHash);
        emit _ListingWithdrawn(_listingHash, msg.sender);
    }

    // -----------------------
    // TOKEN HOLDER INTERFACE:
    // -----------------------

    /**
    @dev                Starts a poll for a listingHash which is either in the apply stage or
                        already in the whitelist. Tokens are taken from the challenger and the
                        applicant's deposits are locked.
    @param _listingHash The listingHash being challenged, whether listed or in application
    @param _data        Extra data relevant to the challenge. Think IPFS hashes.
    */
    function challenge(bytes32 _listingHash, string memory _data) external returns (uint256 challengeID) {
        Listing storage listing = listings[_listingHash];
        uint256 minDeposit = parameterizer.get("minDeposit");

        // Listing must be in apply stage or already on the whitelist
        require(appWasMade(_listingHash) || listing.whitelisted);
        // Prevent multiple challenges
        require(listing.challengeID == 0 || challenges[listing.challengeID].resolved);

        if (listing.unstakedDeposit < minDeposit) {
            // Not enough tokens, listingHash auto-delisted
            resetListing(_listingHash);
            emit _TouchAndRemoved(_listingHash);
            return 0;
        }

        // Starts poll
        uint256 pollID = voting.startPoll(
            parameterizer.get("voteQuorum"),
            parameterizer.get("commitStageLen"),
            parameterizer.get("revealStageLen")
        );

        uint256 oneHundred = 100; // Kludge that we need to use SafeMath
        Challenge storage c = challenges[pollID];
        c.challenger = msg.sender;
        c.rewardPool = ((oneHundred.sub(parameterizer.get("dispensationPct"))).mul(minDeposit)).div(100);
        c.stake = minDeposit;
        c.resolved = false;
        c.totalTokens = 0;
    

        // Updates listingHash to store most recent challenge
        listing.challengeID = pollID;

        // Locks tokens for listingHash during challenge
        listing.unstakedDeposit -= minDeposit;

        // Takes tokens from challenger
        require(token.transferFrom(msg.sender, address(this), minDeposit));

        (uint256 commitEndDate, uint256 revealEndDate,,,) = voting.pollMap(pollID);

        emit _Challenge(_listingHash, pollID, _data, commitEndDate, revealEndDate, msg.sender);
        return pollID;
    }

    /**
    @dev                Updates a listingHash's status from 'application' to 'listing' or resolves
                        a challenge if one exists.
    @param _listingHash The listingHash whose status is being updated
    */
    function updateStatus(bytes32 _listingHash) public {
        if (canBeWhitelisted(_listingHash)) {
            whitelistApplication(_listingHash);
        } else if (challengeCanBeResolved(_listingHash)) {
            resolveChallenge(_listingHash);
        } else {
            revert();
        }
    }

    /**
    @dev                  Updates an array of listingHashes' status from 'application' to 'listing' or resolves
                          a challenge if one exists.
    @param _listingHashes The listingHashes whose status are being updated
    */
    function updateStatuses(bytes32[] calldata _listingHashes) public {
        // loop through arrays, revealing each individual vote values
        for (uint256 i = 0; i < _listingHashes.length; i++) {
            updateStatus(_listingHashes[i]);
        }
    }

    // ----------------
    // TOKEN FUNCTIONS:
    // ----------------

    /**
    @dev                Called by a voter to claim their reward for each completed vote. Someone
                        must call updateStatus() before this can be called.
    @param _challengeID The PLCR pollID of the challenge a reward is being claimed for
    */
    function claimReward(uint256 _challengeID) public {
        Challenge storage challengeInstance = challenges[_challengeID];
        // Ensures the voter has not already claimed tokens and challengeInstance results have
        // been processed
        require(challengeInstance.tokenClaims[msg.sender] == false);
        require(challengeInstance.resolved == true);

        uint256 voterTokens = voting.getNumPassingTokens(msg.sender, _challengeID);
        uint256 reward = voterTokens.mul(challengeInstance.rewardPool)
                      .div(challengeInstance.totalTokens);

        // Subtracts the voter's information to preserve the participation ratios
        // of other voters compared to the remaining pool of rewards
        challengeInstance.totalTokens -= voterTokens;
        challengeInstance.rewardPool -= reward;

        // Ensures a voter cannot claim tokens again
        challengeInstance.tokenClaims[msg.sender] = true;

        require(token.transfer(msg.sender, reward));

        emit _RewardClaimed(_challengeID, reward, msg.sender);
    }

    /**
    @dev                 Called by a voter to claim their rewards for each completed vote. Someone
                         must call updateStatus() before this can be called.
    @param _challengeIDs The PLCR pollIDs of the challenges rewards are being claimed for
    */
    function claimRewards(uint256[] calldata _challengeIDs) public {
        // loop through arrays, claiming each individual vote reward
        for (uint256 i = 0; i < _challengeIDs.length; i++) {
            claimReward(_challengeIDs[i]);
        }
    }

    // --------
    // GETTERS:
    // --------

    /**
    @dev                Calculates the provided voter's token reward for the given poll.
    @param _voter       The address of the voter whose reward balance is to be returned
    @param _challengeID The pollID of the challenge a reward balance is being queried for
    @return             The uint256 indicating the voter's reward
    */
    function voterReward(address _voter, uint256 _challengeID)
    public view returns (uint256) {
        uint256 totalTokens = challenges[_challengeID].totalTokens;
        uint256 rewardPool = challenges[_challengeID].rewardPool;
        uint256 voterTokens = voting.getNumPassingTokens(_voter, _challengeID);
        return voterTokens.mul(rewardPool).div(totalTokens);
    }

    /**
    @dev                Determines whether the given listingHash be whitelisted.
    @param _listingHash The listingHash whose status is to be examined
    */
    function canBeWhitelisted(bytes32 _listingHash) view public returns (bool) {
        uint256 challengeID = listings[_listingHash].challengeID;

        // Ensures that the application was made,
        // the application period has ended,
        // the listingHash can be whitelisted,
        // and either: the challengeID == 0, or the challenge has been resolved.
        if (
            appWasMade(_listingHash) &&
            listings[_listingHash].applicationExpiry < block.timestamp &&
            !isWhitelisted(_listingHash) &&
            (challengeID == 0 || challenges[challengeID].resolved == true)
        ) { return true; }

        return false;
    }

    /**
    @dev                Returns true if the provided listingHash is whitelisted
    @param _listingHash The listingHash whose status is to be examined
    */
    function isWhitelisted(bytes32 _listingHash) view public returns (bool whitelisted) {
        return listings[_listingHash].whitelisted;
    }

    /**
    @dev                Returns true if apply was called for this listingHash
    @param _listingHash The listingHash whose status is to be examined
    */
    function appWasMade(bytes32 _listingHash) view public returns (bool exists) {
        return listings[_listingHash].applicationExpiry > 0;
    }

    /**
    @dev                Returns true if the application/listingHash has an unresolved challenge
    @param _listingHash The listingHash whose status is to be examined
    */
    function challengeExists(bytes32 _listingHash) view public returns (bool) {
        uint256 challengeID = listings[_listingHash].challengeID;

        return (listings[_listingHash].challengeID > 0 && !challenges[challengeID].resolved);
    }

    /**
    @dev                Determines whether voting has concluded in a challenge for a given
                        listingHash. Throws if no challenge exists.
    @param _listingHash A listingHash with an unresolved challenge
    */
    function challengeCanBeResolved(bytes32 _listingHash) view public returns (bool) {
        uint256 challengeID = listings[_listingHash].challengeID;

        require(challengeExists(_listingHash));

        return voting.pollEnded(challengeID);
    }

    /**
    @dev                Determines the number of tokens awarded to the winning party in a challenge.
    @param _challengeID The challengeID to determine a reward for
    */
    function determineReward(uint256 _challengeID) public view returns (uint256) {
        require(!challenges[_challengeID].resolved && voting.pollEnded(_challengeID));

        // Edge case, nobody voted, give all tokens to the challenger.
        if (voting.getTotalNumberOfTokensForWinningOption(_challengeID) == 0) {
            return 2 * challenges[_challengeID].stake;
        }

        return (2 * challenges[_challengeID].stake) - challenges[_challengeID].rewardPool;
    }

    /**
    @dev                Getter for Challenge tokenClaims mappings
    @param _challengeID The challengeID to query
    @param _voter       The voter whose claim status to query for the provided challengeID
    */
    function tokenClaims(uint256 _challengeID, address _voter) public view returns (bool) {
        return challenges[_challengeID].tokenClaims[_voter];
    }

    // ----------------
    // PRIVATE FUNCTIONS:
    // ----------------

    /**
    @dev                Determines the winner in a challenge. Rewards the winner tokens and
                        either whitelists or de-whitelists the listingHash.
    @param _listingHash A listingHash with a challenge that is to be resolved
    */
    function resolveChallenge(bytes32 _listingHash) private {
        uint256 challengeID = listings[_listingHash].challengeID;

        // Calculates the winner's reward,
        // which is: (winner's full stake) + (dispensationPct * loser's stake)
        uint256 reward = determineReward(challengeID);

        // Sets flag on challenge being processed
        challenges[challengeID].resolved = true;

        // Stores the total tokens used for voting by the winning side for reward purposes
        challenges[challengeID].totalTokens =
            voting.getTotalNumberOfTokensForWinningOption(challengeID);

        // Case: challenge failed
        if (voting.isPassed(challengeID)) {
            whitelistApplication(_listingHash);
            // Unlock stake so that it can be retrieved by the applicant
            listings[_listingHash].unstakedDeposit += reward;

            emit _ChallengeFailed(_listingHash, challengeID, challenges[challengeID].rewardPool, challenges[challengeID].totalTokens);
        }
        // Case: challenge succeeded or nobody voted
        else {
            resetListing(_listingHash);
            // Transfer the reward to the challenger
            require(token.transfer(challenges[challengeID].challenger, reward));

            emit _ChallengeSucceeded(_listingHash, challengeID, challenges[challengeID].rewardPool, challenges[challengeID].totalTokens);
        }
    }

    /**
    @dev                Called by updateStatus() if the applicationExpiry date passed without a
                        challenge being made. Called by resolveChallenge() if an
                        application/listing beat a challenge.
    @param _listingHash The listingHash of an application/listingHash to be whitelisted
    */
    function whitelistApplication(bytes32 _listingHash) private {
        if (!listings[_listingHash].whitelisted) { emit _ApplicationWhitelisted(_listingHash); }
        listings[_listingHash].whitelisted = true;
    }

    /**
    @dev                Deletes a listingHash from the whitelist and transfers tokens back to owner
    @param _listingHash The listing hash to delete
    */
    function resetListing(bytes32 _listingHash) private {
        Listing storage listing = listings[_listingHash];

        // Emit events before deleting listing to check whether is whitelisted
        if (listing.whitelisted) {
            emit _ListingRemoved(_listingHash);
        } else {
            emit _ApplicationRemoved(_listingHash);
        }

        // Deleting listing to prevent reentry
        address owner = listing.owner;
        uint256 unstakedDeposit = listing.unstakedDeposit;
        delete listings[_listingHash];
        
        // Transfers any remaining balance back to the owner
        if (unstakedDeposit > 0){
            require(token.transfer(owner, unstakedDeposit));
        }
    }
}
