const XLN = artifacts.require("XLN");
const crypto = require("crypto");

const privateKeys = [
  "0xc87509a1c067bbde78beb793e6fa76530b6382a4c0241e5e4a9ec0a0f44dc0d3",
  "0xae6ae8e5ccbfb04590405997ee2d52d2b330726137b875053c36d94e974d162f",
  "0x0dbbe8e4ae425a6d2687f1a7e3ba17bc98c673636790f1b8ad91193c05875ef1",
  "0xc88b703fb08cbea894b6aeff5a544fb92e78a18e19814cd85da83b71f772aa6c",
  "0x388c684f0ba1ef5017716adb5d21a053ea8e90277d0868337519f97bede61418",
  "0x659cbb0e2411a44db63778987b1e22153c086a95eb6b18bdf89de078917abc63",
];

const logTx = (res) => {
  console.log("\n\n\n\nGAS: " + res.receipt.gasUsed);
  res.logs.map((l) => {
    console.log(l.args["0"] + ": " + l.args["1"]);
  });
};

const getBatch = (obj) => {
  return Object.assign(
    {
      channelToReserve: [],
      reserveToChannel: [],
      reserveToReserve: [],
      reserveToToken: [],
      tokenToReserve: [],
      reseverToReserve: [],

      cooperativeProof: [],
      disputeProof: [],
      revealEntries: [],

      revealSecret: [],
      cleanSecret: [],

      hub_id: 0,
    },
    obj
  );
};

const getProofHash = async (
  by_id,
  for_id,
  proofType,
  entries,
  dispute_nonce
) => {
  let ch = await L1.getChannel(accounts[by_id], accounts[for_id]);

  let used_nonce =
    proofType == XLN.MessageType.DisputeProof
      ? dispute_nonce
      : ch.channel.cooperative_nonce;

  let last_type =
    proofType == XLN.MessageType.DisputeProof
      ? "bytes32"
      : proofType == XLN.MessageType.WithdrawProof
      ? "(uint,uint)[]"
      : "(uint,int)[]";

  let last_item =
    proofType == XLN.MessageType.DisputeProof
      ? web3.utils.keccak256(
          web3.eth.abi.encodeParameters(["(uint,int)[]"], [entries])
        )
      : entries;

  return web3.utils.keccak256(
    web3.eth.abi.encodeParameters(
      ["uint", "bytes", "uint", "uint", last_type],
      [
        proofType,
        ch.channelKey,
        ch.channel.channel_counter,
        used_nonce,
        last_item,
      ]
    )
  );
};

const signProof = (hash, private_key) => {
  return web3.eth.accounts.sign(hash, private_key).signature;
};

// assert JS state to contract state

assertState = async function (a1_bal, a2_bal, collateral, ondelta) {
  assert.equal(
    a1_bal,
    (await L1.getUser(accounts[0])).assets[0].reserve.toString()
  );
  assert.equal(
    a2_bal,
    (await L1.getUser(accounts[1])).assets[0].reserve.toString()
  );

  let ch = await L1.getChannel(accounts[0], accounts[1]);

  assert.equal(collateral, ch.collaterals[0].collateral);
  assert.equal(ondelta, ch.collaterals[0].ondelta);
};

