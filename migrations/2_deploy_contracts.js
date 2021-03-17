const XLN = artifacts.require("XLN");

module.exports = function (deployer) {
  deployer.deploy(XLN, { gas: 6000000 }).then((f) => {
    console.log(
      "deployedBytecode: " + f.constructor._json.deployedBytecode.length / 2
    );
    console.log(f.logs);
  });
};
