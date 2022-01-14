// SPDX-License-Identifier: MIT
pragma solidity  ^0.8.4;

import "./BEP721.sol";
import "./IBEP20.sol";

interface IMarketplace {
	function getToken() external view returns(address);
    function getMintFeeInTokens() external view returns (uint);
}

contract XWIPNFT is BEP721 {
    using SafeMath for uint256;
    using SafeMath for uint;	

    uint256 public nextTokenId;        
    address public owner;
    address public marketplace; //TBD assign value after marketplace contract is deployed

    struct ItemNFT {
        uint256 tokenId;
        string tokenURI;
        address owner;
    }

    event Minted(uint tokenId, address owner, string tokenURI);

    modifier onlyOwner() {
        require(msg.sender == owner,
        "Function accessible only by the contract owner !!");
        _;
    }     

   constructor(string memory _name, string memory _symbol)
        BEP721(_name, _symbol){ 
        owner = msg.sender;
    }

    function mint(string memory tokenURI) external returns (uint256) {
        uint mintFeeTokens = IMarketplace(marketplace).getMintFeeInTokens();
        IBEP20(IMarketplace(marketplace).getToken()).transferFrom(msg.sender, address(marketplace), mintFeeTokens);  
        uint tokenId = nextTokenId;
        nextTokenId++;
        _mint(msg.sender, tokenId); //TBD use safemint?
        _setTokenURI(tokenId, tokenURI); //TBD add more metadata?
        emit Minted(tokenId, msg.sender, tokenURI);
        return tokenId;
    }

    function getItem(uint tokenId) public view returns(ItemNFT memory) {
        ItemNFT memory item = ItemNFT({
            tokenId : tokenId,
            tokenURI : tokenURI(tokenId),
            owner : ownerOf(tokenId)
        });
        return item;
    }

    function getAllItems() external view returns (ItemNFT[] memory) {
        ItemNFT[] memory list = new ItemNFT[](nextTokenId);
        for (uint i; i < nextTokenId; i ++) {
            list[i] = getItem(i);
        }
        return list;
    }     
    

}