contract("XLN", (accounts) => {
  global.accounts = accounts;

  it("channelKey must be deterministic for any order of addresses", async () => {
    global.L1 = await XLN.deployed();

    let acs = [
      "0xda7A0318c1870121F85749c3feBdB7e18aA65740",
      "0x4e5561C72D820B53C5c1c3C372D7254b4Fa3D65E",
    ];

    let expect_key =
      "0x4e5561c72d820b53c5c1c3c372d7254b4fa3d65eda7a0318c1870121f85749c3febdb7e18aa65740";

    assert.equal(expect_key, await L1.channelKey(acs[0], acs[1]));
    assert.equal(expect_key, await L1.channelKey(acs[1], acs[0]));
  });

  it("test reserveToChannel", async () => {
    await assertState("100000000", "0", "0", "0");

    await L1.reserveToChannel({
      receiver: accounts[0],
      partner: accounts[1],
      pairs: [[0, 100]],
    });

    await assertState("99999900", "0", "100", "100");

    // from other side
    await L1.reserveToChannel({
      receiver: accounts[1],
      partner: accounts[0],
      pairs: [
        [0, 50],
        [0, 50],
      ],
    });
    //ondelta not increased when deposited from right side
    await assertState("99999800", "0", "200", "100");
  });

  it("test batch", async () => {
    await assertState("99999800", "0", "200", "100");

    let b = getBatch();

    b.reserveToChannel.push({
      receiver: accounts[2],
      partner: accounts[0],
      pairs: [[0, 1000]],
    });
    b.reserveToChannel.push({
      receiver: accounts[3],
      partner: accounts[0],
      pairs: [[0, 1000]],
    });

    logTx(await L1.processBatch(b));

    await assertState("99997800", "0", "200", "100");
  });

  it("test channelToReserve", async () => {
    await assertState("99997800", "0", "200", "100");

    let pairs = [
      [0, 20],
      [0, 30],
    ];
    let hash = await getProofHash(0, 1, XLN.MessageType.WithdrawProof, pairs);
    let sig = signProof(hash, privateKeys[0]);

    console.log("JS encoded", hash);
    //console.log('our hash',web3.utils.soliditySha3({t: 'bytes', v: ch_key}, {t: 'uint[][]', v: go}))
    assert.equal(accounts[0], web3.eth.accounts.recover(hash, sig));

    logTx(
      await L1.channelToReserve(
        { partner: accounts[0], pairs: pairs, sig: sig },
        { from: accounts[1] }
      )
    );

    await assertState("99997800", "50", "150", "100");

    pairs = [
      [0, 20],
      [0, 30],
    ];
    hash = await getProofHash(1, 0, XLN.MessageType.WithdrawProof, pairs);
    sig = signProof(hash, privateKeys[1]);

    logTx(
      await L1.channelToReserve(
        { partner: accounts[1], pairs: pairs, sig: sig },
        { from: accounts[0] }
      )
    );

    await assertState("99997850", "50", "100", "50");
  });

  it("submit dispute proof", async () => {
    await assertState("99997850", "50", "100", "50");

    let ch_key = await L1.channelKey(accounts[0], accounts[1]);
    let entries = [[0, -10]];

    let nonce = 1;

    let hash = await getProofHash(
      0,
      1,
      XLN.MessageType.DisputeProof,
      entries,
      nonce
    );
    let sig = signProof(hash, privateKeys[0]);

    let entries_hash = web3.utils.keccak256(
      web3.eth.abi.encodeParameters(["(uint,int)[]"], [entries])
    );

    logTx(
      await L1.disputeProof(
        {
          partner: accounts[0],
          dispute_nonce: nonce,
          entries_hash: entries_hash,
          entries: [],
          sig: sig,
        },
        { from: accounts[1] }
      )
    );

    logTx(
      await L1.revealEntries(
        {
          partner: accounts[0],
          entries: entries,
        },
        { from: accounts[1] }
      )
    );
    await assertState("99997850", "50", "100", "50");

    entries = [[0, 10]];
    nonce = 23;
    hash = await getProofHash(
      1,
      0,
      XLN.MessageType.DisputeProof,
      entries,
      nonce
    );
    sig = signProof(hash, privateKeys[1]);
    entries_hash = web3.utils.keccak256(
      web3.eth.abi.encodeParameters(["(uint,int)[]"], [entries])
    );

    logTx(
      await L1.disputeProof(
        {
          partner: accounts[1],
          dispute_nonce: nonce,
          entries_hash: entries_hash,
          entries: entries,
          sig: sig,
        },
        { from: accounts[0] }
      )
    );

    await assertState("99997910", "90", "0", "0");
  });

  it("submitDispute then accept", async () => {
    await L1.reserveToChannel({
      receiver: accounts[0],
      partner: accounts[1],
      pairs: [[0, 100]],
    });

    await assertState("99997810", "90", "100", "100");

    let ch_key = await L1.channelKey(accounts[0], accounts[1]);
    let entries = [[0, -50]];

    let nonce = 1;

    let hash = await getProofHash(
      0,
      1,
      XLN.MessageType.DisputeProof,
      entries,
      nonce
    );
    let sig = signProof(hash, privateKeys[0]);

    let entries_hash = web3.utils.keccak256(
      web3.eth.abi.encodeParameters(["(uint,int)[]"], [entries])
    );

    logTx(
      await L1.disputeProof(
        {
          partner: accounts[0],
          dispute_nonce: nonce,
          entries_hash: entries_hash,
          entries: [],
          sig: sig,
        },
        { from: accounts[1] }
      )
    );

    logTx(
      await L1.revealEntries(
        {
          partner: accounts[1],
          entries: entries,
        },
        { from: accounts[0] }
      )
    );

    await assertState("99997860", "140", "0", "0");
  });

  it("revealSecret", async () => {
    let secret = crypto.randomBytes(32);
    let hash = web3.utils.keccak256(secret);

    await L1.revealSecret(secret);

    assert.isAbove((await L1.hash_to_block(hash)).toNumber(), 1);
  });

  it("accounts[0] cooperative close", async () => {
    await L1.reserveToChannel({
      receiver: accounts[0],
      partner: accounts[1],
      pairs: [[0, 100]],
    });
    await assertState("99997760", "140", "100", "100");

    let ch_key = await L1.channelKey(accounts[0], accounts[1]);
    let entries = [[0, 50]];

    let hash = await getProofHash(
      0,
      1,
      XLN.MessageType.CooperativeProof,
      entries
    );
    let sig = signProof(hash, privateKeys[0]);

    logTx(
      await L1.cooperativeProof(
        {
          partner: accounts[0],
          entries: entries,
          sig: sig,
        },
        { from: accounts[1] }
      )
    );

    await assertState("99997910", "90", "0", "0");
  });
});

