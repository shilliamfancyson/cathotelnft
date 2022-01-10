pragma solidity ^0.8.0;
import "./IERC721Receiver.sol";

import "./FISH.sol";
import "./Cat.sol";

contract Hotel is Ownable, IERC721Receiver{

    //struct to store a stake's token, owner, earnings
    struct Stake {
        uint16 tokenId;
        uint80 value;
        address owner;
    }

    //add events
    event TokenStaked(address owner, uint256 tokenId, uint256 value);
    event CatClaimed(uint256 tokenId, uint256 earned, bool unstaked);
    event CatNapperClaimed(uint256 tokenId, uint256 earned, bool unstaked);

    //reference Cat NFT contract
    Cat cat;
    //reference to $FISH contract for minting earnings
    FISH fish;

    // reference to Entropy
    // IEntropy entropy;

    //maps tokenId to stake
    mapping(uint256 => Stake) public hotel;
    //maps rarity to all CatNapper stakes with that rarity
    mapping(uint256 => Stake) public group;
    //track location of CatNapper in group
    mapping(uint256 => uint256) public groupIndices;

    //total rarity scores stakes
    uint256 public totalRarityStaked = 0;
    //any rewards distributed when no CNs are staked
    uint256 public unaccountedRewards = 0;
    //amount of $FISH due for each rarity point staked
    uint256 public fishPerRarityScore = 0;

    uint256 public fishForCN = 0;

    // Cats earn 10000 $FISH per day
    uint256 public constant DAILY_FISH_RATE = 100000000000000000;
    // Cats must have 2 days worth of $FISH to unstake or else it's too hungry
    uint256 public constant MINIMUM_TO_EXIT = 2 days;
    // CatNappers take a 15% tax on all $FISH claimed
    uint256 public constant FISH_CLAIM_TAX_PERCENTAGE = 20;
    // there will only ever be (roughly) 1.8 billion $FISH earned through staking
    uint256 public constant MAXIMUM_GLOBAL_FISH = 1800000000000000000000;

    // amount of $FISH earned so far
    uint256 public totalFishEarned;
    // number of Cats staked in the Hotel
    uint256 public totalCatsStaked;
    // the last time $FISH was claimed
    uint256 public lastClaimTimestamp;

    uint256 public totalCatNappersStaked = 0;

    


    /**
     * @param _cat reference to the Cat NFT contract
     * @param _fish reference to the $FISH token
     */
    constructor(address _cat, address _fish) {
        cat = Cat(_cat);
        fish = FISH(_fish);
    }

    /** STAKING */
    
    /**
     * adds Cat and CatNappers to the Hotel and Group
     * @param account the address of the staker
     * @param tokenIds the IDs of the Cat and CatNappers to stake
     */
    function addManyToHotelAndGroup(address account, uint256[] calldata tokenIds)
        public
    {
        // require(
        //     account == _msgSender() || _msgSender() == address(cat),
        //     "DO NOT GIVE YOUR TOKENS AWAY"
        // );
        // require(tx.origin == _msgSender());

        for (uint256 i = 0; i < tokenIds.length; i++) {
            // to ensure it's not in buffer
            // require(cat.totalSupply() >= tokenIds[i] + cat.maxMintAmount());
            
            if (_msgSender() != address(cat)) {
                // dont do this step if its a mint + stake
                require(
                    cat.ownerOf(tokenIds[i]) == _msgSender(),
                    "NOT YOUR TOKEN"
                );
                //cat.transferFrom(_msgSender(), address(this), tokenIds[i]);
            } else if (tokenIds[i] == 0) {
                continue; // there may be gaps in the array for stolen tokens
            }

            if (isCat(tokenIds[i])){
             _addCatToHotel(account, tokenIds[i]);
            }
            else {
            _addCatNapperToGroup(account, tokenIds[i]);
            }
        }
    }
    
    /**
     * adds a single Sheep to the Barn
     * @param account the address of the staker
     * @param tokenId the ID of the Sheep to add to the Barn
     */
    function _addCatToHotel(address account, uint256 tokenId)
        public
        // whenNotPaused
        // _updateEarnings
    {
        cat.transferFrom(_msgSender(), address(this), tokenId);

        hotel[tokenId] = Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(block.timestamp)
        });
        //cat.approve(address(this), 1);
        totalCatsStaked += 1;
        

        emit TokenStaked(account, tokenId, block.timestamp);
    }

    function _addCatNapperToGroup(address account, uint256 tokenId) public {
        
        cat.transferFrom(_msgSender(), address(this), tokenId);

        group[tokenId] = Stake({
            owner: account,
            tokenId: uint16(tokenId),
            value: uint80(block.timestamp)
        });

        totalCatNappersStaked += 1;

        emit TokenStaked(account, tokenId, block.timestamp);
    }

    /** CLAIMING / UNSTAKING */
    function claimManyFromHotelAndGroup(uint16[] calldata tokenIds, bool unstake)
    external
    // _updateEarnings
    {
        require(tx.origin == _msgSender());

        uint256 owed = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            if (isCat(tokenIds[i])){

            owed += _claimCatFromHotel(tokenIds[i], unstake);

            } else {

            owed += _claimCatNapperFromGroup(tokenIds[i], unstake);

            }
        }

        if (owed == 0) return;

        fish.mint(_msgSender(), owed);
    }


    function _claimCatFromHotel(uint256 tokenId, bool unstake)
    internal
    returns (uint256 owed)
    {
        Stake memory stake = hotel[tokenId];

        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");

        owed = ((block.timestamp - stake.value) * DAILY_FISH_RATE) / 1 days;

        if (unstake){

            //50% chance to have all $FISH stolen
            if (cat.generateSeed(totalCatsStaked,10) > 5){
                _payCatNapperTax(owed);
                owed = 0;
            }
            

            totalCatsStaked -= 1;
                    
            //send back cat
            cat.safeTransferFrom(address(this), _msgSender(), tokenId, "");
            delete hotel[tokenId];
        } else {
            
            _payCatNapperTax((owed * FISH_CLAIM_TAX_PERCENTAGE)/100);

            owed = (owed * (100 - FISH_CLAIM_TAX_PERCENTAGE)) / 100;

            hotel[tokenId] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(block.timestamp)
            });

        
        }
        
        

        emit CatClaimed(tokenId, owed, unstake);

    }

    function _claimCatNapperFromGroup(uint256 tokenId, bool unstake) internal returns (uint256){
        require(
            cat.ownerOf(tokenId) == address(this),
            "NOT THE OWNER"
        );

        Stake memory stake = group[tokenId];

        require(stake.owner == _msgSender(), "SWIPER, NO SWIPING");

        uint256 owed = fishForCN / totalCatNappersStaked;

        if (unstake){
            
            totalCatNappersStaked -= 1;

            

            delete group[tokenId];

            cat.safeTransferFrom(address(this), _msgSender(), tokenId,"");
        } else {
        
            group[tokenId] = Stake({
                owner: _msgSender(),
                tokenId: uint16(tokenId),
                value: uint80(block.timestamp)
            });

        }
        emit CatNapperClaimed(tokenId, owed, unstake);
    }

    function randomCatNapper(uint256 seed) external view returns(address){

        if (totalCatNappersStaked == 0){
            return address(0x0);
        }
        return group[seed % totalCatNappersStaked].owner;


    }

    function isCat(uint256 tokenId) public view returns (bool){
        if (tokenId >= 45000){
            return false;
        }
        return true;
    }

    function _payCatNapperTax(uint256 amount) internal {
        if (totalCatNappersStaked == 0){
            unaccountedRewards += amount;
            return;
        }

        fishForCN += amount + unaccountedRewards;
        unaccountedRewards = 0;
        
    }
    
    function onERC721Received(
        address,
        address from,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        require(from == address(0x0), "Cannot send tokens to Barn directly");
        return IERC721Receiver.onERC721Received.selector;
    }


}