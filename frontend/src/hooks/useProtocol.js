import { useState, useEffect, useCallback, useRef } from 'react';
import { ethers } from 'ethers';
import { ADDRESSES, ABIS, RPC_URL } from '../config';

const staticProvider = new ethers.JsonRpcProvider(RPC_URL);

export function useProtocol(userAddress) {
  const [data, setData] = useState(null);
  const [isLoading, setIsLoading] = useState(true);
  const [error, setError] = useState(null);
  const [lastRefresh, setLastRefresh] = useState(null);
  const pendingRef = useRef(false);

  const fetchData = useCallback(async () => {
    if (pendingRef.current) return;
    pendingRef.current = true;

    try {
      const vault    = new ethers.Contract(ADDRESSES.vault,    ABIS.vault,    staticProvider);
      const sentinel = new ethers.Contract(ADDRESSES.sentinel, ABIS.sentinel, staticProvider);
      const usdc     = new ethers.Contract(ADDRESSES.usdc,     ABIS.usdc,     staticProvider);
      const marketA  = new ethers.Contract(ADDRESSES.marketA,  ABIS.market,   staticProvider);
      const marketB  = new ethers.Contract(ADDRESSES.marketB,  ABIS.market,   staticProvider);

      const [
        totalAssets,
        depositsPaused,
        idleBufferPct,
        sharePrice,
        totalSupply,
        vaultInfoData,
        isPending,
        activeRequestId,
        latestRisk,
        history,
        mktAUtil,
        mktBUtil,
        mktABalance,
        mktBBalance,
        mktAAllocPct,
        mktBAllocPct,
      ] = await Promise.all([
        vault.totalAssets(),
        vault.depositsPaused(),
        vault.idleBufferPct(),
        vault.sharePrice(),
        vault.totalSupply(),
        sentinel.vaultInfo(ADDRESSES.vault),
        sentinel.isCheckPending(ADDRESSES.vault),
        sentinel.activeRequest(ADDRESSES.vault),
        sentinel.getLatestRisk(ADDRESSES.vault),
        sentinel.getHistory(ADDRESSES.vault),
        marketA.utilizationBps(),
        marketB.utilizationBps(),
        marketA.balanceOf(ADDRESSES.vault),
        marketB.balanceOf(ADDRESSES.vault),
        vault.marketAllocationPct(ADDRESSES.marketA),
        vault.marketAllocationPct(ADDRESSES.marketB),
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
          idlePct:     Number(snap.idlePct),
        }))
        .reverse();

      setData({
        vault: {
          totalAssets:    Number(totalAssets) / 1e6,
          depositsPaused,
          idleBufferPct:  Number(idleBufferPct),
          sharePrice:     Number(ethers.formatEther(sharePrice)),
          totalSupply:    Number(ethers.formatUnits(totalSupply, 6)),
        },
        markets: [
          {
            address:       ADDRESSES.marketA,
            name:          'Market A',
            allocationPct: Number(mktAAllocPct),
            utilizationBps: Number(mktAUtil),
            balance:       Number(mktABalance) / 1e6,
          },
          {
            address:       ADDRESSES.marketB,
            name:          'Market B',
            allocationPct: Number(mktBAllocPct),
            utilizationBps: Number(mktBUtil),
            balance:       Number(mktBBalance) / 1e6,
          },
        ],
        sentinel: {
          registered:        vaultInfoData.registered,
          autoPauseEnabled:  vaultInfoData.autoPauseEnabled,
          lastLevel:         Number(vaultInfoData.lastLevel),
          lastCheckedAt:     Number(vaultInfoData.lastCheckedAt),
          totalChecks:       Number(vaultInfoData.totalChecks),
          criticalCount:     Number(vaultInfoData.criticalCount),
          isCheckPending:    isPending,
          activeRequestId:   activeRequestId.toString(),
          latestVerdict:     latestRisk.verdict,
          latestVerdictTs:   Number(latestRisk.ts),
          latestLevel:       Number(latestRisk.level),
          history:           historyItems,
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

    // Poll faster (5s) when a check is pending, otherwise 12s
    const interval = setInterval(() => {
      fetchData();
    }, 12_000);

    return () => clearInterval(interval);
  }, [fetchData]);

  return { data, isLoading, error, lastRefresh, refetch: fetchData };
}
