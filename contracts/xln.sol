pragma solidity >=0.4.25;
pragma experimental ABIEncoderV2;

contract XLN {
  struct Asset{
    string name;
  }


  struct Debt{
    uint amount_left;
    address pay_to;
  }
  
  struct User{
    mapping (uint => uint) standalone;
    Debt[] debts;
    string uri;

  }
  //coverage_balance
  struct Coverage {
    uint collateral;
    uint ondelta;
  }
  
  struct Channel{
    mapping (uint => Coverage) coverages;
    
    uint dispute_nonce;
    uint withdrawal_nonce;
  }

  address ad1 = 0x627306090abaB3A6e1400e9345bC60c78a8BEf57;
  address ad2 = 0xf17f52151EbEF6C7334FAD080c5704D77216b732;

  mapping (bytes => Channel) public channels;
  
  mapping (address => User) users;

  Asset[] public assets;
  
  event L(string);
  constructor() public {
      
    emit L("go");
    
    users[msg.sender].standalone[0] = 1000000000000;


    //channels[channelKey(ad1, ad2)].coverages[0].collateral = 10000;


    for (uint i = 0; i < 2; i++) {
      /*
      assets.push(Asset({
        name: "DAI"
      }));
      */
      


    }
  }
  
  
  
  function depositToChannel(address a1, address a2, uint assetId, uint amount) public returns (Coverage memory cov) {
    require(users[msg.sender].standalone[0] >= amount);
    users[msg.sender].standalone[0] -= amount;
    
    Coverage storage cov = channels[channelKey(a1, a2)].coverages[assetId];
    

    
    cov.collateral += amount;
    if (a1 < a2) {
      cov.ondelta += amount;
    }
    emit L("deposit");


    return cov;
 
  }
  
  
  function withdrawFromChannel(address a2, uint assetId, uint amount) public {
    address a1 = msg.sender;
    Coverage storage cov = channels[channelKey(a1, a2)].coverages[assetId];

    require (cov.collateral >= amount);


    cov.collateral -= amount;
    if (a1 < a2) cov.ondelta -= amount;

    users[a1].standalone[assetId] += amount;
    emit L('withdraw');
  }




  // views
  
  function channelKey(address a1, address a2) public pure returns (bytes memory) {
    //determenistic channel key is 40 bytes: concatenated lowerKey + higherKey
    return a1 < a2 ? abi.encodePacked(a1, a2) : abi.encodePacked(a2, a1);
  }
  /*
  function getChannel(bytes key) public view returns ( Channel memory ch) {
    ch = channels[key];
  }
  */

  function getUser(address a1) external view returns (uint balance) {
    return users[a1].standalone[0];
  }

  //bytes memory key, uint  memory assetId
  
  function getCoverage(address  a1, address  a2, uint assetId) public view returns (Coverage memory cov) {
    cov = channels[channelKey(a1, a2)].coverages[assetId];
  }
  
  
}
  





