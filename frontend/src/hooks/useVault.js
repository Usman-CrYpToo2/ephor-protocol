import { useState, useEffect, useCallback, useRef } from 'react';
import { ethers } from 'ethers';
import { ABIS, RPC_URL, VAULTS } from '../config';

const staticProvider = new ethers.JsonRpcProvider(RPC_URL);

export function useVault(vaultAddress, userAddress) {
  const [data, setData]           = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError]         = useState(null);
  const pendingRef = useRef(false);

  const vaultConfig = VAULTS.find(v => v.address?.toLowerCase() === vaultAddress?.toLowerCase()) || null;

  const fetchData = useCallback(async () => {
    if (!vaultAddress || !vaultConfig || pendingRef.current) return;
    pendingRef.current = true;

    try {
      const vault      = new ethers.Contract(vaultConfig.address, ABIS.vault,      staticProvider);
      const sentinel   = new ethers.Contract(vaultConfig.sentinel,   ABIS.sentinel,   staticProvider);
      const strategist = new ethers.Contract(vaultConfig.strategist, ABIS.strategist, staticProvider);
      const usdcCt     = new ethers.Contract(vaultConfig.assetAddr,  ABIS.usdc,       staticProvider);

      const [
        totalAssets,
        depositsPaused,
        idleBufferBps,
        minIdleBufferBps,
        maxMarketBps,
        maxTurnoverBps,
        rebalanceEpochLength,
        currentEpoch,
        lastRebalanceTime,
        sharePrice,
        totalSupply,
        maxDepositRaw,
        performanceFeeBps,
        feeRecipient,
        // sentinel
        vaultInfoData,
        isPending,
        latestRisk,
        history,
        hardLevel,
        // strategist
        stratLastRequest,
        stratActiveRequest,
      ] = await Promise.all([
        vault.totalAssets(),
        vault.depositsPaused(),
        vault.idleBufferBps(),
        vault.minIdleBufferBps(),
        vault.maxMarketBps(),
        vault.maxTurnoverBps(),
        vault.rebalanceEpochLength(),
        vault.currentEpoch(),
        vault.lastRebalanceTime(),
        vault.sharePrice(),
        vault.totalSupply(),
        vault.maxDeposit(userAddress || '0x0000000000000000000000000000000000000000').catch(() => 0n),
        vault.performanceFeeBps().catch(() => 1000n),
        vault.feeRecipient().catch(() => '0x0000000000000000000000000000000000000000'),
        // sentinel
        sentinel.vaultInfo(vaultConfig.address),
        sentinel.isCheckPending(vaultConfig.address),
        sentinel.getLatestRisk(vaultConfig.address),
        sentinel.getHistory(vaultConfig.address),
        sentinel.assessOnChain(vaultConfig.address),
        // strategist
        strategist.lastRequestAt(vaultConfig.address),
        strategist.activeRequest(vaultConfig.address),
      ]);

      // Fetch last RebalanceExecuted event to get actual strategy label
      let lastRebalanceLabel = null;
      let rebalanceCount = 0;
      try {
        const filter = strategist.filters.RebalanceExecuted(vaultConfig.address);
        const logs = await strategist.queryFilter(filter, -50000);
        rebalanceCount = logs.length;
        if (logs.length > 0) {
          lastRebalanceLabel = logs[logs.length - 1].args.label;
        }
      } catch (_) { /* ignore — chain may not have logs yet */ }

      // Fetch per-market data dynamically
      const marketResults = await Promise.all(
        vaultConfig.markets.map(async (m) => {
          const mkt = new ethers.Contract(m.address, ABIS.market, staticProvider);
          const [allocBps, utilBps, rateBps, balance, marketInfo] = await Promise.all([
            vault.marketAllocationBps(m.address).catch(() => 0n),
            mkt.utilizationBps().catch(() => 0n),
            mkt.supplyRateBps().catch(() => 0n),
            mkt.balanceOf(vaultConfig.address).catch(() => 0n),
            vault.markets(m.address).catch(() => ({ enabled: false, supplyCap: 0n })),
          ]);
          return {
            address:       m.address,
            name:          m.name,
            allocationBps: Number(allocBps),
            utilizationBps: Number(utilBps),
            supplyRateBps: Number(rateBps),
            balance:       Number(balance) / Math.pow(10, vaultConfig.assetDecimals),
            supplyCap:     Number(marketInfo.supplyCap) / Math.pow(10, vaultConfig.assetDecimals),
            enabled:       marketInfo.enabled,
          };
        })
      );

      let userAssetBal = 0n, userShares = 0n, userStt = 0n;
      if (userAddress) {
        [userAssetBal, userShares, userStt] = await Promise.all([
          usdcCt.balanceOf(userAddress),
          vault.balanceOf(userAddress),
          staticProvider.getBalance(userAddress),
        ]);
      }

      const historyItems = Array.from(history)
        .map(snap => ({
          timestamp:   Number(snap.timestamp),
          level:       Number(snap.level),
          verdict:     snap.rawVerdict,
          totalAssets: Number(snap.totalAssets) / Math.pow(10, vaultConfig.assetDecimals),
          idleBps:     Number(snap.idleBps),
        }))
        .reverse();

      const totalA  = Number(totalAssets) / Math.pow(10, vaultConfig.assetDecimals);
      const idleBps = Number(idleBufferBps);
      const idleAmt = Math.round(totalA * idleBps / 10000);
      const netApy  = marketResults.reduce((s, m) =>
        s + (m.allocationBps / 10000) * (m.supplyRateBps / 10000) * 100, 0);

      const userSharesNum = Number(ethers.formatUnits(userShares, vaultConfig.assetDecimals));
      const sharePriceNum = Number(ethers.formatEther(sharePrice));
      const userValue     = userSharesNum * sharePriceNum;
      const userCost      = userSharesNum; // approximation: 1:1 at deposit time

      setData({
        config: vaultConfig,
        vault: {
          totalAssets:         totalA,
          depositsPaused,
          idleBufferBps:       idleBps,
          minIdleBufferBps:    Number(minIdleBufferBps),
          maxMarketBps:        Number(maxMarketBps),
          maxTurnoverBps:      Number(maxTurnoverBps),
          rebalanceEpochLength: Number(rebalanceEpochLength),
          currentEpoch:        Number(currentEpoch),
          lastRebalanceTime:   Number(lastRebalanceTime),
          sharePrice:          sharePriceNum,
          totalSupply:         Number(ethers.formatUnits(totalSupply, vaultConfig.assetDecimals)),
          maxDeposit:          Number(maxDepositRaw) / Math.pow(10, vaultConfig.assetDecimals),
          performanceFeeBps:   Number(performanceFeeBps),
          feeRecipient,
          idleAmt,
          netApy,
        },
        markets: marketResults,
        sentinel: {
          registered:       vaultInfoData.registered,
          autoPauseEnabled: vaultInfoData.autoPauseEnabled,
          lastLevel:        Number(vaultInfoData.lastLevel),
          lastCheckedAt:    Number(vaultInfoData.lastCheckedAt),
          totalChecks:      Number(vaultInfoData.totalChecks),
          criticalCount:    Number(vaultInfoData.criticalCount),
          isCheckPending:   isPending,
          latestVerdict:    latestRisk.verdict,
          latestVerdictTs:  Number(latestRisk.ts),
          latestLevel:      Number(latestRisk.level),
          hardLevel:        Number(hardLevel),
          history:          historyItems,
        },
        strategist: {
          lastRequestAt:  Number(stratLastRequest),
          activeRequest:  stratActiveRequest.toString(),
          isPending:      stratActiveRequest.toString() !== '0',
          lastLabel:      lastRebalanceLabel,
          rebalanceCount,
        },
        user: {
          address:     userAddress,
          assetBalance: Number(userAssetBal) / Math.pow(10, vaultConfig.assetDecimals),
          shares:      userSharesNum,
          sttBalance:  Number(ethers.formatEther(userStt)),
          value:       userValue,
          pnl:         userValue - userCost,
          pnlPct:      userCost > 0 ? ((userValue - userCost) / userCost) * 100 : 0,
        },
      });

      setError(null);
    } catch (e) {
      console.error('useVault fetch error:', e);
      setError(e.shortMessage || e.message);
    } finally {
      setIsLoading(false);
      pendingRef.current = false;
    }
  }, [vaultAddress, vaultConfig, userAddress]);

  useEffect(() => {
    setIsLoading(true);
    fetchData();
    const interval = setInterval(fetchData, 12_000);
    return () => clearInterval(interval);
  }, [fetchData]);

  return { data, isLoading, error, refetch: fetchData, vaultConfig };
}
