// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;
pragma experimental ABIEncoderV2;

import "./Token.sol";
import "./ECDSA.sol";
import "./console.sol";

contract XLN is Console {
  enum MessageType {
    JSON, // for offchain messages
    WithdrawProof,
    CooperativeProof,
    DisputeProof
  }

  struct AssetAmountPair {
    uint asset_id;
    uint amount;
  }

  struct ReserveToChannel {
    address receiver;
    address partner;
    AssetAmountPair[] pairs;
  }

  struct ChannelToReserve {
    address partner;
    AssetAmountPair[] pairs;
    bytes sig; 
  }

  /*
  struct Lock {
    uint amount;
    uint until_block;
    bytes32 hash;
  }
  */

  struct Entry {
    uint asset_id;
    int offdelta;
    //Lock[] left_locks;
    //Lock[] right_locks;
  }

  struct CooperativeProof{
    address partner;
    Entry[] entries;
    bytes sig; 
  }

  struct DisputeProof {
    address partner;
    uint dispute_nonce;
    bytes32 entries_hash;
    Entry[] entries; 
    bytes sig; 
  }

  struct RevealEntries {
    address partner;
    Entry[] entries;
  }

  // Internal structs
  struct Debt{
    uint amount;
    address pay_to;
  }
  
  struct Collateral {
    uint collateral;
    int ondelta;
  }

  struct Channel{
    // stored indefinitely, incremented every time a channel is closed (dispute or cooperative) 
    // to invalidate all previously created proofs
    uint channel_counter;

    // used for withdrawals and cooperative close
    uint cooperative_nonce;

    // used for dispute (non-cooperative) close 
    uint dispute_nonce;

    bool dispute_started_by_left;
    uint dispute_until_block;

    // hash of entries is stored during dispute close
    // actual entries are only needed to finalizeChannel
    bytes32 entries_hash; 
  }


  // [address user][asset_id]
  mapping (address => mapping (uint => uint)) reserves;
  mapping (address => mapping (uint => uint)) debtIndex;
  mapping (address => mapping (uint => Debt[])) debts;

  // [bytes ch_key][asset_id]
  mapping (bytes => Channel) public channels;
  mapping (bytes => mapping(uint => Collateral)) collaterals; 
  

  mapping(bytes32 => uint) public hash_to_block;


  struct Asset{
    string name;
    address addr;
  }
  Asset[] public assets;


  struct Hub{
    address addr;
    uint gasused;
    string uri;
  }
  Hub[] public hubs;
  

  constructor() {
    
    assets.push(Asset({
      name: "WETH",
      addr: msg.sender
    }));

    assets.push(Asset({
      name: "DAI",
      addr: msg.sender
    }));

    log("now assets ",assets.length);

    // empty hub, hub_id=0 means not a hub
    hubs.push(Hub({
      addr: 0x0000000000000000000000000000000000000000,
      uri: '',
      gasused: 0
    }));
    
    registerHub(0, "http://127.0.0.1:8000");

    topUp(msg.sender, 0, 100000000);
    topUp(msg.sender, 1, 100000000);
  }

  function registerAsset(Asset memory assetToRegister) public {
    //require(Token(assetToRegister.addr).totalSupply() > 0);

    assets.push(assetToRegister);
  }  
  
  function registerHub(uint hub_id, string memory new_uri) public returns (uint) {
    if (hub_id == 0) {
      hubs.push(Hub({
        addr: msg.sender,
        uri: new_uri,
        gasused: 0
      }));
      return hubs.length - 1;
    } else {
      require(msg.sender == hubs[hub_id].addr, "Not your hub address");
      hubs[hub_id].uri = new_uri;
      return hub_id;
    }
  }

  function revealSecret(bytes32 secret) public {
    hash_to_block[keccak256(abi.encode(secret))] = block.number;
  }
  
  // anyone can get gas refund by deleting very old revealed secrets
  function cleanSecret(bytes32 hash) public {
    if (hash_to_block[hash] < block.number - 50000){
      delete hash_to_block[hash];
    }
  }

  struct TokenToReserve{
    address receiver;
    uint asset_id;
    uint amount;
  }
  function tokenToReserve(TokenToReserve memory params) public returns (bool completeSuccess) {
    // todo: allow to delegate to another address
    require(Token(assets[params.asset_id].addr).transferFrom(msg.sender, address(this), params.amount));
    reserves[msg.sender][params.asset_id] += params.amount;
  }

  struct ReserveToToken{
    address receiver;
    uint asset_id;
    uint amount;
  }
  function reserveToToken(ReserveToToken memory params) public returns (bool completeSuccess) {
    enforceDebts(msg.sender, params.asset_id);

    require(reserves[msg.sender][params.asset_id] >= params.amount);
    reserves[msg.sender][params.asset_id] -= params.amount;
    require(Token(assets[params.asset_id].addr).transfer(params.receiver, params.amount));
  }
  struct ReserveToReserve{
    address receiver;
    uint asset_id;
    uint amount;
  }
  function reserveToReserve(ReserveToReserve memory params) public returns (bool completeSuccess) {
    enforceDebts(msg.sender, params.asset_id);

    require(reserves[msg.sender][params.asset_id] >= params.amount);
    reserves[msg.sender][params.asset_id] -= params.amount;
    reserves[params.receiver][params.asset_id] += params.amount;
  }


  function reserveToChannel(ReserveToChannel memory params) public returns (bool completeSuccess) {
    bool receiver_is_left = params.receiver < params.partner;
    bytes memory ch_key = channelKey(params.receiver, params.partner);

    logChannel(params.receiver, params.partner);

    for (uint i = 0; i < params.pairs.length; i++) {
      uint asset_id = params.pairs[i].asset_id;
      uint amount = params.pairs[i].amount;

      // debts must be paid before any transfers from reserve 
      enforceDebts(msg.sender, asset_id);

      if (reserves[msg.sender][asset_id] >= amount) {
        Collateral storage col = collaterals[ch_key][asset_id];

        reserves[msg.sender][asset_id] -= amount;
        
        col.collateral += amount;

        if (receiver_is_left) {
          col.ondelta += int(amount);
        }

        log("Deposited to channel ", amount);
      } else {
        log("Not enough funds", msg.sender);
        return false;
      }
    }

    logChannel(params.receiver, params.partner);

    return true;
  }

  function channelToReserve(ChannelToReserve memory params) public returns (bool) {
    bool sender_is_left = msg.sender < params.partner;
    bytes memory ch_key = channelKey(msg.sender, params.partner);

    bytes memory encoded_msg = abi.encode(MessageType.WithdrawProof,ch_key,  channels[ch_key].channel_counter, channels[ch_key].cooperative_nonce, params.pairs);

    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));

    log('Encoded msg', encoded_msg);
    
    if(params.partner != ECDSA.recover(hash, params.sig)) {
      log("Invalid signer ", params.partner);
      return false;
    }

    channels[ch_key].cooperative_nonce++;

    for (uint i = 0; i < params.pairs.length; i++) {
      uint asset_id = params.pairs[i].asset_id;
      uint amount = params.pairs[i].amount;

      Collateral storage col = collaterals[ch_key][asset_id];

      if (col.collateral >= amount) {
        col.collateral -= amount;
        if (sender_is_left) {
          col.ondelta -= int(amount);
        }

        reserves[msg.sender][asset_id] += amount;
      }
    }

    logChannel(msg.sender, params.partner);
    return true;
  }


  function cooperativeProof(CooperativeProof memory params) public returns (bool) {
    bytes memory ch_key = channelKey(msg.sender, params.partner);

    bytes memory encoded_msg = abi.encode(MessageType.CooperativeProof, ch_key, channels[ch_key].channel_counter, channels[ch_key].cooperative_nonce, params.entries);

    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));
    log('Encoded msg',encoded_msg);

    if(params.partner != ECDSA.recover(hash, params.sig)) {
      log("Invalid signer ", params.partner);
      return false;
    }

    finalizeChannel(msg.sender, params.partner, params.entries);
    return true;
  }

  // gives each user assets to their reserve based on provided entries and stored collaterals
  // then increases channel_counter to invalidate all previous proofs
  function finalizeChannel(address user1, address user2, Entry[] memory entries) internal returns (bool) {
    address l_user;
    address r_user;
    if (user1 < user2) {
      l_user = user1;
      r_user = user2;
    } else {
      l_user = user2;
      r_user = user1;    
    }

    bytes memory ch_key = abi.encodePacked(l_user, r_user);

    logChannel(l_user, r_user);

    // iterate over entries and split the assets
    for (uint i = 0;i<entries.length;i++){
      uint asset_id = entries[i].asset_id;
      Collateral storage col = collaterals[ch_key][asset_id];

      // final delta = offdelta + ondelta + unlocked hashlocks
      int delta = entries[i].offdelta + col.ondelta;

      if (delta >= 0 && uint(delta) <= col.collateral) {
        // Collateral is split (standard no-credit LN resolution)
        uint left_gets = uint(delta);
        reserves[l_user][asset_id] += left_gets;
        reserves[r_user][asset_id] += col.collateral - left_gets;

      } else {
        // one user gets entire collateral, another gets debt (resolution enabled by XLN)
        address getsCollateral = delta < 0 ? r_user : l_user;
        address getsDebt = delta < 0 ? l_user : r_user;
        uint debtAmount = delta < 0 ? uint(-delta) : uint(delta) - col.collateral;

        
        log('gets debt', getsDebt);
        log('debt', debtAmount);

        reserves[getsCollateral][asset_id] += col.collateral;
        if (reserves[getsDebt][asset_id] >= debtAmount) {
          // will pay right away without creating Debt
          reserves[getsCollateral][asset_id] += debtAmount;
          reserves[getsDebt][asset_id] -= debtAmount;
        } else {
          // pay what they can, and create Debt
          if (reserves[getsDebt][asset_id] > 0) {
            reserves[getsCollateral][asset_id] += reserves[getsDebt][asset_id];
            debtAmount -= reserves[getsDebt][asset_id];
            reserves[getsDebt][asset_id] = 0;
          }
          debts[getsDebt][asset_id].push(Debt({
            pay_to: getsCollateral,
            amount: debtAmount
          }));
        }
      }

      delete collaterals[ch_key][asset_id];
    }
    delete channels[ch_key].entries_hash;
    delete channels[ch_key].dispute_nonce;
    delete channels[ch_key].cooperative_nonce;
    delete channels[ch_key].dispute_until_block;
    delete channels[ch_key].dispute_started_by_left;

    channels[ch_key].channel_counter++;
   
    logChannel(l_user, r_user);

    return true;

  }


  function disputeProof(DisputeProof memory params) public returns (bool) {
    bytes memory ch_key = channelKey(msg.sender, params.partner);

    bytes memory encoded_msg = abi.encode(MessageType.DisputeProof, ch_key, channels[ch_key].channel_counter, params.dispute_nonce, params.entries_hash);


    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));

    log('encoded msg',encoded_msg);
    // ensure actual signer is provided counterparty address

    require(ECDSA.recover(hash, params.sig) == params.partner, "Invalid signer");

    if (channels[ch_key].dispute_until_block == 0) {
      channels[ch_key].dispute_started_by_left = msg.sender < params.partner;
      channels[ch_key].dispute_nonce = params.dispute_nonce;
      channels[ch_key].entries_hash = params.entries_hash;

      // todo: hubs get shorter delay
      channels[ch_key].dispute_until_block = block.number + 20;

      log("set until", channels[ch_key].dispute_until_block);
    } else {
      require(!channels[ch_key].dispute_started_by_left == msg.sender < params.partner, "Only your partner can counter dispute");

      require(channels[ch_key].dispute_nonce < params.dispute_nonce, "New nonce must be greater");

      require(params.entries_hash == keccak256(abi.encode(params.entries)), "Wrong entries provided");


      finalizeChannel(msg.sender, params.partner, params.entries);
      return true;

    }



    return true;
  }


  function revealEntries(RevealEntries memory params) public returns (bool success) {
    bytes memory ch_key = channelKey(msg.sender, params.partner);

    bool sender_is_left = msg.sender < params.partner;
 
    if ((channels[ch_key].dispute_started_by_left == sender_is_left) && block.number < channels[ch_key].dispute_until_block) {
      return false;
    } else if (channels[ch_key].entries_hash != keccak256(abi.encode(params.entries))) {
      return false;
    } 

    finalizeChannel(msg.sender, params.partner, params.entries);
    return true;
  }








  
  function getDebts(address addr, uint asset_id) public view returns (Debt[] memory allDebts, uint currentDebtIndex) {
    currentDebtIndex = debtIndex[addr][asset_id];
    allDebts = debts[addr][asset_id];
  }


  // triggered automatically before every reserveToChannel
  // can be called manually if the partner is offline
  // iterates over debts claims, first-in-first-out 
  function enforceDebts(address addr, uint asset_id) public returns (uint totalDebts) {
    uint debtsLength = debts[addr][asset_id].length;
    if (debtsLength == 0) {
      return 0;
    }
   
    uint memoryReserve = reserves[addr][asset_id]; 
    uint memoryIndex = debtIndex[addr][asset_id];
    
    if (memoryReserve == 0){
      return debtsLength - memoryIndex;
    }
    
    while (true) {
      Debt storage debt = debts[addr][asset_id][memoryIndex];
      
      // can pay in full
      if (memoryReserve >= debt.amount) {
        memoryReserve -= debt.amount;
        reserves[debt.pay_to][asset_id] += debt.amount;

        delete debts[addr][asset_id][memoryIndex];

        // last debt paid? the user is debt free
        if (memoryIndex+1 == debtsLength) {
          memoryIndex = 0;
          // resets .length to 0
          delete debts[addr][asset_id]; 
          debtsLength = 0;
          break;
        }
        memoryIndex++;
        
      } else {
        // pay part of the debt
        reserves[debt.pay_to][asset_id] += memoryReserve;
        debt.amount -= memoryReserve;
        memoryReserve = 0;
        break;
      }
    }

    reserves[addr][asset_id] = memoryReserve;
    debtIndex[addr][asset_id] = memoryIndex;
    
    return debtsLength - memoryIndex;
  }





  struct Batch {
    CooperativeProof[] cooperativeProof;
    DisputeProof[] disputeProof;
    RevealEntries[] revealEntries;

    // assets move Token <=> Reserve <=> Channel
    // but never Token <=> Channel. 'reserve' is useful intermediary
    ReserveToChannel[] reserveToChannel;
    ChannelToReserve[] channelToReserve;

    ReserveToToken[] reserveToToken;
    TokenToReserve[] tokenToReserve;
    ReserveToReserve[] reseverToReserve;

    bytes32[] revealSecret;
    uint hub_id;
  }



  // hubs use onchain in batched fashion
  function processBatch(Batch calldata b) public returns (bool completeSuccess) {
    uint startGas = gasleft();

    // the order is important: first go ones that increase reserve
    // then those that deduct from reserve

    completeSuccess = true; 

    for (uint i = 0; i < b.channelToReserve.length; i++) {
      if(!(channelToReserve(b.channelToReserve[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < b.cooperativeProof.length; i++) {
      if(!(cooperativeProof(b.cooperativeProof[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < b.disputeProof.length; i++) {
      if(!(disputeProof(b.disputeProof[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < b.revealEntries.length; i++) {
      if(!(revealEntries(b.revealEntries[i]))){
        completeSuccess = false;
      }
    }


    for (uint i = 0; i < b.reserveToChannel.length; i++) {
      if(!(reserveToChannel(b.reserveToChannel[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < b.revealSecret.length; i++) {
      revealSecret(b.revealSecret[i]);
    }

    // increase gasused for hubs
    // this is hardest to fake metric of real usage
    if (b.hub_id != 0 && msg.sender == hubs[b.hub_id].addr){
      hubs[b.hub_id].gasused += startGas - gasleft();
    }

    return completeSuccess;
  }

  function channelKey(address a1, address a2) public pure returns (bytes memory) {
    //determenistic channel key is 40 bytes: concatenated lowerKey + higherKey
    return a1 < a2 ? abi.encodePacked(a1, a2) : abi.encodePacked(a2, a1);
  }
  
  struct AssetReserveDebts {
    uint reserve;
    Debt[] debts;
    uint debtIndex;
  }
  
  struct UserReturn {
    AssetReserveDebts[] assets;
  }

  function getUser(address addr) external view returns (UserReturn memory) {
    UserReturn memory u = UserReturn({
      assets: new AssetReserveDebts[](assets.length)
    });
    
    for (uint i = 0;i<assets.length;i++){
      u.assets[i]=(AssetReserveDebts({
        reserve: reserves[addr][i],
        debtIndex: debtIndex[addr][i],
        debts: debts[addr][i]
      }));
    }
    
    return u;
  }
  
  struct ChannelReturn{
    bytes channelKey;
    Channel channel;
    Collateral[] collaterals;
  }

  function getChannel(address  a1, address  a2) public view returns (ChannelReturn memory ch) {
    bytes memory ch_key = channelKey(a1, a2);
    ch = ChannelReturn({
      channelKey: ch_key,
      channel: channels[ch_key],
      collaterals: new Collateral[](assets.length)
    });
    

    for (uint i = 0;i<assets.length;i++){
      ch.collaterals[i]=collaterals[ch_key][i];
    }
    
    return ch;
  }
  
  // dev-only helpers
  function topUp(address addr, uint asset_id, uint amount) public {
    reserves[addr][asset_id] += amount;
  }

  function createDebt(address addr, address pay_to, uint asset_id, uint amount) public {
    debts[addr][asset_id].push(Debt({
      pay_to: pay_to,
      amount: amount
    }));
  }

  function logChannel(address a1, address a2) public {
    bytes memory ch_key = channelKey(a1, a2);
    log(">>> Logging channel", ch_key);
    log("cooperative_nonce", channels[ch_key].cooperative_nonce);
    log("dispute_nonce", channels[ch_key].dispute_nonce);
    log("dispute_until_block", channels[ch_key].dispute_until_block);
    for (uint i = 0; i < assets.length; i++) {
      log("Asset", assets[i].name);
      log("Left:", reserves[a1][i]);
      log("Right:", reserves[a2][i]);
      log("collateral", collaterals[ch_key][i].collateral);
      log("ondelta", collaterals[ch_key][i].ondelta);
    }
  }       


}