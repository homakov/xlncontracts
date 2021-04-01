const XLN = artifacts.require("XLN");

const TokenA = artifacts.require("TokenA");

module.exports = function (deployer) {

  deployer.deploy(TokenA, 10000000, { gas: 6000000 }).then((f) => {
    console.log(f)
  })


  deployer.deploy(XLN, { gas: 6000000 }).then((f) => {
    console.log(
      "deployed size: " + (f.constructor._json.deployedBytecode.length - 2) / 2
    );
    console.log(f.logs);
  });

};
