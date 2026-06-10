import React, { useState, useCallback, useEffect } from 'react';
import { Routes, Route, useNavigate } from 'react-router-dom';
import { ethers } from 'ethers';
import { ADDRESSES, ABIS, SOMNIA_NETWORK, CHAIN_ID, CHECK_DEPOSIT, REBALANCE_DEPOSIT } from './config';

import Header        from './components/Header';
import VaultListPage from './pages/VaultListPage';
import VaultDetailPage from './pages/VaultDetailPage';
import DemoPage      from './pages/DemoPage';

// ── Toast ─────────────────────────────────────────────────────────────────────

function Toast({ toasts }) {
  return (
    <div className="fixed top-[5rem] right-4 z-50 space-y-2 max-w-sm w-full pointer-events-none">
      {toasts.map(t => (
        <div
          key={t.id}
          className={`pointer-events-auto px-4 py-3 rounded-xl border text-sm shadow-2xl
            ${t.type === 'error'   ? 'bg-red-950/95 border-red-700/60 text-red-200'
            : t.type === 'success' ? 'bg-emerald-950/95 border-emerald-700/60 text-emerald-200'
            : t.type === 'pending' ? 'bg-blue-950/95 border-blue-700/60 text-blue-200'
            :                        'bg-zinc-900/95 border-white/10 text-zinc-200'}`}
        >
          <div className="flex items-start gap-2">
            <span className="mt-0.5 flex-shrink-0 font-bold">
              {t.type === 'error' ? '✕' : t.type === 'success' ? '✓' : t.type === 'pending' ? '↻' : 'ℹ'}
            </span>
            <span className="leading-snug">{t.msg}</span>
          </div>
          {t.hash && (
            <a
              href={`https://shannon-explorer.somnia.network/tx/${t.hash}`}
              target="_blank" rel="noreferrer"
              className="block mt-1 text-xs underline opacity-60 hover:opacity-100 ml-5"
            >
              View on explorer ↗
            </a>
          )}
        </div>
      ))}
    </div>
  );
}

// ── App ───────────────────────────────────────────────────────────────────────

