pragma solidity^0.8.0;

import "../..//PLCRVoting/contracts/PLCRVoting.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

contract Parameterizer {
    // ------
    // EVENTS
    // ------

    event _ReparameterizationProposal(string name, uint256 value, bytes32 propID, uint256 deposit, uint256 appEndDate, address indexed proposer);
    event _NewChallenge(bytes32 indexed propID, uint256 challengeID, uint256 commitEndDate, uint256 revealEndDate, address indexed challenger);
    event _ProposalAccepted(bytes32 indexed propID, string name, uint256 value);
    event _ProposalExpired(bytes32 indexed propID);
    event _ChallengeSucceeded(bytes32 indexed propID, uint256 indexed challengeID, uint256 rewardPool, uint256 totalTokens);
    event _ChallengeFailed(bytes32 indexed propID, uint256 indexed challengeID, uint256 rewardPool, uint256 totalTokens);
    event _RewardClaimed(uint256 indexed challengeID, uint256 reward, address indexed voter);

    // ------
    // DATA STRUCTURES
    // ------

    using SafeMath for uint256;

    struct ParamProposal {
        uint256 appExpiry;
        uint256 challengeID;
        uint256 deposit;
        string name;
        address owner;
        uint256 processBy;
        uint256 value;
    }

    struct Challenge {
        uint256 rewardPool;        // (remaining) pool of tokens distributed amongst winning voters
        address challenger;     // owner of Challenge
        bool resolved;          // indication of if challenge is resolved
        uint256 stake;             // number of tokens at risk for either party during challenge
        uint256 winningTokens;     // (remaining) amount of tokens used for voting by the winning side
        mapping(address => bool) tokenClaims;
    }

    // ------
    // STATE
    // ------

    mapping(bytes32 => uint256) public params;

    // maps challengeIDs to associated challenge data
    mapping(uint256 => Challenge) public challenges;

    // maps pollIDs to intended data change if poll passes
    mapping(bytes32 => ParamProposal) public proposals;

    // Global Variables
    IERC20 public token;
    PLCRVoting public voting;
    uint256 public PROCESSBY = 604800; // 7 days

    /**
    @dev Initializer        Can only be called once
    @param _token           The address where the ERC20 token contract is deployed
    @param _plcr            address of a PLCR voting contract for the provided token
    @notice _parameters     array of canonical parameters
    */
    function init(
        address _token,
        address _plcr,
        uint256[] calldata _parameters
    ) public {
        require(_token != address(0) && address(token) == address(0));
        require(_plcr != address(0) && address(voting) == address(0));

        token = IERC20(_token);
        voting = PLCRVoting(_plcr);

        // minimum deposit for listing to be whitelisted
        set("minDeposit", _parameters[0]);
        
        // minimum deposit to propose a reparameterization
        set("pMinDeposit", _parameters[1]);

        // period over which applicants wait to be whitelisted
        set("applyStageLen", _parameters[2]);

        // period over which reparmeterization proposals wait to be processed
        set("pApplyStageLen", _parameters[3]);

        // length of commit period for voting
        set("commitStageLen", _parameters[4]);
        
        // length of commit period for voting in parameterizer
        set("pCommitStageLen", _parameters[5]);
        
        // length of reveal period for voting
        set("revealStageLen", _parameters[6]);

        // length of reveal period for voting in parameterizer
        set("pRevealStageLen", _parameters[7]);

        // percentage of losing party's deposit distributed to winning party
        set("dispensationPct", _parameters[8]);

        // percentage of losing party's deposit distributed to winning party in parameterizer
        set("pDispensationPct", _parameters[9]);

        // type of majority out of 100 necessary for candidate success
        set("voteQuorum", _parameters[10]);

        // type of majority out of 100 necessary for proposal success in parameterizer
        set("pVoteQuorum", _parameters[11]);

        // minimum length of time user has to wait to exit the registry 
        set("exitTimeDelay", _parameters[12]);

        // maximum length of time user can wait to exit the registry
        set("exitPeriodLen", _parameters[13]);
    }

    // -----------------------
    // TOKEN HOLDER INTERFACE
    // -----------------------

    /**
    @notice propose a reparamaterization of the key _name's value to _value.
    @param _name the name of the proposed param to be set
    @param _value the proposed value to set the param to be set
    */
    function proposeReparameterization(string calldata _name, uint256 _value) public returns (bytes32) {
        uint256 deposit = get("pMinDeposit");
        bytes32 propID = keccak256(abi.encodePacked(_name, _value));

        if (keccak256(abi.encodePacked(_name)) == keccak256(abi.encodePacked("dispensationPct")) ||
            keccak256(abi.encodePacked(_name)) == keccak256(abi.encodePacked("pDispensationPct"))) {
            require(_value <= 100);
        }

        require(!propExists(propID)); // Forbid duplicate proposals
        require(get(_name) != _value); // Forbid NOOP reparameterizations

        // attach name and value to pollID
        proposals[propID] = ParamProposal({
            appExpiry: block.timestamp.add(get("pApplyStageLen")),
            challengeID: 0,
            deposit: deposit,
            name: _name,
            owner: msg.sender,
            processBy: block.timestamp.add(get("pApplyStageLen"))
                .add(get("pCommitStageLen"))
                .add(get("pRevealStageLen"))
                .add(PROCESSBY),
            value: _value
        });

        require(token.transferFrom(msg.sender, address(this), deposit)); // escrow tokens (deposit amt)

        emit _ReparameterizationProposal(_name, _value, propID, deposit, proposals[propID].appExpiry, msg.sender);
        return propID;
    }

    /**
    @notice challenge the provided proposal ID, and put tokens at stake to do so.
    @param _propID the proposal ID to challenge
    */
    function challengeReparameterization(bytes32 _propID) public returns (uint256 challengeID) {
        ParamProposal memory prop = proposals[_propID];
        uint256 deposit = prop.deposit;

        require(propExists(_propID) && prop.challengeID == 0);

        //start poll
        uint256 pollID = voting.startPoll(
            get("pVoteQuorum"),
            get("pCommitStageLen"),
            get("pRevealStageLen")
        );

        Challenge storage c = challenges[pollID];
        c.challenger = msg.sender;
        c.rewardPool = SafeMath.sub(100, get("pDispensationPct")).mul(deposit).div(100);
        c.stake = deposit;
        c.resolved = false;
        c.winningTokens = 0;

        proposals[_propID].challengeID = pollID;       // update listing to store most recent challenge

        //take tokens from challenger
        require(token.transferFrom(msg.sender, address(this), deposit));

        (uint256 commitEndDate, uint256 revealEndDate,,,) = voting.pollMap(pollID);

        emit _NewChallenge(_propID, pollID, commitEndDate, revealEndDate, msg.sender);
        return pollID;
    }

    /**
    @notice             for the provided proposal ID, set it, resolve its challenge, or delete it depending on whether it can be set, has a challenge which can be resolved, or if its "process by" date has passed
    @param _propID      the proposal ID to make a determination and state transition for
    */
    function processProposal(bytes32 _propID) public {
        ParamProposal storage prop = proposals[_propID];
        address propOwner = prop.owner;
        uint256 propDeposit = prop.deposit;

        
        // Before any token transfers, deleting the proposal will ensure that if reentrancy occurs the
        // prop.owner and prop.deposit will be 0, thereby preventing theft
        if (canBeSet(_propID)) {
            // There is no challenge against the proposal. The processBy date for the proposal has not
            // passed, but the proposal's appExpirty date has passed.
            set(prop.name, prop.value);
            emit _ProposalAccepted(_propID, prop.name, prop.value);
            delete proposals[_propID];
            require(token.transfer(propOwner, propDeposit));
        } else if (challengeCanBeResolved(_propID)) {
            // There is a challenge against the proposal.
            resolveChallenge(_propID);
        } else if (block.timestamp > prop.processBy) {
            // There is no challenge against the proposal, but the processBy date has passed.
            emit _ProposalExpired(_propID);
            delete proposals[_propID];
            require(token.transfer(propOwner, propDeposit));
        } else {
            // There is no challenge against the proposal, and neither the appExpiry date nor the
            // processBy date has passed.
            revert();
        }

        assert(get("dispensationPct") <= 100);
        assert(get("pDispensationPct") <= 100);

        // verify that future proposal appExpiry and processBy times will not overflow
        block.timestamp.add(get("pApplyStageLen"))
            .add(get("pCommitStageLen"))
            .add(get("pRevealStageLen"))
            .add(PROCESSBY);

        delete proposals[_propID];
    }

    /**
    @notice                 Claim the tokens owed for the msg.sender in the provided challenge
    @param _challengeID     the challenge ID to claim tokens for
    */
    function claimReward(uint256 _challengeID) public {
        Challenge storage challenge = challenges[_challengeID];
        // ensure voter has not already claimed tokens and challenge results have been processed
        require(challenge.tokenClaims[msg.sender] == false);
        require(challenge.resolved == true);

        uint256 voterTokens = voting.getNumPassingTokens(msg.sender, _challengeID);
        uint256 reward = voterReward(msg.sender, _challengeID);

        // subtract voter's information to preserve the participation ratios of other voters
        // compared to the remaining pool of rewards
        challenge.winningTokens -= voterTokens;
        challenge.rewardPool -= reward;

        // ensures a voter cannot claim tokens again
        challenge.tokenClaims[msg.sender] = true;

        emit _RewardClaimed(_challengeID, reward, msg.sender);
        require(token.transfer(msg.sender, reward));
    }

    /**
    @dev                    Called by a voter to claim their rewards for each completed vote.
                            Someone must call updateStatus() before this can be called.
    @param _challengeIDs    The PLCR pollIDs of the challenges rewards are being claimed for
    */
    function claimRewards(uint256[] calldata _challengeIDs) public {
        // loop through arrays, claiming each individual vote reward
        for (uint256 i = 0; i < _challengeIDs.length; i++) {
            claimReward(_challengeIDs[i]);
        }
    }

    // --------
    // GETTERS
    // --------

    /**
    @dev                Calculates the provided voter's token reward for the given poll.
    @param _voter       The address of the voter whose reward balance is to be returned
    @param _challengeID The ID of the challenge the voter's reward is being calculated for
    @return             The uint256 indicating the voter's reward
    */
    function voterReward(address _voter, uint256 _challengeID)
    public view returns (uint256) {
        uint256 winningTokens = challenges[_challengeID].winningTokens;
        uint256 rewardPool = challenges[_challengeID].rewardPool;
        uint256 voterTokens = voting.getNumPassingTokens(_voter, _challengeID);
        return (voterTokens * rewardPool) / winningTokens;
    }

    /**
    @notice Determines whether a proposal passed its application stage without a challenge
    @param _propID The proposal ID for which to determine whether its application stage passed without a challenge
    */
    function canBeSet(bytes32 _propID) view public returns (bool) {
        ParamProposal memory prop = proposals[_propID];

        return (block.timestamp > prop.appExpiry && block.timestamp < prop.processBy && prop.challengeID == 0);
    }

    /**
    @notice Determines whether a proposal exists for the provided proposal ID
    @param _propID The proposal ID whose existance is to be determined
    */
    function propExists(bytes32 _propID) view public returns (bool) {
        return proposals[_propID].processBy > 0;
    }

    /**
    @notice Determines whether the provided proposal ID has a challenge which can be resolved
    @param _propID The proposal ID whose challenge to inspect
    */
    function challengeCanBeResolved(bytes32 _propID) view public returns (bool) {
        ParamProposal storage prop = proposals[_propID];
        Challenge storage challenge = challenges[prop.challengeID];

        return (prop.challengeID > 0 && challenge.resolved == false && voting.pollEnded(prop.challengeID));
    }

    /**
    @notice Determines the number of tokens to awarded to the winning party in a challenge
    @param _challengeID The challengeID to determine a reward for
    */
    function challengeWinnerReward(uint256 _challengeID) public view returns (uint256) {
        if(voting.getTotalNumberOfTokensForWinningOption(_challengeID) == 0) {
            // Edge case, nobody voted, give all tokens to the challenger.
            return 2 * challenges[_challengeID].stake;
        }

        return (2 * challenges[_challengeID].stake) - challenges[_challengeID].rewardPool;
    }

    /**
    @notice gets the parameter keyed by the provided name value from the params mapping
    @param _name the key whose value is to be determined
    */
    function get(string memory _name) public view returns (uint256 value) {
        return params[keccak256(abi.encodePacked(_name))];
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
    // PRIVATE FUNCTIONS
    // ----------------

    /**
    @dev resolves a challenge for the provided _propID. It must be checked in advance whether the _propID has a challenge on it
    @param _propID the proposal ID whose challenge is to be resolved.
    */
    function resolveChallenge(bytes32 _propID) private {
        ParamProposal memory prop = proposals[_propID];
        Challenge storage challenge = challenges[prop.challengeID];

        // winner gets back their full staked deposit, and dispensationPct*loser's stake
        uint256 reward = challengeWinnerReward(prop.challengeID);

        challenge.winningTokens = voting.getTotalNumberOfTokensForWinningOption(prop.challengeID);
        challenge.resolved = true;

        if (voting.isPassed(prop.challengeID)) { // The challenge failed
            if(prop.processBy > block.timestamp) {
                set(prop.name, prop.value);
            }
            emit _ChallengeFailed(_propID, prop.challengeID, challenge.rewardPool, challenge.winningTokens);
            require(token.transfer(prop.owner, reward));
        }
        else { // The challenge succeeded or nobody voted
            emit _ChallengeSucceeded(_propID, prop.challengeID, challenge.rewardPool, challenge.winningTokens);
            require(token.transfer(challenges[prop.challengeID].challenger, reward));
        }
    }

    /**
    @dev sets the param keted by the provided name to the provided value
    @param _name the name of the param to be set
    @param _value the value to set the param to be set
    */
    function set(string memory _name, uint256 _value) private {
        params[keccak256(abi.encodePacked(_name))] = _value;
    }
}