/*
ganache-cli -m 'candy maple cake sugar pudding cream honey rich smooth crumble sweet treat'
Ganache CLI v6.12.2 (ganache-core: 2.13.2)

Available Accounts
==================
(0) 0x627306090abaB3A6e1400e9345bC60c78a8BEf57 (100 ETH)
(1) 0xf17f52151EbEF6C7334FAD080c5704D77216b732 (100 ETH)
(2) 0xC5fdf4076b8F3A5357c5E395ab970B5B54098Fef (100 ETH)
(3) 0x821aEa9a577a9b44299B9c15c88cf3087F3b5544 (100 ETH)
(4) 0x0d1d4e623D10F9FBA5Db95830F7d3839406C6AF2 (100 ETH)
(5) 0x2932b7A2355D6fecc4b5c0B6BD44cC31df247a2e (100 ETH)
(6) 0x2191eF87E392377ec08E7c08Eb105Ef5448eCED5 (100 ETH)
(7) 0x0F4F2Ac550A1b4e2280d04c21cEa7EBD822934b5 (100 ETH)
(8) 0x6330A553Fc93768F612722BB8c2eC78aC90B3bbc (100 ETH)
(9) 0x5AEDA56215b167893e80B4fE645BA6d5Bab767DE (100 ETH)

Private Keys
==================
(0) 0xc87509a1c067bbde78beb793e6fa76530b6382a4c0241e5e4a9ec0a0f44dc0d3
(1) 0xae6ae8e5ccbfb04590405997ee2d52d2b330726137b875053c36d94e974d162f
(2) 0x0dbbe8e4ae425a6d2687f1a7e3ba17bc98c673636790f1b8ad91193c05875ef1
(3) 0xc88b703fb08cbea894b6aeff5a544fb92e78a18e19814cd85da83b71f772aa6c
(4) 0x388c684f0ba1ef5017716adb5d21a053ea8e90277d0868337519f97bede61418
(5) 0x659cbb0e2411a44db63778987b1e22153c086a95eb6b18bdf89de078917abc63
(6) 0x82d052c865f5763aad42add438569276c00d3d88a2d062d36b2bae914d58b8c8
(7) 0xaa3680d5d48a8283413f7a108367c7299ca73f553735860a87b08f39395618b7
(8) 0x0f62d96d6675f32685bbdb8ac13cda7c23436f63efbb9d07700d8669ff12b7c4
(9) 0x8d5366123cb560bb606379f90a0bfd4769eecc0557f1b362dcae9012b548b1e5

*/
