
var Arena = artifacts.require("./Arena.sol");

var KittyCore = artifacts.require("./KittyCore.sol");

module.exports = function (deployer) {

  deployer.deploy(KittyCore)
    .then(() => KittyCore.deployed())
    .then((deployed) => {
      return deployer.deploy(Arena, deployed.address).then(() => console.log("all deployed"));
    });

};
