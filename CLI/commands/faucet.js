var readlineSync = require('readline-sync');
var BigNumber = require('bignumber.js');
var common = require('./common/common_functions');
var contracts = require('./helpers/contract_addresses');
var abis = require('./helpers/contract_abis')
var chalk = require('chalk');
const Tx = require('ethereumjs-tx');
const Web3 = require('web3');

if (typeof web3 !== 'undefined') {
  web3 = new Web3(web3.currentProvider);
} else {
  // set the provider you want from Web3.providers
  web3 = new Web3(new Web3.providers.HttpProvider('https://kovan.infura.io/'));
}

////////////////////////
let polyToken;

// App flow
let accounts;
let enc = web3.eth.accounts.encrypt('e4eacb9959f5714458dff6dd467b5ddfc73e7349fd4ed78aecac0513b4a15755', 'PASSWORD');
let IssuerAccount = web3.eth.accounts.decrypt(enc, 'PASSWORD');
let Issuer = IssuerAccount.address;
console.log("Issuer Account: " + Issuer);
let defaultGasPrice;

async function executeApp(beneficiary, amount) {
  // Can uncomment this if running on ganache and you want to prefund the clean account.
  // accounts = await web3.eth.getAccounts();
  // await web3.eth.sendTransaction({from: accounts[0], to: Issuer, value: BigNumber(10**18)});
  // console.log("FUNDED ACCOUNT");

  defaultGasPrice = common.getGasPrice(await web3.eth.net.getId());

  console.log("\n");
  console.log("***************************")
  console.log("Welcome to the POLY Faucet.");
  console.log("***************************\n")

  await setup();
  await send_poly(beneficiary, amount);
};

async function setup(){
  try {
    let polytokenAddress = await contracts.polyToken();
    let polytokenABI = abis.polyToken();
    polyToken = new web3.eth.Contract(polytokenABI, polytokenAddress);
    polyToken.setProvider(web3.currentProvider);
  } catch (err) {
    console.log(err)
    console.log('\x1b[31m%s\x1b[0m',"There was a problem getting the contracts. Make sure they are deployed to the selected network.");
    process.exit(0);
  }
}

async function send_poly(beneficiary, amount) {
  let issuerBalance = await polyToken.methods.balanceOf(Issuer).call({from : Issuer});
  console.log(chalk.blue(`Hello user you have '${(new BigNumber(issuerBalance).dividedBy(new BigNumber(10).pow(18))).toNumber()} POLY'\n`))

  if (typeof beneficiary === 'undefined' && typeof amount === 'undefined') {
    let options = ['250 POLY for ticker registration','500 POLY for token launch + ticker reg', '20K POLY for CappedSTO Module', '20.5K POLY for Ticker + Token + CappedSTO', '100.5K POLY for Ticker + Token + USDTieredSTO','As many POLY as you want'];
    index = readlineSync.keyInSelect(options, 'What do you want to do?');
    console.log("Selected:",options[index]);
    switch (index) {
      case 0:
        beneficiary =  readlineSync.question(`Enter beneficiary of 250 POLY ('${Issuer}'): `);
        amount = '250';
        break;
      case 1:
        beneficiary =  readlineSync.question(`Enter beneficiary of 500 POLY ('${Issuer}'): `);
        amount = '500';
        break;
      case 2:
        beneficiary =  readlineSync.question(`Enter beneficiary of 20K POLY ('${Issuer}'): `);
        amount = '20000';
        break;
      case 3:
        beneficiary =  readlineSync.question(`Enter beneficiary of 20.5K POLY ('${Issuer}'): `);
        amount = '20500';
        break;
      case 4:
        beneficiary =  readlineSync.question(`Enter beneficiary of 100.5K POLY ('${Issuer}'): `);
        amount = '100500';
        break;
      case 5:
        beneficiary =  readlineSync.question(`Enter beneficiary of transfer ('${Issuer}'): `);
        amount = readlineSync.questionInt(`Enter the no. of POLY Tokens: `).toString();
        break;
    }
  }

  if (beneficiary == "") beneficiary = Issuer;
  await transferTokens(beneficiary, web3.utils.toWei(amount));
}

async function transferTokens(to, amount) {
    try {
        let getTokensAction = polyToken.methods.getTokens(amount, to);
        let GAS = await common.estimateGas(getTokensAction, Issuer, 1.2);
        await localExec(IssuerAccount, polyToken._address, getTokensAction.encodeABI(), GAS, defaultGasPrice);

    } catch (err){
        console.log(err.message);
        return;
    }
    let balance = await polyToken.methods.balanceOf(to).call();
    let balanceInPoly = new BigNumber(balance).dividedBy(new BigNumber(10).pow(18));
    console.log(chalk.green(`Congratulations! balance of ${to} address is ${balanceInPoly.toNumber()} POLY`));
}

async function localExec(from, to, abi, gas, gasPrice) {
    let parameter = {
        from: from.address,
        to: to,
        data: abi,
        gasLimit: gas,
        gasPrice: gasPrice
    };
    parameter.nonce = await web3.eth.getTransactionCount(from.address);
    const transaction = new Tx(parameter);
    transaction.sign(Buffer.from(from.privateKey.replace('0x', ''), 'hex'));
    web3.eth.sendSignedTransaction('0x' + transaction.serialize().toString('hex'))
    .on('transactionHash', function(hash) {
        console.log(`
        Your transaction is being processed. Please wait...
        TxHash: ${hash}\n`
      );
    })
    .on('receipt', function(receipt){
      console.log(`
        Congratulations! The transaction was successfully completed.
        Review it on Etherscan.
        TxHash: ${receipt.transactionHash}\n`
      );
    })
    .on('error', console.error);
}

module.exports = {
  executeApp: async function(beneficiary, amount) {
        return executeApp(beneficiary, amount);
    }
}
