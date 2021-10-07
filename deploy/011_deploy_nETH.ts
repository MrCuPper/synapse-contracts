import { HardhatRuntimeEnvironment } from 'hardhat/types'
import { DeployFunction } from 'hardhat-deploy/types'

const func: DeployFunction = async function (hre: HardhatRuntimeEnvironment) {
  const { deployments, getNamedAccounts, getChainId } = hre
  const { deploy, get, execute, getOrNull, log, save } = deployments
  const { deployer } = await getNamedAccounts()

  if ((await getChainId()) === '42161') {
    if ((await getOrNull('nETH')) == null) {
      const receipt = await execute(
        'SynapseERC20Factory',
        { from: deployer, log: true },
        'deploy',
        (
          await get('SynapseERC20')
        ).address,
        'nETH',
        'nETH',
        '18',
        (
          await get('DevMultisig')
        ).address
      )

      const newTokenEvent = receipt?.events?.find(
        (e: any) => e['event'] == 'SynapseERC20Created'
      )
      const tokenAddress = newTokenEvent['args']['contractAddress']
      log(`deployed nETH token at ${tokenAddress}`)

      await save('nETH', {
        abi: (await get('SynapseToken')).abi, // Generic ERC20 ABI
        address: tokenAddress,
      })
    }
  }
}

export default func
func.tags = ['SynapseERC20Factory']
