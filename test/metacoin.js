const MetaCoin = artifacts.require("MetaCoin");
const XLN = artifacts.require("XLN");

const privateKeys = ['0xc87509a1c067bbde78beb793e6fa76530b6382a4c0241e5e4a9ec0a0f44dc0d3',
'0xae6ae8e5ccbfb04590405997ee2d52d2b330726137b875053c36d94e974d162f',
'0x0dbbe8e4ae425a6d2687f1a7e3ba17bc98c673636790f1b8ad91193c05875ef1',
'0xc88b703fb08cbea894b6aeff5a544fb92e78a18e19814cd85da83b71f772aa6c',
'0x388c684f0ba1ef5017716adb5d21a053ea8e90277d0868337519f97bede61418',
'0x659cbb0e2411a44db63778987b1e22153c086a95eb6b18bdf89de078917abc63']

contract('MetaCoin', (accounts,b,c,d) => {
 

  it('channelKey must be deterministic for any order of addresses', async ()=>{
    const X = await XLN.deployed()
    let acs = ['0xda7A0318c1870121F85749c3feBdB7e18aA65740',
    '0x4e5561C72D820B53C5c1c3C372D7254b4Fa3D65E']

    let expect_key = '0x4e5561c72d820b53c5c1c3c372d7254b4fa3d65eda7a0318c1870121f85749c3febdb7e18aa65740'

    assert.equal(expect_key, await X.channelKey(acs[0],acs[1]))
    assert.equal(expect_key, await X.channelKey(acs[1],acs[0])) 

    //console.log(await X.channels(key))
  })

  it('should deposit 100 to channel from either side correctly', async ()=>{
    const X = await XLN.deployed()

    // log channel
    assert.equal('1000000000000', (await X.getUser(accounts[0])).toString())
    let cov = await X.getCoverage(accounts[0], accounts[1], 0);
    assert.equal('0', cov.collateral)
    assert.equal('0', cov.ondelta)
 
    await X.depositToChannel(accounts[0], accounts[1], 0, 100)


    assert.equal('999999999900', (await X.getUser(accounts[0])).toString())
    cov = await X.getCoverage(accounts[0], accounts[1], 0);
    assert.equal('100', cov.collateral)
    assert.equal('100', cov.ondelta)
    
    await X.depositToChannel(accounts[1], accounts[0], 0, 100)


    assert.equal('999999999800', (await X.getUser(accounts[0])).toString())
    cov = await X.getCoverage(accounts[0], accounts[1], 0);
    assert.equal('200', cov.collateral)
    assert.equal('100', cov.ondelta) //ondelta not increased for right user
  })


  it('should withdraw 100 from either side correctly', async ()=>{
    const X = await XLN.deployed()

    // log channel
    assert.equal('999999999800', (await X.getUser(accounts[0])).toString())
    cov = await X.getCoverage(accounts[0], accounts[1], 0);
    assert.equal('200', cov.collateral)
    assert.equal('100', cov.ondelta)

    let amounts = [0, 10, 0, 20]

    let chKey = await X.channelKey(accounts[0],accounts[1])

    withdraw_nonce = (await X.getChannel(accounts[0],accounts[1])).toNumber()
    msg=web3.eth.abi.encodeParameters(['bytes','uint','uint[]'], [chKey,withdraw_nonce, amounts]);
    console.log('we encoded',msg)


    //console.log('our hash',web3.utils.soliditySha3({t: 'bytes', v: chKey}, {t: 'uint[][]', v: go}))

    sig=web3.eth.accounts.sign(web3.utils.keccak256(msg), privateKeys[0]);
 
    //assert.equal(accounts[0],web3.eth.accounts.recover(msg, sig.signature))

    let logy = (res)=>{console.log(res.logs.map(l=>l.args['0']+": "+l.args['1']))}


cov = await X.getCoverage(accounts[0], accounts[1], 0);
    console.log(cov)

    logy(await X.withdrawFromChannel(accounts[0], amounts, sig.signature, {from: accounts[1]}))
cov = await X.getCoverage(accounts[0], accounts[1], 0);
    console.log(cov)

    withdraw_nonce = (await X.getChannel(accounts[0],accounts[1])).toNumber()
    msg=web3.eth.abi.encodeParameters(['bytes','uint','uint[]'], [chKey,withdraw_nonce, amounts]);
    console.log('we encoded',msg)
    sig=web3.eth.accounts.sign(web3.utils.keccak256(msg), privateKeys[0]);

    logy(await X.withdrawFromChannel(accounts[0], amounts, sig.signature, {from: accounts[1]}))
cov = await X.getCoverage(accounts[0], accounts[1], 0);
    console.log(cov)
    console.log(res.logs.map(l=>l.args['0']+l.args['1']))


    return
    assert.equal('999999999900', (await X.getUser(accounts[0])).toString())
    cov = await X.getCoverage(accounts[0], accounts[1], 0);
    console.log(cov)
    assert.equal('100', cov.collateral)
    assert.equal('0', cov.ondelta)

    //withdraw from counterparty side
    await X.withdrawFromChannel(accounts[0],  0, 100,{from: accounts[1]})

    assert.equal('100', (await X.getUser(accounts[1])).toString())
    cov = await X.getCoverage(accounts[0], accounts[1], 0);
    assert.equal('0', cov.collateral)
    assert.equal('0', cov.ondelta)
  })











  it('should put 10000 MetaCoin in the first account', async () => {
    const X = await XLN.deployed()

    // log channel
    console.log('user',(await X.getUser(accounts[0])).toString())

    const metaCoinInstance = await MetaCoin.deployed();
    const balance = await metaCoinInstance.getBalance.call(accounts[0]);

    //assert.equal(balance.valueOf(), 10000, "10000 wasn't in the first account");
  });
  it('should call a function that depends on a linked library', async () => {
    const metaCoinInstance = await MetaCoin.deployed();
    const metaCoinBalance = (await metaCoinInstance.getBalance.call(accounts[0])).toNumber();
    const metaCoinEthBalance = (await metaCoinInstance.getBalanceInEth.call(accounts[0])).toNumber();

    assert.equal(metaCoinEthBalance, 2 * metaCoinBalance, 'Library function returned unexpected function, linkage may be broken');
  });
  it('should send coin correctly', async () => {
    const X = await XLN.deployed()

    // log channel
    console.log('user',(await X.getUser(accounts[0])).toString())

    const metaCoinInstance = await MetaCoin.deployed();

    // Setup 2 accounts.
    const accountOne = accounts[0];
    const accountTwo = accounts[1];

    // Get initial balances of first and second account.
    const accountOneStartingBalance = (await metaCoinInstance.getBalance.call(accountOne)).toNumber();
    const accountTwoStartingBalance = (await metaCoinInstance.getBalance.call(accountTwo)).toNumber();

    // Make transaction from first account to second.
    const amount = 10;
    await metaCoinInstance.sendCoin(accountTwo, amount, { from: accountOne });

    // Get balances of first and second account after the transactions.
    const accountOneEndingBalance = (await metaCoinInstance.getBalance.call(accountOne)).toNumber();
    const accountTwoEndingBalance = (await metaCoinInstance.getBalance.call(accountTwo)).toNumber();


    assert.equal(accountOneEndingBalance, accountOneStartingBalance - amount, "Amount wasn't correctly taken from the sender");
    assert.equal(accountTwoEndingBalance, accountTwoStartingBalance + amount, "Amount wasn't correctly sent to the receiver");
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