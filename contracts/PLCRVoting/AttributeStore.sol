pragma solidity ^0.6.0;

library AttributeStore {
    struct Data {
        mapping(bytes32 => uint) store;
    }

    function getAttribute(Data storage self, bytes32 UUID, string memory attrName) public view returns (uint) {
        bytes32 key = keccak256(abi.encode(UUID,attrName));
        return self.store[key];
    }

    function setAttribute(Data storage self, bytes32 UUID, string memory attrName, uint attrVal) public {
        bytes32 key = keccak256(abi.encode(UUID, attrName));
        self.store[key] = attrVal;
    }
}