/*
pragma solidity ^0.4.0;
pragma experimental ABIEncoderV2;

contract XLN {

  struct Asset{
    string name;

  }


  struct User{
    uint standalone;
    
    mapping (address => Channel) channels;
  }
  
  struct Channel{
    uint collateral;
    uint ondelta;

    uint withdrawal_nonce;
  }


  struct Debt{
    uint amount_left;
    address pay_to;
  }

  mapping (address => Bank) public banks;


  constructor() {
    for (uint i = 0; i < 5; i++) {
      assets.push(Asset({
        name: "DAI"
      }))

      users.push(User({

      }))


    }
  }
}
  







  
   
  function openBank(string uri){
    Bank storage b = banks[msg.sender];
    b.uri = uri;
  }
  


   
  function close(bytes pf) {
    Peer p = peers[msg.sender];
    
    // make sure peer is not locked yet
    require(p.until == 0);
    
    // anything in collateral anyway?  
    require(p.capacity > 0);

    if(pf.length > 0){
      var (signer, is_bond, delay, nonce, amount) = verify(pf, 0);
      amount -= p.taken_amount;

      // delayed type
      require(delay == 2);
      
      
      require(p.capacity >= amount);
    }else{
       amount = 0; // hub's part of collateral
       delay = 2;
       nonce = 0;
    }
    
    // prevent replay attack
    require(nonce > p.nonce);
      
      p.until = uint32(getBlock() + TIMEOUT);
      p.nonce = nonce;
      p.amount = amount;
      p.locked_by_peer = true;
      
      // finally let's notify the hub about close event
      // so they could dispute it with latest nonce if needed
      NotifyHubAboutClose(msg.sender, p.amount);
   }
    
    function settle() {
       Peer p = peers[msg.sender];        
       
        // make sure it's locked
        require(p.until > 0);
        
        // if closed by peer, wait timeout
        if(p.locked_by_peer) require(getBlock() > p.until);
        
        uint peerBalance = p.capacity.sub(p.amount);
        ownerBalance = ownerBalance.add(p.amount);
        
        p.amount = 0;
        p.capacity = 0;
        p.until = 0;
        
        // send back to the peer their part
        msg.sender.transfer(peerBalance);
        
    }
    
    // someone posted dispute_proof
    function dispute(bytes pf) {
      Peer p = peers[msg.sender];

      // is locked
      require(p.until > 0);

      // peer can only dispute if closed by hub
      require(p.locked_by_peer == false);
      
        // make sure proof was signed by hub
       var (signer, is_bond, delay, nonce, amount) = verify(pf, 0);
       require(signer == owner);
       
       amount -= p.taken_amount;
       require(amount <= p.capacity);

       // peer can dispute with bigger or same nonce if odd
    require(nonce > p.nonce || (p.nonce == nonce && odd(p.nonce)) );

    
    ownerBalance = ownerBalance.add(amount);
    uint peerBalance = p.capacity.sub(amount);
    
    p.capacity = 0;
    p.amount = 0;
    p.nonce = nonce;
    p.until = 0;

    msg.sender.transfer(peerBalance);        
        
    }
    
    // hub is responsive and approves a transfer
    function transfer(bytes pf, address _peer, address _hub){
      Peer p = peers[msg.sender];

      var (signer, is_bond, delay, nonce, amount) = verify(pf, 0);
      
      require(signer == owner);
      require(delay == 0); // mutual and instant
      require(p.until == 0); // unlocked
      require(p.capacity >= amount); // is there enough collateral
      require(p.instant_nonce == nonce); // no replay
      p.instant_nonce += 1;     
      
      p.capacity = p.capacity.sub(amount);
    }





  
  function rebalance(bytes inputs, address[] outputs, uint[] amounts) onlyOwner {
     // Solidity doesn't support nested arrays yet, so we send instant proofs in one long string
     // and manually extract using offsets
     uint8 total_inputs = uint8(inputs.length / PROOF_LENGTH);
    

    // Step 1: collect collateral to ownerBalance from the peers who gave mutual close proofs
    for(uint8 i = 0; i < total_inputs; i++){
        var (signer, is_bond, delay, nonce, amount) = verify(inputs, i);
        Peer p = peers[signer];
        
        require(delay == 0); // mutual close type
        
        //require(p.until == 0); // unlocked
        require(p.capacity >= amount); // is there enough collateral
        require(p.instant_nonce == nonce); // no replay
        p.instant_nonce += 1;
        
        // first of all we add all amounts to hub balance
        ownerBalance = ownerBalance.add(amount);
        p.capacity = p.capacity.sub(amount);
        
        // amounts in old proofs are summed with net which gives current amount
        // i.e. you have proof with hub's amount = 10, then hub instant closed 5
        // but you can still post amount=10 proof and get the withdrawn -5 deducted 
        p.taken_amount = p.taken_amount.add(amount);
    }
    
    // Step 2: settled bonds must be paid first (first-in-first-out)
    for(i = 0; i < uint8(payBondsFirst.length); i++){
        Bond b = bonds[payBondsFirst[i]];
        
        
    }
    
    // Step 3: send ownerBalance to outputs (increase their collateral)
    // two arrays outputs and amounts work as a mapping
    require(outputs.length == amounts.length);
    
    for(i = 0; i < outputs.length; i++){
        p = peers[outputs[i]];
        
        require(ownerBalance >= amounts[i]);
        ownerBalance = ownerBalance.sub(amounts[i]);
        p.capacity = p.capacity.add(amounts[i]);
        
        // adds to how much bonds were covered in total
        p.given_amount = p.given_amount.add(amounts[i]);
        
    }
    
    

  }
  
  function ownerClose(bytes pf) onlyOwner {
      var (signer, is_bond, delay, nonce, amount) = verify(pf, 0);
      
      Peer storage p = peers[signer];
      
      // make sure peer is not locked
      require(p.until == 0);
    
      require(delay == 2);
      require(p.capacity > 0);
      require(p.capacity >= amount);
      

      
      p.until = uint32(getBlock() + TIMEOUT);
      p.nonce = nonce;
      p.amount = amount;
      p.locked_by_peer = false;
      
      // finally let's notify the peer about close event
      NotifyPeerAboutClose(signer, p.amount);
  }
  
  function ownerSettle(address peer) onlyOwner {
        Peer storage p = peers[peer];
        
        // make sure it's locked
        require(p.until > 0);
        
        // if closed by hub, wait delay
        if(!p.locked_by_peer) require(getBlock() > p.until);

        ownerBalance += p.amount;
        uint peerBalance = p.capacity - p.amount;
        
        p.amount = 0;
        p.capacity = 0;
        p.until = 0;
        
        // send back to the peer their part
        peer.transfer(peerBalance);      
  }


  // owner disputes a close by a peer
  function ownerDispute(bytes pf) onlyOwner {
    var (signer, is_bond, delay, nonce, amount) = verify(pf, 0);
    
    Peer storage p = peers[signer];
    
    // is locked
    require(p.until > 0);
    
    // we can only dispute if close started by peer
    require(p.locked_by_peer);
    
    // owner can dispute with bigger or same nonce if even
    require(nonce > p.nonce || (p.nonce == nonce && !odd(p.nonce)) );
    
    ownerBalance += amount;
    uint peerBalance = p.capacity - amount;
    
    p.capacity = 0;
    p.amount = 0;
    p.nonce = nonce;
    p.until = 0;

    signer.transfer(peerBalance);
  } 
  

    
    
  // parses proof and recovers the signer. delay means type of proof
  // 0 means instant (mutual) close, 1 is bond, 2 is delayed close
  // pf is dynamically sized array that can contain a lot of proofs one by one (nested arrays are not supported) 
  // offset 0..255 

    function verify(bytes pf, uint8 offset) constant returns (address signer, bool is_bond, uint8 delay, uint24 nonce, uint amount) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        // find offset where current proof starts in dynamic bytes array
        uint bytes_offset = offset * PROOF_LENGTH;
        uint8 header;
    
        //amount will be 32->12 bytes soon
        assembly {
            r := mload(add(pf, 32))
            s := mload(add(pf, 64))
            amount := mload(add(pf, 96))
            header := and(mload(add(pf, 97)), 0xff)
            nonce := and(mload(add(pf, 100)), 0xffffff)
            v := and(mload(add(pf, 101)), 0xff)
        }
        
        require(v == 27 || v == 28);
        
        is_bond = (header & 0x80) == 0x80; // works as sign magnitude. -10 is bond
        delay = header & 0x7f; // 0 means instant. 
        
        
        // includes current contract this, and recepient to avoid replay attacks
        bytes32 signed_hash = sha3(msg.sender, amount, header, nonce);
        
        // returns who signed this proof (peer or hub)
        signer = ecrecover(signed_hash, v, r, s);
    }
    
    
    function odd(uint num) constant returns (bool){
        return bool(num % 2 != 0);
    }
    
    function getBlock() constant returns (uint){
        // we should return block.number but in JS VM we immitate with timestamp instread
        return block.timestamp - 1500000000;
    }
    
    


}
*/



