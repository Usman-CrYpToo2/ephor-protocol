import { useState, useEffect, useCallback, useRef } from 'react';
import { ethers } from 'ethers';
import { ADDRESSES, ABIS, RPC_URL } from '../config';

const staticProvider = new ethers.JsonRpcProvider(RPC_URL);

export function useProtocol(userAddress) {
  const [data, setData]           = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError]         = useState(null);
  const [lastRefresh, setLastRefresh] = useState(null);
  const pendingRef = useRef(false);

  const fetchData = useCallback(async () => {
    if (pendingRef.current) return;
    pendingRef.current = true;

    try {
      const vault      = new ethers.Contract(ADDRESSES.vault,      ABIS.vault,      staticProvider);
      const sentinel   = new ethers.Contract(ADDRESSES.sentinel,   ABIS.sentinel,   staticProvider);
      const strategist = new ethers.Contract(ADDRESSES.strategist, ABIS.strategist, staticProvider);
      const usdc       = new ethers.Contract(ADDRESSES.usdc,       ABIS.usdc,       staticProvider);
      const marketA    = new ethers.Contract(ADDRESSES.marketA,    ABIS.market,     staticProvider);
      const marketB    = new ethers.Contract(ADDRESSES.marketB,    ABIS.market,     staticProvider);

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
        // sentinel
        vaultInfoData,
        isPending,
        activeRequestId,
        latestRisk,
        history,
        hardLevel,
        // markets
        mktAUtil,
        mktBUtil,
        mktARate,
        mktBRate,
        mktABalance,
        mktBBalance,
        mktAAllocBps,
        mktBAllocBps,
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
        // sentinel
        sentinel.vaultInfo(ADDRESSES.vault),
        sentinel.isCheckPending(ADDRESSES.vault),
        sentinel.activeRequest(ADDRESSES.vault),
        sentinel.getLatestRisk(ADDRESSES.vault),
        sentinel.getHistory(ADDRESSES.vault),
        sentinel.assessOnChain(ADDRESSES.vault),
        // markets
        marketA.utilizationBps(),
        marketB.utilizationBps(),
        marketA.supplyRateBps().catch(() => 0n),
        marketB.supplyRateBps().catch(() => 0n),
        marketA.balanceOf(ADDRESSES.vault),
        marketB.balanceOf(ADDRESSES.vault),
        vault.marketAllocationBps(ADDRESSES.marketA),
        vault.marketAllocationBps(ADDRESSES.marketB),
        // strategist
        strategist.lastRequestAt(ADDRESSES.vault),
        strategist.activeRequest(ADDRESSES.vault),
      ]);

      let userUsdcBal = 0n, userShares = 0n, userStt = 0n;
      if (userAddress) {
        [userUsdcBal, userShares, userStt] = await Promise.all([
          usdc.balanceOf(userAddress),
          vault.balanceOf(userAddress),
          staticProvider.getBalance(userAddress),
        ]);
      }

      const historyItems = Array.from(history)
        .map(snap => ({
          timestamp:   Number(snap.timestamp),
          level:       Number(snap.level),
          verdict:     snap.rawVerdict,
          totalAssets: Number(snap.totalAssets) / 1e6,
          idleBps:     Number(snap.idleBps),
        }))
        .reverse();

      const totalA   = Number(totalAssets) / 1e6;
      const idleBps  = Number(idleBufferBps);
      const idleAmt  = Math.round(totalA * idleBps / 10000);
      const deployed = totalA - idleAmt;

      setData({
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
          sharePrice:          Number(ethers.formatEther(sharePrice)),
          totalSupply:         Number(ethers.formatUnits(totalSupply, 6)),
          idleAmt,
          deployed,
        },
        markets: [
          {
            address:       ADDRESSES.marketA,
            name:          'Market A',
            allocationBps: Number(mktAAllocBps),
            utilizationBps: Number(mktAUtil),
            supplyRateBps: Number(mktARate),
            balance:       Number(mktABalance) / 1e6,
          },
          {
            address:       ADDRESSES.marketB,
            name:          'Market B',
            allocationBps: Number(mktBAllocBps),
            utilizationBps: Number(mktBUtil),
            supplyRateBps: Number(mktBRate),
            balance:       Number(mktBBalance) / 1e6,
          },
        ],
        sentinel: {
          registered:       vaultInfoData.registered,
          autoPauseEnabled: vaultInfoData.autoPauseEnabled,
          lastLevel:        Number(vaultInfoData.lastLevel),
          lastCheckedAt:    Number(vaultInfoData.lastCheckedAt),
          totalChecks:      Number(vaultInfoData.totalChecks),
          criticalCount:    Number(vaultInfoData.criticalCount),
          isCheckPending:   isPending,
          activeRequestId:  activeRequestId.toString(),
          latestVerdict:    latestRisk.verdict,
          latestVerdictTs:  Number(latestRisk.ts),
          latestLevel:      Number(latestRisk.level),
          hardLevel:        Number(hardLevel),
          history:          historyItems,
        },
        strategist: {
          lastRequestAt:    Number(stratLastRequest),
          activeRequest:    stratActiveRequest.toString(),
          isPending:        stratActiveRequest.toString() !== '0',
        },
        user: {
          address:     userAddress,
          usdcBalance: Number(userUsdcBal) / 1e6,
          shares:      Number(ethers.formatUnits(userShares, 6)),
          sttBalance:  Number(ethers.formatEther(userStt)),
        },
      });

      setError(null);
      setLastRefresh(new Date());
    } catch (e) {
      console.error('Protocol fetch error:', e);
      setError(e.shortMessage || e.message);
    } finally {
      setIsLoading(false);
      pendingRef.current = false;
    }
  }, [userAddress]);

  useEffect(() => {
    fetchData();
    const interval = setInterval(fetchData, 12_000);
    return () => clearInterval(interval);
  }, [fetchData]);

  return { data, isLoading, error, lastRefresh, refetch: fetchData };
}
