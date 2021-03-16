// SPDX-License-Identifier: MIT
pragma solidity 0.8.0;
pragma experimental ABIEncoderV2;

import "./ConvertLib.sol";
import "./ECDSA.sol";
import "./console.sol";


contract XLN is Console {

  enum MessageType {
    None,
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
  struct Asset{
    string name;
  }


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
    bytes32 entries_hash;

  }

  // hub fees_paid

  // mappings are stored outside of structs because solidity functions cannot return 
  //structs that contain mappings




  // [address user][asset_id]
  mapping (address => mapping (uint => uint)) reserves;
  mapping (address => mapping (uint => uint)) debtIndex;
  mapping (address => mapping (uint => Debt[])) debts;

  // [bytes ch_key][asset_id]
  mapping (bytes => Channel) public channels;
  mapping (bytes => mapping(uint => Collateral)) collaterals;    
 
  

  Asset[] public assets;
  

  constructor() {
    assets.push(Asset({
      name: "WETH"
    }));

    assets.push(Asset({
      name: "DAI"
    }));
 
    reserves[msg.sender][0] = 100000000;
    reserves[msg.sender][1] = 100000000;
    reserves[msg.sender][2] = 100000000;
  }


  function depositToChannel(DepositToChannelParams memory params) public returns (bool) {
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

  function withdrawFromChannel(WithdrawProof memory params) public  returns (bool) {
    bool sender_is_left = msg.sender < params.partner;

    logChannel(msg.sender, params.partner);

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

        log(ConvertLib.uint2str(asset_id), amount);
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

    // ensure actual signer is provided counterparty address

    if(params.partner != ECDSA.recover(hash, params.sig)) {
      log("Invalid signer ", params.partner);
      return false;
    }



    address l_user = msg.sender < params.partner ? msg.sender : params.partner;
    address r_user = msg.sender < params.partner ? params.partner : msg.sender;  

    finalizeChannel(ch_key, l_user, r_user, params.entries);


  }


  function finalizeChannel(bytes memory ch_key, address l_user, address r_user, Entry[] memory entries) internal returns (bool) {
    logChannel(l_user, r_user);

    // iterate over entries and split the assets
    for (uint i = 0;i<entries.length;i++){
      uint asset_id = entries[i].asset_id;
      Collateral storage col = collaterals[ch_key][asset_id];

      // final delta = offdelta + ondelta + unlocked hashlocks
      int delta = entries[i].offdelta + col.ondelta;

      log("delta", delta);
      log("offdelta", entries[i].offdelta);
      
      if (delta >= 0 && delta <= int(col.collateral)) {
        // Collateral is split (standard no-credit LN resolution)
        uint left_gets = uint(delta);
        reserves[l_user][asset_id] += left_gets;
        reserves[r_user][asset_id] += col.collateral - left_gets;


      } else {
        // one user gets entire collateral, another gets debt (resolution enabled by XLN)
        address getsCollateral = delta < 0 ? r_user : l_user;
        address getsDebt = delta < 0 ? l_user : r_user;
        uint debtAmount = delta < 0 ? uint(-delta) : uint(delta) - col.collateral;

        log('gets collateral', getsCollateral);
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
    /*
    log('encoded msg hash',keccak256(encoded_msg));
    log('eth hash',hash);*/

    // ensure actual signer is provided counterparty address

    require(ECDSA.recover(hash, params.sig) == params.partner, "Invalid signer");

    if (channels[ch_key].dispute_until_block == 0) {


      channels[ch_key].dispute_by_left = msg.sender < params.partner;
      channels[ch_key].dispute_nonce = params.dispute_nonce;
      channels[ch_key].entries_hash = params.entries_hash;
      channels[ch_key].dispute_until_block = block.number + 20;

      log("set until",channels[ch_key].dispute_until_block);


    } else {
      require(!channels[ch_key].dispute_by_left == msg.sender < params.partner, "Only your partner can counter dispute");

      require(channels[ch_key].dispute_nonce < params.dispute_nonce, "New nonce must be greater");

      require(params.entries_hash == keccak256(abi.encode(params.entries)), "Wrong entries provided");

      //require(block.number < channels[ch_key].dispute_until_block);


      address l_user = msg.sender < params.partner ? msg.sender : params.partner;
      address r_user = msg.sender < params.partner ? params.partner : msg.sender;  


      finalizeChannel(ch_key, l_user, r_user, params.entries);
      return true;

    }



    return true;
  }


  function acceptDispute(AcceptDisputeParams memory params) public returns (bool) {
    bytes memory ch_key = channelKey(msg.sender, params.partner);

    bool sender_is_left = msg.sender < params.partner;
 
    if ((channels[ch_key].dispute_by_left == sender_is_left) && block.number < channels[ch_key].dispute_until_block) {
      return false;
    } else if (channels[ch_key].entries_hash == keccak256(abi.encode(params.entries))) {

      address l_user = msg.sender < params.partner ? msg.sender : params.partner;
      address r_user = msg.sender < params.partner ? params.partner : msg.sender;  


      finalizeChannel(ch_key, l_user, r_user, params.entries);
      return true;
    }
    
 
  }










  function createDebt(address fromUser, address toUser, uint amount) public {
    debts[fromUser][0].push(Debt({
      pay_to: toUser,
      amount: amount
    }));
    
  }
  
  function getDebts(address fromUser) public view returns (Debt[] memory allDebts, uint memoryIndex) {
    memoryIndex = debtIndex[fromUser][0];
    allDebts = debts[fromUser][0];
  }

  function payDebts(address fromUser, uint top_up) public returns (uint totalDebts) {
    uint debtsLength = debts[fromUser][0].length;
    if (debtsLength == 0) {
      return 0;
    }
   
    uint reserve = reserves[fromUser][0] + top_up; 
    uint memoryIndex = debtIndex[fromUser][0];
    
    if (reserve == 0){
      return debtsLength - memoryIndex;
    }
    
    while (true) {
      Debt storage debt = debts[fromUser][0][memoryIndex];
      
      // can pay in full
      if (reserve >= debt.amount) {
        // transferToReserve
        reserve -= debt.amount;
        reserves[debt.pay_to][0] += debt.amount;

        delete debts[fromUser][0][memoryIndex];

        // last debt paid? the user is debt free
        if (memoryIndex+1 == debtsLength) {
          memoryIndex = 0;
          // sets back internal .length to 0
          delete debts[fromUser][0]; 
          debtsLength = 0;
          break;
        }
        memoryIndex++;
        
      } else {
        reserves[debt.pay_to][0] += reserve;
        debt.amount -= reserve;
        reserve = 0;
        break;
      }
    }

    reserves[fromUser][0] = reserve;
    debtIndex[fromUser][0] = memoryIndex;
    
    return debtsLength - memoryIndex;
  }









  // this is expected to be the most called function 
  // hubs use it to rebalance from big senders to big receivers
  function batchRebalance(
    WithdrawProof[] memory withdrawProofs, 
    CooperativeProof[] memory cooperativeProofs,
    DisputeProof[] memory disputeProofs,
    AcceptDisputeParams[] memory acceptDisputes,
    DepositToChannelParams[] memory depositArray
  ) public returns (bool) {

    bool completeSuccess = true; 


    // withdrawals are processed first to pull funds from channels to standalone
    for (uint i = 0; i < withdrawProofs.length; i++) {
      if(!(withdrawFromChannel(withdrawProofs[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < cooperativeProofs.length; i++) {
      if(!(cooperativeClose(cooperativeProofs[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < disputeProofs.length; i++) {
      if(!(submitDisputeProof(disputeProofs[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < acceptDisputes.length; i++) {
      if(!(acceptDispute(acceptDisputes[i]))){
        completeSuccess = false;
      }
    }


    for (uint i = 0; i < depositArray.length; i++) {
      if(!(depositToChannel(depositArray[i]))){
        completeSuccess = false;
      }
    }

    return completeSuccess;
  }



  // read only

  function logChannel(address a1, address a2) public {
    bytes memory ch_key = channelKey(a1, a2);
    log(">>>Logging channel", ch_key);

    log("cooperative_nonce", channels[ch_key].cooperative_nonce);
    log("dispute_nonce", channels[ch_key].dispute_nonce);
    for (uint i = 0; i < assets.length; i++) {
      log("Asset", i);
      log("L balance", reserves[a1][i]);
      log("R balance", reserves[a2][i]);

      log("collateral", collaterals[ch_key][i].collateral);
      log("ondelta", collaterals[ch_key][i].ondelta);

    }


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
  
  struct User {
    AssetReserveDebts[] assets;
  }

  function getUser(address addr) external view returns (User memory) {
    User memory u = User({
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
  
    
    
    
  
    
}