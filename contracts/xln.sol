// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;
pragma experimental ABIEncoderV2;

import "./ConvertLib.sol";
import "./ECDSA.sol";
import "./console.sol";

contract XLN is Console{
  enum MessageTypeId {
      None,
      BalanceProof,
      BalanceProofUpdate,
      Withdraw,
      CooperativeSettle,
      IOU,
      MSReward
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
    uint amount_left;
    address pay_to;
  }
  
  struct User{
    mapping (uint => uint) standalone;
    mapping (uint => Debt[]) debts;
    string uri;

  }
  //coverage_balance
  struct Coverage {
    uint collateral;
    int ondelta;
  }

  struct Channel{
    uint withdraw_nonce;

    uint dispute_nonce;
    uint dispute_until_block;
    bytes32 hash_outcome_proposed;
    bool dispute_by_left;

    mapping (uint => Coverage) coverages;    
  }


  mapping (bytes => Channel) public channels;
  
  mapping (address => User) users;

  Asset[] public assets;
  

  constructor() {
    users[msg.sender].standalone[0] = 1000000000000;

    assets.push(Asset({
      name: "WETH"
    }));
  }


  function depositToChannel(DepositToChannelParams memory params) public returns (bool) {
    bool a1_is_left = params.a1 < params.a2;

    logChannel(params.a1, params.a2);

    for (uint i = 0; i < params.pairs.length; i++) {
      uint asset_id = params.pairs[i].asset_id;
      uint amount = params.pairs[i].amount;

      if (users[msg.sender].standalone[asset_id] >= amount) {

        Coverage storage cov = channels[channelKey(params.a1, params.a2)].coverages[asset_id];

        users[msg.sender].standalone[asset_id] -= amount;
        
        cov.collateral += amount;

        if (a1_is_left) {
          cov.ondelta += int(amount);
          log('new ondelta', cov.ondelta);
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


    bytes memory encoded_msg = abi.encode(ch_key, channels[ch_key].withdraw_nonce++, params.pairs);


    bytes32 hash = ECDSA.toEthSignedMessageHash(keccak256(encoded_msg));

    log('encoded msg',encoded_msg);
    /*
    log('encoded msg hash',keccak256(encoded_msg));
    log('eth hash',hash);*/

    // ensure actual signer is provided counterparty address

    address signer = ECDSA.recover(hash, params.sig);
    log('signer', signer);

    if(params.a2 != signer) {
      log("Invalid signer", signer);
      return false;
    }


    for (uint i = 0; i < params.pairs.length; i++) {
      uint asset_id = params.pairs[i].asset_id;
      uint amount = params.pairs[i].amount;

      Coverage storage cov = channels[ch_key].coverages[asset_id];

      if (cov.collateral >= amount) {
        cov.collateral -= amount;
        if (a1_is_left) {
          cov.ondelta -= int(amount);
        }

        users[a1].standalone[asset_id] += amount;

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
      Coverage storage cov = channels[ch_key].coverages[asset_id];

      // final delta = offdelta + ondelta + unlocked hashlocks
      int delta = params.offdeltas[i].offdelta + cov.ondelta;

      log("delta", delta);
      log("offdelta", params.offdeltas[i].offdelta);
      
      if (delta >= 0 && delta <= int(cov.collateral)) {
        // Collateral is split (standard no-credit LN resolution)
        uint left_gets = uint(delta);
        users[l_user].standalone[asset_id] += left_gets;
        users[r_user].standalone[asset_id] += cov.collateral - left_gets;


      } else {
        // one user gets entire collateral, another gets debt (resolution enabled by XLN)
        address getsCollateral = delta < 0 ? r_user : l_user;
        address getsDebt = delta < 0 ? l_user : r_user;
        uint debtAmount = delta < 0 ? uint(-delta) : uint(delta) - cov.collateral;

        log('gets collateral', getsCollateral);
        log('gets debt', getsDebt);
        log('debt', debtAmount);

        users[getsCollateral].standalone[asset_id] += cov.collateral;
        if (users[getsDebt].standalone[asset_id] >= debtAmount) {
          // will pay right away without creating Debt
          users[getsCollateral].standalone[asset_id] += debtAmount;
          users[getsDebt].standalone[asset_id] -= debtAmount;
        } else {
          // pay what they can, and create Debt
          if (users[getsDebt].standalone[asset_id] > 0) {
            users[getsCollateral].standalone[asset_id] += users[getsDebt].standalone[asset_id];
            debtAmount -= users[getsDebt].standalone[asset_id];
            users[getsDebt].standalone[asset_id] = 0;
          }
          users[getsDebt].debts[asset_id].push(Debt({
            pay_to: getsCollateral,
            amount_left: debtAmount
          }));
        }
      }

      delete channels[ch_key].coverages[asset_id];
    }
    delete channels[ch_key];
   
    logChannel(a1, params.a2);


    return true;

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
      log("L balance", users[a1].standalone[i]);
      log("R balance", users[a2].standalone[i]);

      log("collateral", channels[ch_key].coverages[i].collateral);
      log("ondelta", channels[ch_key].coverages[i].ondelta);

    }


  }
  
  function channelKey(address a1, address a2) public pure returns (bytes memory) {
    //determenistic channel key is 40 bytes: concatenated lowerKey + higherKey
    return a1 < a2 ? abi.encodePacked(a1, a2) : abi.encodePacked(a2, a1);
  }

  function getUser(address a1) external view returns (uint balance) {
    return users[a1].standalone[0];
  }

  function getChannel(address  a1, address  a2) public view returns (uint withdraw_nonce) {
    withdraw_nonce=channels[channelKey(a1, a2)].withdraw_nonce;
  }
  
  function getCoverage(address  a1, address  a2, uint asset_id) public view returns (Coverage memory cov) {
    cov = channels[channelKey(a1, a2)].coverages[asset_id];
  }  
}