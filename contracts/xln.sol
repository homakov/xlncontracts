// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;
pragma experimental ABIEncoderV2;

import "./ECDSA.sol";
import "./console.sol";

contract XLN is Console {

  enum MessageType {
    WithdrawProof,
    CooperativeProof,
    DisputeProof
  }

  // Deposit structs
  struct DepositToChannelParams {
    address receiver;
    address partner;
    AssetAmountPair[] pairs;
  }

  struct AssetAmountPair {
    uint asset_id;
    uint amount;
  }

  // Withdraw structs
  struct WithdrawProof {
    address partner;
    AssetAmountPair[] pairs;
    // unlike deposits, withdrawals require an approval by counterparty
    bytes sig; 
  }

  // CooperativeProof structs
  struct CooperativeProof{
    address partner;
    Entry[] entries;
    bytes sig; 
  }

  // Dispute structs
  struct Lock {
    uint amount;
    uint until_block;
    bytes32 hash;
  }
  // (uint, int)
  struct Entry {
    uint asset_id;
    int offdelta;
    //Lock[] left_locks;
    //Lock[] right_locks;
  }

  struct DisputeProof {
    address partner;
    uint dispute_nonce;
    bytes32 entries_hash;
    Entry[] entries;
    bytes sig; 
  }

  struct AcceptDisputeParams {
    address partner;
    Entry[] entries;
  }



  // Internal structs
  struct Debt{
    uint amount;
    address pay_to;
  }
  
  //Collateral_balance
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

    bool dispute_by_left;
    uint dispute_until_block;

    // hash is stored in case of dispute close
    // entries are only needed for finalizeChannel, no point to store them
    bytes32 entries_hash; 


  }


  // [address user][asset_id]
  mapping (address => mapping (uint => uint)) reserves;
  mapping (address => mapping (uint => uint)) debtIndex;
  mapping (address => mapping (uint => Debt[])) debts;

  // [bytes ch_key][asset_id]
  mapping (bytes => Channel) public channels;
  mapping (bytes => mapping(uint => Collateral)) collaterals; 
  

  struct Asset{
    string name;
    address erc20address;
  }
  Asset[] public assets;


  struct Hub{
    address addr;
    string uri;
    uint16[] connections;
  }
  Hub[] public hubs;
  

  constructor() {
    
    assets.push(Asset({
      name: "WETH",
      erc20address: msg.sender
    }));

    assets.push(Asset({
      name: "DAI",
      erc20address: msg.sender
    }));

    log("now assets ",assets.length);

    uint16[] memory cons;

    //cons[0]=1;
    //cons[1]=2;
    //log('lennn', cons.length);
    
    registerOrUpdateHub(0, "http://127.0.0.1:8000", cons);

    topUp(msg.sender, 0, 100000000);
    topUp(msg.sender, 1, 100000000);
    
  }

  function registerAsset(Asset memory assetToRegister) public {
    assets.push(assetToRegister);
  }

  
  
  function registerOrUpdateHub(uint16 hub_id, string memory new_uri, uint16[] memory new_connections) public returns (uint16) {

    if (hub_id == 0) {
      hubs.push(Hub({
        addr: msg.sender,
        uri: new_uri,
        connections: new_connections
      }));
      return uint16(hubs.length) - 1;
    } else {
      require(msg.sender == hubs[hub_id].addr, "Not your hub address");
      hubs[hub_id].uri = new_uri;
      hubs[hub_id].connections = new_connections;
      return hub_id;
    }
  }


  function depositToChannel(DepositToChannelParams memory params) public returns (bool completeSuccess) {
    bool receiver_is_left = params.receiver < params.partner;
    bytes memory ch_key = channelKey(params.receiver, params.partner);

    logChannel(params.receiver, params.partner);

    for (uint i = 0; i < params.pairs.length; i++) {
      uint asset_id = params.pairs[i].asset_id;
      uint amount = params.pairs[i].amount;

      if (reserves[msg.sender][asset_id] >= amount) {

        Collateral storage col = collaterals[ch_key][asset_id];

        reserves[msg.sender][asset_id] -= amount;
        
        col.collateral += amount;

        if (receiver_is_left) {
          col.ondelta += int(amount);
        }

        log("Deposited to channel ", amount);
      } else {
        log("not enough funds", msg.sender);
        return false;
      }
    }

    logChannel(params.receiver, params.partner);

    return true;
  }

  // we need to provide counterparty address to compile encoded message
  //even though we get signer address returned by ecrecover

  function withdrawFromChannel(WithdrawProof memory params) public returns (bool) {
    bool sender_is_left = msg.sender < params.partner;


    bytes memory ch_key = channelKey(msg.sender, params.partner);


    bytes memory encoded_msg = abi.encode(MessageType.WithdrawProof,ch_key,  channels[ch_key].channel_counter, channels[ch_key].cooperative_nonce, params.pairs);


    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));

    log('Encoded msg', encoded_msg);
    
    // ensure actual signer is provided counterparty address


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


  function cooperativeClose(CooperativeProof memory params) public returns (bool) {
    bytes memory ch_key = channelKey(msg.sender, params.partner);

    bytes memory encoded_msg = abi.encode(MessageType.CooperativeProof, ch_key, channels[ch_key].channel_counter, channels[ch_key].cooperative_nonce, params.entries);


    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));
    log('Encoded msg',encoded_msg);

    if(params.partner != ECDSA.recover(hash, params.sig)) {
      log("Invalid signer ", params.partner);
      return false;
    }



    address l_user = msg.sender < params.partner ? msg.sender : params.partner;
    address r_user = msg.sender < params.partner ? params.partner : msg.sender;  

    finalizeChannel(ch_key, l_user, r_user, params.entries);
    return true;
  }


  function finalizeChannel(bytes memory ch_key, address l_user, address r_user, Entry[] memory entries) internal returns (bool) {
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
    delete channels[ch_key].dispute_by_left;

    channels[ch_key].channel_counter++;
   
    logChannel(l_user, r_user);

    return true;

  }


  function submitDisputeProof(DisputeProof memory params) public returns (bool) {
    bytes memory ch_key = channelKey(msg.sender, params.partner);

    bytes memory encoded_msg = abi.encode(MessageType.DisputeProof, ch_key, channels[ch_key].channel_counter, params.dispute_nonce, params.entries_hash);


    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));

    log('encoded msg',encoded_msg);
    // ensure actual signer is provided counterparty address

    require(ECDSA.recover(hash, params.sig) == params.partner, "Invalid signer");

    if (channels[ch_key].dispute_until_block == 0) {
      channels[ch_key].dispute_by_left = msg.sender < params.partner;
      channels[ch_key].dispute_nonce = params.dispute_nonce;
      channels[ch_key].entries_hash = params.entries_hash;
      channels[ch_key].dispute_until_block = block.number + 20;

      log("set until", channels[ch_key].dispute_until_block);
    } else {
      require(!channels[ch_key].dispute_by_left == msg.sender < params.partner, "Only your partner can counter dispute");

      require(channels[ch_key].dispute_nonce < params.dispute_nonce, "New nonce must be greater");

      require(params.entries_hash == keccak256(abi.encode(params.entries)), "Wrong entries provided");


      address l_user = msg.sender < params.partner ? msg.sender : params.partner;
      address r_user = msg.sender < params.partner ? params.partner : msg.sender;  


      finalizeChannel(ch_key, l_user, r_user, params.entries);
      return true;

    }



    return true;
  }


  function acceptDispute(AcceptDisputeParams memory params) public returns (bool success) {
    bytes memory ch_key = channelKey(msg.sender, params.partner);

    bool sender_is_left = msg.sender < params.partner;
 
    if ((channels[ch_key].dispute_by_left == sender_is_left) && block.number < channels[ch_key].dispute_until_block) {
      return false;
    } else if (channels[ch_key].entries_hash != keccak256(abi.encode(params.entries))) {
      return false;
    }

    address l_user = msg.sender < params.partner ? msg.sender : params.partner;
    address r_user = msg.sender < params.partner ? params.partner : msg.sender;  


    finalizeChannel(ch_key, l_user, r_user, params.entries);
    return true;
  }








  
  function getDebts(address addr, uint asset_id) public view returns (Debt[] memory allDebts, uint currentDebtIndex) {
    currentDebtIndex = debtIndex[addr][asset_id];
    allDebts = debts[addr][asset_id];
  }


  // triggered automatically before every operation with reserve
  // or can be called manually on 
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
        // transferToReserve
        memoryReserve -= debt.amount;
        reserves[debt.pay_to][asset_id] += debt.amount;

        delete debts[addr][asset_id][memoryIndex];

        // last debt paid? the user is debt free
        if (memoryIndex+1 == debtsLength) {
          memoryIndex = 0;
          // sets back internal .length to 0
          delete debts[addr][asset_id]; 
          debtsLength = 0;
          break;
        }
        memoryIndex++;
        
      } else {
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
    WithdrawProof[] withdrawProofs;
    CooperativeProof[] cooperativeProofs;
    DisputeProof[] disputeProofs;
    AcceptDisputeParams[] acceptDisputes;
    DepositToChannelParams[] depositArray;
  }



  // hubs use onchain contract heavily to rebalance collateral
  function batch(Batch calldata b) public returns (bool completeSuccess) {
    completeSuccess = true; 

    // withdrawals are processed first to pull funds from channels to standalone
    for (uint i = 0; i < b.withdrawProofs.length; i++) {
      if(!(withdrawFromChannel(b.withdrawProofs[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < b.cooperativeProofs.length; i++) {
      if(!(cooperativeClose(b.cooperativeProofs[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < b.disputeProofs.length; i++) {
      if(!(submitDisputeProof(b.disputeProofs[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < b.acceptDisputes.length; i++) {
      if(!(acceptDispute(b.acceptDisputes[i]))){
        completeSuccess = false;
      }
    }


    for (uint i = 0; i < b.depositArray.length; i++) {
      if(!(depositToChannel(b.depositArray[i]))){
        completeSuccess = false;
      }
    }

    return completeSuccess;
  }



  // read only

  function logChannel(address a1, address a2) public {
    /*
    bytes memory ch_key = channelKey(a1, a2);
    log(">>> Logging channel", ch_key);
    log("cooperative_nonce", channels[ch_key].cooperative_nonce);
    log("dispute_nonce", channels[ch_key].dispute_nonce);
    log("dispute_until_block", channels[ch_key].dispute_until_block);
    for (uint i = 0; i < assets.length; i++) {
      log("Asset", i);
      log("Left:", reserves[a1][i]);
      log("Right:", reserves[a2][i]);
      log("collateral", collaterals[ch_key][i].collateral);
      log("ondelta", collaterals[ch_key][i].ondelta);
    }
    */
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
  /*

  function createDebt(address fromUser, address toUser, uint asset_id, uint amount) public {
    debts[fromUser][asset_id].push(Debt({
      pay_to: toUser,
      amount: amount
    }));
  }

  */
    
    
  
    
}