export default function App() {
  const [provider, setProvider]       = useState(null);
  const [signer, setSigner]           = useState(null);
  const [userAddress, setUserAddress] = useState(null);
  const [chainId, setChainId]         = useState(null);
  const [toasts, setToasts]           = useState([]);

  // ── Toast helpers ─────────────────────────────────────────────────────────

  const addToast = useCallback((msg, type = 'info', hash = '', duration = 5000) => {
    const id = Date.now() + Math.random();
    setToasts(prev => [...prev, { id, msg, type, hash }]);
    if (duration > 0) setTimeout(() => setToasts(prev => prev.filter(t => t.id !== id)), duration);
    return id;
  }, []);

  const removeToast = useCallback(id => setToasts(prev => prev.filter(t => t.id !== id)), []);

  // ── Wallet ────────────────────────────────────────────────────────────────

  const connectWallet = async () => {
    if (!window.ethereum) {
      addToast('MetaMask not found. Please install MetaMask.', 'error'); return;
    }
    try {
      const p   = new ethers.BrowserProvider(window.ethereum);
      await p.send('eth_requestAccounts', []);
      const s   = await p.getSigner();
      const addr = await s.getAddress();
      const net  = await p.getNetwork();
      setProvider(p); setSigner(s); setUserAddress(addr); setChainId(Number(net.chainId));
      addToast('Wallet connected', 'success');
    } catch (e) {
      if (e.code !== 4001) addToast('Connection failed: ' + e.message, 'error');
    }
  };

  useEffect(() => {
    if (!window.ethereum) return;
    (async () => {
      try {
        const accounts = await window.ethereum.request({ method: 'eth_accounts' });
        if (!accounts.length) return;
        const p   = new ethers.BrowserProvider(window.ethereum);
        const s   = await p.getSigner();
        const net = await p.getNetwork();
        setProvider(p); setSigner(s); setUserAddress(accounts[0]); setChainId(Number(net.chainId));
      } catch {}
    })();
  }, []);

  useEffect(() => {
    if (!window.ethereum) return;
    const onChain    = (hex) => setChainId(parseInt(hex, 16));
    const onAccounts = (accounts) => {
      if (!accounts.length) { setSigner(null); setUserAddress(null); setChainId(null); }
      else setUserAddress(accounts[0]);
    };
    window.ethereum.on('chainChanged',    onChain);
    window.ethereum.on('accountsChanged', onAccounts);
    return () => {
      window.ethereum.removeListener('chainChanged',    onChain);
      window.ethereum.removeListener('accountsChanged', onAccounts);
    };
  }, []);

  const switchNetwork = async () => {
    try {
      await window.ethereum.request({ method: 'wallet_switchEthereumChain', params: [{ chainId: SOMNIA_NETWORK.chainId }] });
    } catch (e) {
      if (e.code === 4902) {
        try { await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [SOMNIA_NETWORK] }); } catch {}
      }
    }
  };

  // ── TX wrapper ────────────────────────────────────────────────────────────

  const withTx = useCallback(async (label, fn, onSuccess) => {
    const pid = addToast(`${label}: confirm in MetaMask…`, 'pending', '', 0);
    try {
      const tx = await fn();
      removeToast(pid);
      const wid = addToast(`${label}: confirming…`, 'pending', tx.hash, 0);
      await tx.wait();
      removeToast(wid);
      addToast(`${label}: success!`, 'success', tx.hash);
      if (onSuccess) onSuccess();
      return true;
    } catch (e) {
      removeToast(pid);
      if (e.code !== 4001) addToast(`${label} failed: ${e.reason || e.shortMessage || e.message}`, 'error');
      return false;
    }
  }, [addToast, removeToast]);

  // ── Contract builders ─────────────────────────────────────────────────────

  const contracts = useCallback((vaultConfig) => {
    if (!signer) return null;
    const addr = vaultConfig?.address || ADDRESSES.vault;
    return {
      vault:      new ethers.Contract(addr,                     ABIS.vault,      signer),
      sentinel:   new ethers.Contract(vaultConfig?.sentinel   || ADDRESSES.sentinel,   ABIS.sentinel,   signer),
      strategist: new ethers.Contract(vaultConfig?.strategist || ADDRESSES.strategist, ABIS.strategist, signer),
      usdc:       new ethers.Contract(vaultConfig?.assetAddr  || ADDRESSES.usdc,       ABIS.usdc,       signer),
      markets:    (vaultConfig?.markets || []).map(m =>
        ({ ...m, contract: new ethers.Contract(m.address, ABIS.market, signer) })
      ),
    };
  }, [signer]);

  // ── Action handlers (passed to pages) ────────────────────────────────────

  const isWrongNetwork = chainId !== null && chainId !== CHAIN_ID;
  const isConnected    = !!signer && !isWrongNetwork;

  const makeActions = useCallback((vaultConfig, refetch) => ({
    onCheckVault: async () => {
      const cx = contracts(vaultConfig);
      if (!cx) return addToast('Connect wallet first', 'error');
      await withTx('AI Risk Check', () =>
        cx.sentinel.checkVault(vaultConfig?.address || ADDRESSES.vault, { value: ethers.parseEther(CHECK_DEPOSIT) }),
        refetch
      );
    },

    onRequestRebalance: async () => {
      const cx = contracts(vaultConfig);
      if (!cx) return addToast('Connect wallet first', 'error');
      await withTx('AI Rebalance', () =>
        cx.strategist.requestRebalance(vaultConfig?.address || ADDRESSES.vault, { value: ethers.parseEther(REBALANCE_DEPOSIT) }),
        refetch
      );
    },

    onUnpause: async () => {
      const cx = contracts(vaultConfig);
      if (!cx) return addToast('Connect wallet first', 'error');
      await withTx('Unpause Deposits', () => cx.vault.unpauseDeposits(), refetch);
    },

    onDeposit: async (amount) => {
      const cx = contracts(vaultConfig);
      if (!cx || !userAddress) return addToast('Connect wallet first', 'error');
      const decimals = vaultConfig?.assetDecimals ?? 6;
      const parsed = ethers.parseUnits(amount, decimals);

      // Pre-flight: check available capacity before wasting the approval tx
      try {
        const available = await cx.vault.maxDeposit(userAddress);
        if (parsed > available) {
          const avail = Number(available) / Math.pow(10, decimals);
          return addToast(
            avail <= 0
              ? `Vault is at capacity. Withdraw first to free space.`
              : `Exceeds vault capacity. Max deposit: ${avail.toLocaleString()} ${vaultConfig?.asset}`,
            'error'
          );
        }
      } catch {}

      const pid = addToast('Step 1/2: Approving…', 'pending', '', 0);
      try {
        const t1 = await cx.usdc.approve(vaultConfig?.address || ADDRESSES.vault, parsed);
        await t1.wait();
        removeToast(pid);
        const wid = addToast('Step 2/2: Depositing…', 'pending', '', 0);
        const t2 = await cx.vault.deposit(parsed, userAddress);
        await t2.wait();
        removeToast(wid);
        addToast(`Deposited ${Number(amount).toLocaleString()} ${vaultConfig?.asset || 'USDC'}!`, 'success', t2.hash);
        if (refetch) setTimeout(refetch, 2000);
      } catch (e) {
        removeToast(pid);
        if (e.code !== 4001) {
          const msg = e.reason || e.shortMessage || e.message || '';
          const friendly = msg.includes('DepositExceedsCap') || msg.includes('cap')
            ? 'Vault is at capacity. Withdraw first to free space.'
            : 'Deposit failed: ' + msg;
          addToast(friendly, 'error');
        }
      }
    },

    onWithdraw: async (shares) => {
      const cx = contracts(vaultConfig);
      if (!cx || !userAddress) return addToast('Connect wallet first', 'error');
      const decimals = vaultConfig?.assetDecimals ?? 6;
      await withTx('Withdraw', () =>
        cx.vault.redeem(ethers.parseUnits(shares, decimals), userAddress, userAddress),
        refetch
      );
    },

    // ── Demo scenario: SAFE ──────────────────────────────────────────
    // Txs: oracle + up to 2 deallocations + 2 setUtil = max 5
    onSetSafe: async () => {
      const cx = contracts(vaultConfig);
      if (!cx) return addToast('Connect wallet first', 'error');
      const pid = addToast('Setting SAFE scenario…', 'pending', '', 0);
      try {
        // 1. Disable oracle
        const t0 = await cx.sentinel.setOracle('0x0000000000000000000000000000000000000000');
        await t0.wait();
        // 2. Withdraw as much as the market actually holds (avoids no-liquidity with no extra mints)
        //    Tiny unpaid-yield dust left in market is << 25% alloc threshold — SAFE still passes.
        for (const m of cx.markets) {
          const vaultPos = await m.contract.balanceOf(vaultConfig.address);
          if (vaultPos === 0n) continue;
          const marketTokens = await m.contract.totalAssets();
          const toWithdraw = vaultPos < marketTokens ? vaultPos : marketTokens;
          if (toWithdraw > 0n) {
            const t = await cx.vault.deallocate(m.address, toWithdraw);
            await t.wait();
          }
        }
        // 3. Set low utilization on all markets
        for (const m of cx.markets) {
          const t = await m.contract.setUtilization(20);
          await t.wait();
        }
        removeToast(pid);
        addToast('SAFE scenario set. Go to Risk AI tab → Run Risk Check.', 'success');
        if (refetch) setTimeout(refetch, 2000);
      } catch (e) {
        removeToast(pid);
        if (e.code !== 4001) addToast('Set SAFE failed: ' + (e.reason || e.shortMessage || e.message), 'error');
      }
    },

    // ── Demo scenario: CAUTION ───────────────────────────────────────
    // Txs: oracle + 2 setUtil = 3 total
    onSetCaution: async () => {
      const cx = contracts(vaultConfig);
      if (!cx) return addToast('Connect wallet first', 'error');
      const pid = addToast('Setting CAUTION scenario…', 'pending', '', 0);
      try {
        const t0 = await cx.sentinel.setOracle('0x0000000000000000000000000000000000000000');
        await t0.wait();
        const t1 = await cx.markets[0].contract.setUtilization(85);
        await t1.wait();
        const t2 = await cx.markets[1].contract.setUtilization(50);
        await t2.wait();
        removeToast(pid);
        addToast('CAUTION scenario set. Go to Risk AI tab → Run Risk Check.', 'success');
        if (refetch) setTimeout(refetch, 2000);
      } catch (e) {
        removeToast(pid);
        if (e.code !== 4001) addToast('Set CAUTION failed: ' + (e.reason || e.shortMessage || e.message), 'error');
      }
    },

    // ── Demo scenario: CRITICAL ──────────────────────────────────────
    // Fast path (normal state): mktB already > 40% alloc → oracle + setUtil = 2 txs.
    // Rebuild path (after Set SAFE emptied markets): oracle + 2 dealloc + alloc + setUtil = max 5 txs.
    onSetCritical: async () => {
      const cx = contracts(vaultConfig);
      if (!cx) return addToast('Connect wallet first', 'error');
      const pid = addToast('Setting CRITICAL scenario…', 'pending', '', 0);
      try {
        const mktB = cx.markets[1];
        const mktA = cx.markets[0];

        // 1. Disable oracle
        const t0 = await cx.sentinel.setOracle('0x0000000000000000000000000000000000000000');
        await t0.wait();

        // 2. Check if mktB already satisfies the > 40% alloc threshold
        const totalAssets = await cx.vault.totalAssets();
        const mktBPos    = await mktB.contract.balanceOf(vaultConfig.address);
        const allocBps   = totalAssets > 0n ? mktBPos * 10000n / totalAssets : 0n;

        if (allocBps <= 4000n) {
          // Rebuild: safe-withdraw both markets (no minting — withdraw min of position vs tokens held)
          const safeDeallocate = async (mkt) => {
            const pos = await mkt.contract.balanceOf(vaultConfig.address);
            if (pos === 0n) return;
            const held = await mkt.contract.totalAssets();
            const amt  = pos < held ? pos : held;
            if (amt > 0n) { const t = await cx.vault.deallocate(mkt.address, amt); await t.wait(); }
          };
          await safeDeallocate(mktA);
          await safeDeallocate(mktB);

          // Allocate 45% of vault to mktB (55% stays idle — above 10% floor)
          const fresh = await cx.vault.totalAssets();
          const want  = fresh * 45n / 100n;
          const cap   = (await cx.vault.markets(mktB.address))[1];
          const alloc = want < cap ? want : cap * 9n / 10n;
          if (alloc > 0n) { const t = await cx.vault.allocate(mktB.address, alloc); await t.wait(); }
        }

        // 3. Set mktB utilization to 96% (> 95% threshold)
        const t3 = await mktB.contract.setUtilization(96);
        await t3.wait();

        removeToast(pid);
        addToast('CRITICAL scenario set. Go to Risk AI tab → Run Risk Check.', 'success');
        if (refetch) setTimeout(refetch, 2000);
      } catch (e) {
        removeToast(pid);
        if (e.code !== 4001) addToast('Set CRITICAL failed: ' + (e.reason || e.shortMessage || e.message), 'error');
      }
    },

    // ── Demo utility: Reset vault to seed state ──────────────────────
    // Restores the exact state from ExecuteAndSeed.s.sol:
    //   USDC 100k → 30k mktA / 20k mktB / 50k idle, util 45%/72%, rate 3%/5.2%
    //   WETH 100  → 30  mktA / 20  mktB / 50  idle, util 55%/68%, rate 3.8%/5.1%
    //   WBTC 10   → 3   mktA / 2   mktB / 5   idle, util 40%/62%, rate 2.8%/4.5%
    onReset: async () => {
      const cx   = contracts(vaultConfig);
      if (!cx || !signer) return addToast('Connect wallet first', 'error');
      const seed = vaultConfig?.seed;
      if (!seed) return addToast('No seed config for this vault', 'error');

      const dec      = vaultConfig.assetDecimals;
      const toRaw    = (n) => BigInt(Math.round(n * 10 ** dec));
      const seedDep  = toRaw(seed.deposit);
      const seedA    = toRaw(seed.allocA);
      const seedB    = toRaw(seed.allocB);
      const mktA     = cx.markets[0];
      const mktB     = cx.markets[1];

      const pid = addToast('Resetting vault to seed state…', 'pending', '', 0);
      try {
        // 1. Disable oracle
        const t0 = await cx.sentinel.setOracle('0x0000000000000000000000000000000000000000');
        await t0.wait();

        // 2. Safe-deallocate both markets (withdraw min of position vs tokens held)
        for (const mkt of [mktA, mktB]) {
          const pos  = await mkt.contract.balanceOf(vaultConfig.address);
          if (pos === 0n) continue;
          const held = await mkt.contract.totalAssets();
          const amt  = pos < held ? pos : held;
          if (amt > 0n) { const t = await cx.vault.deallocate(mkt.address, amt); await t.wait(); }
        }

        // 3. If vault is near empty, mint + deposit to reach seed amount
        const currentTotal = await cx.vault.totalAssets();
        if (currentTotal < seedDep / 10n) {
          const toMint = seedDep - currentTotal;
          const tm = await cx.usdc.mint(await signer.getAddress(), toMint);
          await tm.wait();
          const ta = await cx.usdc.approve(vaultConfig.address, toMint);
          await ta.wait();
          const td = await cx.vault.deposit(toMint, await signer.getAddress());
          await td.wait();
        }

        // 4. Allocate to seed targets (capped by supply caps)
        const [, capA] = await cx.vault.markets(mktA.address);
        const [, capB] = await cx.vault.markets(mktB.address);
        const allocA = seedA < capA ? seedA : capA * 9n / 10n;
        const allocB = seedB < capB ? seedB : capB * 9n / 10n;
        const t1 = await cx.vault.allocate(mktA.address, allocA);
        await t1.wait();
        const t2 = await cx.vault.allocate(mktB.address, allocB);
        await t2.wait();

        // 5. Restore original utilizations and supply rates
        const t3 = await mktA.contract.setUtilization(seed.utilA);
        await t3.wait();
        const t4 = await mktB.contract.setUtilization(seed.utilB);
        await t4.wait();
        const t5 = await mktA.contract.setSupplyRate(seed.rateA);
        await t5.wait();
        const t6 = await mktB.contract.setSupplyRate(seed.rateB);
        await t6.wait();

        removeToast(pid);
        addToast('Vault reset to initial seed state.', 'success');
        if (refetch) setTimeout(refetch, 2000);
      } catch (e) {
        removeToast(pid);
        if (e.code !== 4001) addToast('Reset failed: ' + (e.reason || e.shortMessage || e.message), 'error');
      }
    },

    // ── Demo utility: Mint tokens ────────────────────────────────────
    onMintToken: async () => {
      const cx = contracts(vaultConfig);
      if (!cx || !userAddress) return addToast('Connect wallet first', 'error');
      const decimals = vaultConfig?.assetDecimals ?? 6;
      await withTx(`Mint ${vaultConfig?.asset}`, () =>
        cx.usdc.mint(userAddress, ethers.parseUnits('10000', decimals)),
        refetch
      );
    },

    // ── Demo utility: Simulate yield ─────────────────────────────────
    // Mints yield buffer to each market before advancing index so
    // withdrawal never fails due to insufficient market liquidity.
    onSimulateYield: async () => {
      const cx = contracts(vaultConfig);
      if (!cx) return addToast('Connect wallet first', 'error');
      const pid = addToast('Simulating 30-day yield…', 'pending', '', 0);
      try {
        for (const m of cx.markets) {
          // Read actual ERC20 balance held by the market contract
          const marketBal = await m.contract.totalAssets();
          if (marketBal > 0n) {
            // Mint 6% buffer to the market (covers ~5% yield for 365 days at 5% APY + safety margin)
            const yieldBuffer = marketBal * 6n / 100n;
            const t1 = await cx.usdc.mint(m.address, yieldBuffer);
            await t1.wait();
          }
          // Advance the interest index by 365 days (~5% APY yield)
          const t2 = await m.contract.fastForwardDays(365);
          await t2.wait();
        }
        removeToast(pid);
        addToast('+~5% yield applied. Share price increased.', 'success');
        if (refetch) setTimeout(refetch, 2000);
      } catch (e) {
        removeToast(pid);
        if (e.code !== 4001) addToast('Yield simulation failed: ' + (e.reason || e.shortMessage || e.message), 'error');
      }
    },

    // Keep legacy name for DemoPage compat
    onMintUsdc: async () => {
      const cx = contracts(vaultConfig);
      if (!cx || !userAddress) return addToast('Connect wallet first', 'error');
      const decimals = vaultConfig?.assetDecimals ?? 6;
      await withTx(`Mint ${vaultConfig?.asset}`, () =>
        cx.usdc.mint(userAddress, ethers.parseUnits('10000', decimals)),
        refetch
      );
    },
  }), [contracts, addToast, removeToast, withTx, userAddress]);

  const walletProps = { userAddress, chainId, isConnected, isWrongNetwork, onConnect: connectWallet, onSwitchNetwork: switchNetwork };

  return (
    <div className="min-h-screen bg-black text-white">
      <Toast toasts={toasts} />
      <Header {...walletProps} />

      {isWrongNetwork && (
        <div className="border-b border-amber-800/40 bg-amber-950/30">
          <div className="max-w-7xl mx-auto px-6 py-2.5 flex items-center justify-between">
            <div className="flex items-center gap-2 text-sm text-amber-300">
              <span>⚠</span>
              <span>Wrong network — switch to Somnia Testnet (Chain ID 50312)</span>
            </div>
            <button onClick={switchNetwork}
              className="px-4 py-1.5 rounded-lg bg-amber-600 hover:bg-amber-500 text-white text-xs font-semibold">
              Switch
            </button>
          </div>
        </div>
      )}

      <Routes>
        <Route path="/" element={<VaultListPage walletProps={walletProps} />} />
        <Route path="/vault/:vaultAddress" element={
          <VaultDetailPage walletProps={walletProps} makeActions={makeActions} />
        } />
        <Route path="/demo" element={
          <DemoPage
            walletProps={walletProps}
            makeActions={makeActions}
          />
        } />
      </Routes>
    </div>
  );
}
