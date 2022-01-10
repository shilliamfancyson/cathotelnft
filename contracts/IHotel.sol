pragma solidity ^0.8.0;

interface IHotel {
    // function addManyToBarnAndPack(address account, uint16[] calldata tokenIds)
    //     external;

    function randomCatNapper(uint256 seed) external view returns (address);
}