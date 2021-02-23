const MetaCoin = artifacts.require("MetaCoin");
const XLN = artifacts.require("XLN");

contract('MetaCoin', (accounts) => {

  console.log(accounts)
  //console.log(XLN)

  it('channelKey must be deterministic for any order of addresses', async ()=>{
    const X = await XLN.deployed()
    let acs = ['0xda7A0318c1870121F85749c3feBdB7e18aA65740',
    '0x4e5561C72D820B53C5c1c3C372D7254b4Fa3D65E']

    let key = '0x4e5561c72d820b53c5c1c3c372d7254b4fa3d65eda7a0318c1870121f85749c3febdb7e18aa65740'

    assert.equal(key, await X.channelKey(acs[0],acs[1]))
    assert.equal(key, await X.channelKey(acs[1],acs[0])) 

    console.log(X.channels)
  })

  it('should deposit 100 to channel from either side correctly', async ()=>{
    const X = await XLN.deployed()

    // log channel
    assert.equal('1000000000000', (await X.getUser(accounts[0])).toString())
    let cov = await X.getCoverage(accounts[0], accounts[1], 0);
    console.log(cov)
    assert.equal('0', cov.collateral)
    assert.equal('0', cov.ondelta)
 
    console.log(await X.depositToChannel(accounts[0], accounts[1], 0, 100))


    assert.equal('999999999900', (await X.getUser(accounts[0])).toString())
    cov = await X.getCoverage(accounts[0], accounts[1], 0);
    assert.equal('100', cov.collateral)
    assert.equal('100', cov.ondelta)
    
    console.log(await X.depositToChannel(accounts[1], accounts[0], 0, 100))


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
    console.log(cov)
    assert.equal('200', cov.collateral)
    assert.equal('100', cov.ondelta)


    msg='withdraw,a1,a2,[id, amount],'
    sig=web3.eth.accounts.sign(msg, '0x4c0883a69102937d6231471b5dbb6204fe5129617082792ae468d01a3f362318');


    web3.eth.accounts.recover(msg, sig.signature)

    
 
    console.log(await X.withdrawFromChannel(accounts[1],  0, 100))

    assert.equal('999999999900', (await X.getUser(accounts[0])).toString())
    cov = await X.getCoverage(accounts[0], accounts[1], 0);
    console.log(cov)
    assert.equal('100', cov.collateral)
    assert.equal('0', cov.ondelta)

    //withdraw from counterparty side
    console.log(await X.withdrawFromChannel(accounts[0],  0, 100,{from: accounts[1]}))

    assert.equal('100', (await X.getUser(accounts[1])).toString())
    cov = await X.getCoverage(accounts[0], accounts[1], 0);
    console.log(cov)
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
