import { useState, useEffect } from 'react';
import { ethers } from 'ethers';
import { ABIS, RPC_URL, VAULTS } from '../config';

const staticProvider = new ethers.JsonRpcProvider(RPC_URL);

export function useVaultList() {
  const [vaults, setVaults] = useState(null);
  const [isLoading, setIsLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;

    async function fetchAll() {
      const results = await Promise.all(
        VAULTS.map(async (cfg) => {
          if (cfg.comingSoon || !cfg.address) {
            return { ...cfg, totalAssets: null, netApy: null, liquidity: null, level: null };
          }
          try {
            const vault    = new ethers.Contract(cfg.address, ABIS.vault, staticProvider);
            const sentinel = new ethers.Contract(cfg.sentinel, ABIS.sentinel, staticProvider);

            const [totalAssets, idleBufferBps, latestRisk] = await Promise.all([
              vault.totalAssets(),
              vault.idleBufferBps(),
              sentinel.getLatestRisk(cfg.address).catch(() => ({ level: 0n, ts: 0n, verdict: '' })),
            ]);

            // Fetch market rates for APY computation
            const marketData = await Promise.all(
              cfg.markets.map(async (m) => {
                const mkt = new ethers.Contract(m.address, ABIS.market, staticProvider);
                const [allocBps, rateBps] = await Promise.all([
                  vault.marketAllocationBps(m.address).catch(() => 0n),
                  mkt.supplyRateBps().catch(() => 0n),
                ]);
                return { allocationBps: Number(allocBps), supplyRateBps: Number(rateBps) };
              })
            );

            const divisor  = Math.pow(10, cfg.assetDecimals);
            const totalA   = Number(totalAssets) / divisor;
            const idleBps  = Number(idleBufferBps);
            const liquidity = totalA * idleBps / 10000;
            const netApy   = marketData.reduce((s, m) =>
              s + (m.allocationBps / 10000) * (m.supplyRateBps / 10000) * 100, 0);

            return {
              ...cfg,
              totalAssets: totalA,
              liquidity,
              netApy,
              level: Number(latestRisk.level),
            };
          } catch {
            return { ...cfg, totalAssets: null, netApy: null, liquidity: null, level: null };
          }
        })
      );

      if (!cancelled) {
        setVaults(results);
        setIsLoading(false);
      }
    }

    fetchAll();
    const interval = setInterval(fetchAll, 20_000);
    return () => { cancelled = true; clearInterval(interval); };
  }, []);

  return { vaults, isLoading };
}
