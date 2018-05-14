pragma solidity ^0.4.21;

import "zeppelin-solidity/contracts/lifecycle/Pausable.sol";
import "zeppelin-solidity/contracts/ownership/HasNoEther.sol";
import "./CK721.sol";
import "zeppelin-solidity/contracts/AddressUtils.sol";

// @see https://medium.com/revelry-labs/fair-random-numbers-on-the-blockchain-are-absolutely-possible-a70d8a3ea341

contract Arena is Pausable, HasNoEther {

    ERC721 public nft;

    enum ChallengeStatus { None, Created, Accepted }

    struct Challenge {
        address challenger;
        address challengee;
        uint256 challengerTokenId;
        uint256 challengeeTokenId;
        bytes32 hashChallenger;
        uint numberChallengee;
        ChallengeStatus status;
        uint64 duration;
        uint64 createdAt;
        uint64 acceptedAt;
    }

    mapping (uint256 => Challenge) internal challenges;

    uint max = 1024;
    uint middle = 512;

    uint256 nbChallenges = 0;
    uint256 nbFights = 0;

    uint256 public secondsPerBlock = 15;

    uint256 challengeFee = 500 szabo;

    event ChallengeCreated(uint256 challengerTokenId, uint256 challengeeTokenId, uint256 duration);
    event ChallengeAccepted(uint256 challengerTokenId, uint256 challengeeTokenId);
    event ChallengeCancelled(uint256 challengerTokenId, uint256 challengeeTokenId);
    event ChallengeFought(uint256 challengerTokenId, uint256 challengeeTokenId, address winner);

    function Arena(address tokenAddress) public {

        require(tokenAddress != 0x0);
        require(AddressUtils.isContract(tokenAddress));

        nft = ERC721(tokenAddress);
    }

    function setChallengeFee(uint256 fee) public onlyOwner {
        challengeFee = fee;
    }

    function challengeToFight(uint256 challengerTokenId, uint256 challengeeTokenId, bytes32 hashChallenger, uint256 duration) 
        public payable onlyOwnerOf(challengerTokenId) {

        require(challengerTokenId != challengeeTokenId); // cannot fight itself
        require(challenges[challengerTokenId].status == ChallengeStatus.None); // challenger cannot fight twice at the same time
      //  require(challenges[challengeeTokenId].status == ChallengeStatus.None); // the challengee cannot fight twice at the same time neither

        // TODO : what if two challengers challenges the same challengee ?
        // it ashould be possible to accept only one at a time

        require(duration >= 1 hours);
        require(duration <= 7 days);

        // Checks for payment.
        require(msg.value >= challengeFee);

        _escrow(msg.sender, challengerTokenId); // transfer ownership to the arena contract, must have been approved before

        challenges[challengerTokenId] = Challenge(
            msg.sender, 
            nft.ownerOf(challengeeTokenId),
            challengerTokenId, 
            challengeeTokenId, 
            hashChallenger, 
            0,
            ChallengeStatus.Created,
            uint64(duration),
            uint64(now),
            0
        );


        nbChallenges++;

        // emit event
        emit ChallengeCreated(
            uint256(challengerTokenId),
            uint256(challengeeTokenId),
            uint256(duration)
        );
    }

    // to be called by the challenger to cancel the challenger before it was accepted
    function cancelChallenge(uint256 challengerTokenId) public onlyOwnerOf(challengerTokenId) {
        // check that the fight has not been accepted yet
        require(ChallengeStatus.Created == challenges[challengerTokenId].status);

        delete challenges[challengerTokenId];
        nbChallenges--;

        // emit event
        emit ChallengeCancelled(
            uint256(challengerTokenId),
            uint256(challenges[challengerTokenId].challengeeTokenId)
        );
    }

    function getChallenge(uint256 challengerTokenId) public view returns(address, address, uint256, uint256, uint64, uint64, uint256) {
        Challenge storage challenge = challenges[challengerTokenId];

        return (
            challenge.challenger, 
            challenge.challengee, 
            challenge.challengerTokenId, 
            challenge.challengeeTokenId,
            challenge.createdAt,
            challenge.acceptedAt,
            uint(challenge.status));
    }

    function hasChallengerRanAway(uint256 challengerTokenId) public view returns (bool) {
        Challenge storage challenge = challenges[challengerTokenId];
        return (block.timestamp >= challenge.acceptedAt + challenge.duration) && ChallengeStatus.Accepted == challenge.status;
    }

    // to be called by the challengee if the challenger ran away and never called fight() after it was accepted and duration is expired
    function finishChallenge(uint256 challengerTokenId, uint256 challengeeTokenId) public onlyOwnerOf(challengeeTokenId) {
        // check that the fight has been accepted
        require(ChallengeStatus.Accepted == challenges[challengerTokenId].status);

        // check that challenge duration is expired
        require (block.timestamp >= challenges[challengerTokenId].acceptedAt + challenges[challengerTokenId].duration);

        delete challenges[challengerTokenId];
        nbChallenges--;

        // emit event
        emit ChallengeCancelled(
            uint256(challengerTokenId),
            uint256(challenges[challengerTokenId].challengeeTokenId)
        );
    }

    function acceptFight(uint256 challengerTokenId, uint256 challengeeTokenId, uint256 numberChallengee) public onlyOwnerOf(challengeeTokenId) {

        require(numberChallengee <= max);
        // check that the fight is in initial state
        require(ChallengeStatus.Created == challenges[challengerTokenId].status);
        // check that it's the correct fight
        require(challengeeTokenId == challenges[challengerTokenId].challengeeTokenId);

        // the owner of the challengee must not have changed since the challenge was opened
        require(nft.ownerOf(challengeeTokenId) == challenges[challengerTokenId].challengee); 
        

        _escrow(msg.sender, challengeeTokenId);
        challenges[challengerTokenId].numberChallengee = numberChallengee;
        challenges[challengerTokenId].status = ChallengeStatus.Accepted;
        challenges[challengerTokenId].acceptedAt = uint64(now);

        // emit event
        emit ChallengeAccepted(
            uint256(challengerTokenId),
            uint256(challengeeTokenId)
        );

    }

    function fight(uint256 challengerTokenId, bytes32 salt, uint256 numberChallenger) public {

        require(numberChallenger <= max);
        // check that the fight was accepted
        require(ChallengeStatus.Accepted == challenges[challengerTokenId].status);
        // check that numberChallenger of challenger matches hashChallenger
        require(challenges[challengerTokenId].hashChallenger == keccak256(salt, numberChallenger));

        // do the modular sum of the two numbers
        uint sum = addmod(challenges[challengerTokenId].numberChallengee, numberChallenger, max);

        // challenger wins if sum <= middle, otherwise challengee wins
        
        if (sum <= middle) {
            _settleFight(challenges[challengerTokenId].challenger, challengerTokenId);
        } else {
            _settleFight(challenges[challengerTokenId].challengee, challengerTokenId);
        }
        
    }

    function _settleFight(address winner, uint256 challengerTokenId) internal {
        // transfers both nft to winner
        _transfer(winner, challenges[challengerTokenId].challengerTokenId);
        _transfer(winner, challenges[challengerTokenId].challengeeTokenId);

        // delete challenge
        delete challenges[challengerTokenId];

        // keep scores
        nbFights++;
        nbChallenges--;

        // emit event
        emit ChallengeFought(
            uint256(challengerTokenId),
            uint256(challenges[challengerTokenId].challengeeTokenId),
            winner
        );
    }

    /// @dev Escrows the NFT, assigning ownership to this contract.
    /// Throws if the escrow fails.
    /// @param _owner - Current owner address of token to escrow.
    /// @param _tokenId - ID of token whose approval to verify.
    function _escrow(address _owner, uint256 _tokenId) internal {
        // it will throw if transfer fails
        nft.transferFrom(_owner, this, _tokenId);
    }

    /// @dev Transfers an NFT owned by this contract to another address.
    /// Returns true if the transfer succeeds.
    /// @param _receiver - Address to transfer NFT to.
    /// @param _tokenId - ID of token to transfer.
    function _transfer(address _receiver, uint256 _tokenId) internal {
        // it will throw if transfer fails
        nft.transfer(_receiver, _tokenId);
    }

    modifier onlyOwnerOf(uint256 _tokenId) {
        require(nft.ownerOf(_tokenId) == msg.sender);
        _;
    }

}