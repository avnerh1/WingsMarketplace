// SPDX-License-Identifier: MIT
pragma solidity  ^0.8.4;

import "./IBEP20.sol";
import "./IBEP721.sol";
import "./Pancake.sol";
import "./WIPNFT.sol";

contract XWIPMarketplace is IMarketplace {
    using SafeMath for uint256;
    using SafeMath for uint;

//TBD allow it to be upgradable. Maybe use https://eips.ethereum.org/EIPS/eip-1967 ?

    address public token; //testnet: 0x8a9424745056Eb399FD19a0EC26A14316684e274 ?
    address public factory;
    address public swapRouter = 0x10ED43C718714eb63d5aA57B78B54704E256024E; //https://docs.pancakeswap.finance/code/smart-contracts/pancakeswap-exchange/router-v2 //testnet: 0x9Ac64Cc6e4415144C455BD8E4837Fea55603e5c3
    uint256 public mintFeeUSD = 5 * 10**18;    
    address public busd = 0x55d398326f99059fF775485246999027B3197955; //testnet: 0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7
    address public weth; //testnet: 0xae13d989dac2f0debff460ac112a837c89baa7cd
    address private marketWallet; 
    address private teamWallet;
    address public admin;
    bool public priceWithBNBPair; 

    struct NFTListing {
        address collection;
        uint256 tokenId;              
        uint price;
        bool currencyIsToken; //true: pay with token. false: with BNB
        bool forSale;
    }
    uint nextListingIdx;
    uint forsaleItemsCount;
    mapping(uint => NFTListing) listings;

    uint private swapLimit = 100000000000;


     event Listed(address collection, uint tokenId, uint listingId);
    event Removed(uint listingId);
    event Bought(uint listingId, uint price, bool priceInTokens, address buyer);
    event Liquiditied(uint token, uint ETH, uint liquidity, uint time);
    event Swapped(uint WETH, uint token); //TBD more data? listingID, buyer address?

    modifier onlyAdmin() {
        require(msg.sender == admin,
        "Function accessible only by the owner !!");
        _;
    }     

    constructor(address _teamWallet, address _marketWallet,  address _token) {
        admin = msg.sender;
        teamWallet = _teamWallet;
        marketWallet = _marketWallet;        
        token = _token;

        IPancakeRouter02 router = IPancakeRouter02(swapRouter); 
        factory = router.factory();
        weth = router.WETH();        
    }


    function openOffer(address collection, uint tokenId, uint256 price, bool currencyIsToken) external returns (uint) {
        require(IBEP721(collection).getApproved(tokenId) == address(this), "You need to approve the marketplace to use this NFT");

        uint256 listingId = nextListingIdx;
        nextListingIdx++;
        forsaleItemsCount++;

        listings[listingId] = NFTListing(
          collection,
          tokenId,
          price,
          currencyIsToken,
          true
        );

        emit Listed(collection, tokenId, listingId);
        return listingId;
    }

    function removeOffer(uint listingId) external { 
        NFTListing storage listing = listings[listingId];
        require(IBEP721(listing.collection).ownerOf(listing.tokenId)==msg.sender || IBEP721(listing.collection).getApproved(listing.tokenId)==msg.sender, "Item is not owned/approved by you");
        if (listings[listingId].forSale) {
            forsaleItemsCount--;
        }
        listing.forSale = false;
        emit Removed(listingId);
    }             

    function buyNFTWithToken(uint listingId, uint tokenAmount) public {        
        NFTListing storage listing = listings[listingId];
        require(listing.forSale == true, "NFT is not for sale");
        require(listing.currencyIsToken == true, "This NFT is to be paid with tokens");     
        require (tokenAmount >= listing.price, "Token amount is smaller than NFT price");  
        require(IBEP721(listing.collection).getApproved(listing.tokenId) == address(this), "Marketplace is not approved to  control of this NFT");

        IBEP20 _token = IBEP20(token);     
        address buyer = msg.sender;
        address seller = IBEP721(listing.collection).ownerOf(listing.tokenId);

        _token.transferFrom(buyer, seller, tokenAmount * 95 / 100);
        _token.transferFrom(buyer, address(this), tokenAmount * 3 / 100 );
        _token.transferFrom(buyer, marketWallet, tokenAmount / 100);
        _token.transferFrom(buyer, teamWallet, tokenAmount / 100);

        IBEP721(listing.collection).transferFrom(seller, buyer, listing.tokenId); //TBD use safeTransferFrom()?
        IBEP721(listing.collection).approve(address(0), listing.tokenId);
        listing.forSale = false;
        forsaleItemsCount--;      
        emit Bought(listingId, tokenAmount, true, buyer);
        
    }
    
    function buyNFTWithBNB(uint listingId) public payable {
        NFTListing storage listing = listings[listingId];
        require(listing.forSale == true, "NFT is not for sale");
        require(IBEP721(listing.collection).getApproved(listing.tokenId) == address(this), "Marketplace is not in control of this item");
            
        address buyer = msg.sender;
        address seller = IBEP721(listing.collection).ownerOf(listing.tokenId);

        if (listing.currencyIsToken) {
            uint tokenAmount = convertToTokens(listing.price);
            require(tokenAmount >= listing.price, "Sent amount is smaller than NFT price in tokens");

            IBEP20 _token = IBEP20(token);  
            _token.transferFrom(address(this), seller, tokenAmount * 95 / 100);
            _token.transferFrom(address(this), marketWallet, tokenAmount / 100);
            _token.transferFrom(address(this), teamWallet, tokenAmount / 100);            
        } else {
            require(msg.value >= listing.price, "Sent amount is smaller than NFT price");
            payable(seller).transfer(msg.value * 95 / 100);
            payable(marketWallet).transfer(msg.value / 100);
            payable(teamWallet).transfer(msg.value / 100);
        }

        IBEP721(listing.collection).transferFrom(seller, buyer, listing.tokenId);  //TBD use safeTransferFrom()?
        IBEP721(listing.collection).approve(address(0), listing.tokenId);
        listing.forSale = false;
        forsaleItemsCount--;
        emit Bought(listingId, listing.price, listing.currencyIsToken, buyer);

        swapBalanceToTokens();
    }


    function convertToTokens(uint tokenAmount) internal returns (uint) {
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = token;
        IPancakeRouter02 uniswapRouter = IPancakeRouter02(swapRouter);    
        uint[] memory amounts = uniswapRouter.swapETHForExactTokens{value:msg.value}(tokenAmount, path, address(this), block.timestamp);
        // refund leftover coins to user
        (bool success,) = msg.sender.call{value:msg.value - amounts[0]}(""); 
        //msg.sender.transfer(msg.value - amount[0]);
        require(success, "refund when swapping to tokens failed");        
        return amounts[1];
    }

    function getEstimatedCoinsForTokens(uint tokenAmount) public view returns (uint[] memory) {
        address[] memory path = new address[](2);
        path[0] = weth; path[1] = token;
        IPancakeRouter02 uniswapRouter = IPancakeRouter02(swapRouter);    
        return uniswapRouter.getAmountsIn(tokenAmount, path);
    }    

    function swapBalanceToTokens() public returns (uint[] memory){
        uint[] memory amounts;
        if (IPancakeFactory(factory).getPair(token, weth) != address(0)) {
            if (address(this).balance >= swapLimit) {
                address[] memory path = new address[](2);
                path[0] = weth; path[1] = token;    
                IPancakeRouter02 uniswapRouter = IPancakeRouter02(swapRouter);             
                amounts = uniswapRouter.swapExactETHForTokens{value:address(this).balance}(0, path, address(this), block.timestamp);
                emit Swapped(amounts[0], amounts[1]);
            }
        }
        return amounts;
    }   

    
    receive() external payable {}


    function getTotalNFTsCount() external view returns (uint) {
        return nextListingIdx;
    }
    function getForSaleNFTsCount() external view returns (uint) {
        return forsaleItemsCount;
    }

    function getNFTItem(uint listingId) external view returns (NFTListing memory) {
        require(nextListingIdx>listingId, "listingId does not exist");
        NFTListing memory item = listings[listingId]; 
        return item;
    }
    function getAllNFTsByOwner(bool onlyForSale, address owner) external view returns (NFTListing[] memory) {
        uint count;
        for (uint i = 0; i < nextListingIdx; i++) {            
           NFTListing storage item = listings[i]; 
           if ((!onlyForSale || item.forSale) && (owner==address(0) || IBEP721(item.collection).ownerOf(item.tokenId)==owner)) {
                count++;    
           }
        }        
        NFTListing[] memory result = new NFTListing[](count);
        uint j;
        for (uint i = 0; i < nextListingIdx; i++) {            
           NFTListing storage item = listings[i]; 
            if ((!onlyForSale || item.forSale) && (owner==address(0) || IBEP721(item.collection).ownerOf(item.tokenId)==owner)) {
                result[j] = item;
                j++;
            }
        }    
       return result;        
    }    

    
    function getAllNFTsForSale() external view returns (NFTListing[] memory) {
        NFTListing[] memory result = new NFTListing[](forsaleItemsCount);
        uint j;
        for (uint i = 0; i < nextListingIdx; i++) {
            NFTListing storage item = listings[i]; 
            if (item.forSale) {
                result[j] = item;
                j++;
            }
        }
        return result;        
    }   

    function getAllNFTs() external view returns (NFTListing[] memory) {
        NFTListing[] memory result = new NFTListing[](nextListingIdx);
        for (uint i = 0; i < nextListingIdx; i++) {            
            NFTListing storage item = listings[i]; 
            result[i] = item;
        }
        return result;        
    }   

    function getMintFeeInTokens() external view override returns(uint) {
        IPancakeRouter02 uniswapRouter = IPancakeRouter02(swapRouter);    
        uint amountToken;
        if (priceWithBNBPair) {
            address[] memory path = new address[](3);
            path[0] = busd; path[1] = weth; path[2] = token;
            uint[] memory amounts = uniswapRouter.getAmountsOut(mintFeeUSD, path);
            amountToken = amounts[2];            
        } else {
            address[] memory path = new address[](2);
            path[0] = busd; path[1] = token;
            uint[] memory amounts = uniswapRouter.getAmountsOut(mintFeeUSD, path);
            amountToken = amounts[1];
        }
        return amountToken;
    }

    function getToken() external view override returns(address) {
        return token;
    }

    function setMintFeeUSD(uint fee) onlyAdmin external {
        mintFeeUSD = fee;
    }

    function setMintFeeUseBNBPair(bool useBNBPair) onlyAdmin external {
        priceWithBNBPair = useBNBPair;
    }

    function setWETHAddress(address _weth) onlyAdmin external {
        weth = _weth;
    }    

    function setbusdAddress(address _busd) onlyAdmin external {
        busd = _busd;
    }           

    function setTeamWallet(address _teamWallet) onlyAdmin external {
        teamWallet = _teamWallet;
    }   

    function setMarketWallet(address _marketWallet) onlyAdmin external {
        teamWallet = _marketWallet;
    }       



    function setSwapLimit(uint _limit) onlyAdmin external { 
        swapLimit = _limit;
    }

    function getSwapLimit() external view returns(uint) {
        return swapLimit;
    }  

}