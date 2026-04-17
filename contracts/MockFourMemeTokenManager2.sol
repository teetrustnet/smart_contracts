// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

contract MockLaunchToken {
    string public name = "Mock FourMeme Token";
    string public symbol = "M4M";
    uint8 public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;

    constructor(address holder, uint256 supply) {
        totalSupply = supply;
        balanceOf[holder] = supply;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockFourMemeTokenManager2 {
    address[] internal _list;

    function createToken(bytes calldata, bytes calldata) external payable {
        MockLaunchToken token = new MockLaunchToken(msg.sender, 1_000_000_000 ether);
        _list.push(address(token));
    }

    function _tokenCount() external view returns (uint256) {
        return _list.length;
    }

    function _tokens(uint256 index) external view returns (address) {
        return _list[index];
    }
}
