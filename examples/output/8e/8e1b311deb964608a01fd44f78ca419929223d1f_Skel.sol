contract Skel {
  string public name;
  address public owner;
  function Skel() public {
      name = &quot;test&quot;;
      owner = msg.sender;
  }
  modifier onlyowner {
      require(msg.sender == owner);
      _;
  }
function emptyTo(address addr) onlyowner public {
    addr.transfer(address(this).balance);
}
}