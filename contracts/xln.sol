// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "./ConvertLib.sol";
import "./ECDSA.sol";
import "./console.sol";

contract XLN is Console{
  enum MessageType {
    None,
    DisputeProof,
    InstantDisputeProof,
    Withdraw
  }

  // Deposit structs
  struct DepositToChannelParams {
    address a1;
    address a2;
    AssetAmountPair[] pairs;
  }

  struct AssetAmountPair {
    uint asset_id;
    uint amount;
  }

  // Withdraw structs
  struct WithdrawFromChannelParams {
    // a1 is implied to be msg.sender
    // You can't withdraw from channel you don't participate in

    address a2;
    uint withdraw_nonce;
    AssetAmountPair[] pairs;

    // unlike deposits, withdrawals require an approval by counterparty
    bytes sig; 
  }

  // Dispute structs
  struct Lock {
    uint amount;
    uint until_block;
    bytes32 hash;
  }
  // (uint, int)
  struct Offdelta {
    uint asset_id;
    int offdelta;
    //Lock[] left_locks;
    //Lock[] right_locks;
  }

  struct StartDisputeParams {
    address a2;
    uint dispute_nonce;

    Offdelta[] offdeltas;

    bytes sig; 
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
    uint withdraw_nonce;

    uint dispute_nonce;
    uint dispute_until_block;
    bytes32 hash_outcome_proposed;
    bool dispute_by_left;

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

  // [bytes ch_key]

  

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
    bool a1_is_left = params.a1 < params.a2;

    log('enum type', uint(MessageType.Withdraw));
    logChannel(params.a1, params.a2);

    for (uint i = 0; i < params.pairs.length; i++) {
      uint asset_id = params.pairs[i].asset_id;
      uint amount = params.pairs[i].amount;

      if (reserves[msg.sender][asset_id] >= amount) {

        Collateral storage col = collaterals[channelKey(params.a1, params.a2)][asset_id];

        reserves[msg.sender][asset_id] -= amount;
        
        col.collateral += amount;

        if (a1_is_left) {
          col.ondelta += int(amount);
          log('new ondelta', col.ondelta);
        }

        log("Deposited to channel ", amount);
      } else {
        log("not enough funds", msg.sender);
        return false;
      }
    }

    logChannel(params.a1, params.a2);

    return true;
  }

  // we need to provide counterparty address to compile encoded message
  //even though we get signer address returned by ecrecover

  function withdrawFromChannel(WithdrawFromChannelParams memory params) public  returns (bool) {
    address a1 = msg.sender;
    bool a1_is_left = a1 < params.a2;

    logChannel(a1, params.a2);

    bytes memory ch_key = channelKey(a1, params.a2);


    bytes memory encoded_msg = abi.encode(ch_key, channels[ch_key].withdraw_nonce, params.pairs);


    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));

    log('encoded msg',encoded_msg);
    
    // ensure actual signer is provided counterparty address

    address signer = ECDSA.recover(hash, params.sig);
    log('signer', signer);

    if(params.a2 != signer) {
      log("proposed signer ", params.a2);
      log("Invalid signer", signer);
      return false;
    }

    channels[ch_key].withdraw_nonce++;


    for (uint i = 0; i < params.pairs.length; i++) {
      uint asset_id = params.pairs[i].asset_id;
      uint amount = params.pairs[i].amount;

      Collateral storage col = collaterals[ch_key][asset_id];

      if (col.collateral >= amount) {
        col.collateral -= amount;
        if (a1_is_left) {
          col.ondelta -= int(amount);
        }

        reserves[a1][asset_id] += amount;

        log(ConvertLib.uint2str(asset_id), amount);
      }
    }

    logChannel(a1, params.a2);

    return true;
    
  }



  function startDispute(StartDisputeParams memory params) public returns (bool) {
    address a1 = msg.sender;

    bytes memory ch_key = channelKey(a1, params.a2);

    bytes memory encoded_msg = abi.encode(ch_key, params.dispute_nonce, params.offdeltas);


    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));

    log('encoded msg',encoded_msg);
    /*
    log('encoded msg hash',keccak256(encoded_msg));
    log('eth hash',hash);*/

    // ensure actual signer is provided counterparty address

    address signer = ECDSA.recover(hash, params.sig); 
    log('signer', signer);

    address l_user = a1 < params.a2 ? a1 : params.a2;
    address r_user = a1 < params.a2 ? params.a2 : a1;  

    logChannel(a1, params.a2);

    // iterate over offdeltas and split the assets
    for (uint i = 0;i<params.offdeltas.length;i++){
      uint asset_id = params.offdeltas[i].asset_id;
      Collateral storage col = collaterals[ch_key][asset_id];

      // final delta = offdelta + ondelta + unlocked hashlocks
      int delta = params.offdeltas[i].offdelta + col.ondelta;

      log("delta", delta);
      log("offdelta", params.offdeltas[i].offdelta);
      
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
    delete channels[ch_key];
   
    logChannel(a1, params.a2);

    return true;

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
    WithdrawFromChannelParams[] memory withdrawArray, 
    DepositToChannelParams[] memory depositArray,
    StartDisputeParams[] memory disputeArray
  ) public returns (bool) {

    bool completeSuccess = true; 


    // withdrawals are processed first to pull funds from channels to standalone
    for (uint i = 0; i < withdrawArray.length; i++) {
      if(!(withdrawFromChannel(withdrawArray[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < depositArray.length; i++) {
      if(!(depositToChannel(depositArray[i]))){
        completeSuccess = false;
      }
    }

    for (uint i = 0; i < disputeArray.length; i++) {
      if(!(startDispute(disputeArray[i]))){
        completeSuccess = false;
      }
    }


    return completeSuccess;
  }



  // read only

  function logChannel(address a1, address a2) public {
    bytes memory ch_key = channelKey(a1, a2);
    log(">>>Logging channel", ch_key);

    log("withdraw_nonce", channels[ch_key].withdraw_nonce);
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
    AssetReserveDebts[] reserves;
  }

  function getUser(address a1) external view returns (User memory) {
    User memory u = User({
      reserves: new AssetReserveDebts[](assets.length)
    });
    
    for (uint i = 0;i<assets.length;i++){
      u.reserves[i]=(AssetReserveDebts({
        reserve: reserves[a1][i],
        debtIndex: debtIndex[a1][i],
        debts: debts[a1][i]
      }));
    }
    
    return u;
  }
  
  struct ChannelReturn{
    Channel channel;
    Collateral[] collaterals;
  }

  function getChannel(address  a1, address  a2) public view returns (ChannelReturn memory ch) {
    bytes memory ch_key = channelKey(a1, a2);
    ChannelReturn memory ch = ChannelReturn({
      channel: channels[ch_key],
      collaterals: new Collateral[](assets.length)
    });
    

    for (uint i = 0;i<assets.length;i++){
      ch.collaterals[i]=collaterals[ch_key][i];
    }
    
    return ch;
  }
  
    
    
    
  
    
}