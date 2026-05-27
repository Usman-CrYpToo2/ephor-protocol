import React, { useState, useCallback, useEffect } from 'react';
import { ethers } from 'ethers';
import { ADDRESSES, ABIS, SOMNIA_NETWORK, CHAIN_ID, CHECK_DEPOSIT } from './config';
import { useProtocol } from './hooks/useProtocol';

import Header     from './components/Header';
import TabNav     from './components/TabNav';
import DashboardPage from './pages/DashboardPage';
import PositionPage  from './pages/PositionPage';
import SentinelPage  from './pages/SentinelPage';
import DemoPage      from './pages/DemoPage';

// ── Toast notifications ───────────────────────────────────────────────────────

function Toast({ toasts }) {
  return (
    <div className="fixed top-[7rem] right-4 z-50 space-y-2 max-w-sm w-full pointer-events-none">
      {toasts.map(t => (
        <div
          key={t.id}
          className={`pointer-events-auto animate-fade-in px-4 py-3 rounded-xl border text-sm shadow-2xl
            ${t.type === 'error'   ? 'bg-red-950/95 border-red-700/60 text-red-200'
            : t.type === 'success' ? 'bg-emerald-950/95 border-emerald-700/60 text-emerald-200'
            : t.type === 'pending' ? 'bg-blue-950/95 border-blue-700/60 text-blue-200'
            :                        'bg-slate-900/95 border-slate-700/60 text-slate-200'}`}
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

// ── Critical banner ───────────────────────────────────────────────────────────

function CriticalBanner({ show }) {
  if (!show) return null;
  return (
    <div className="bg-red-950/40 border-b border-red-800/40">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 py-2.5 flex items-center gap-3">
        <span className="text-red-400 text-base flex-shrink-0">⚠</span>
        <p className="text-sm text-red-300">
          <strong>Critical risk detected.</strong> Deposits are paused and emergency deallocation has been executed.
          Review conditions in <strong>Demo Controls</strong> and use <strong>Unpause Deposits</strong> to restore operations.
        </p>
      </div>
    </div>
  );
}

// ── App ───────────────────────────────────────────────────────────────────────

export default function App() {
  const [tab, setTab]                 = useState('dashboard');
  const [provider, setProvider]       = useState(null);
  const [signer, setSigner]           = useState(null);
  const [userAddress, setUserAddress] = useState(null);
  const [chainId, setChainId]         = useState(null);
  const [toasts, setToasts]           = useState([]);

  const { data, isLoading, error, lastRefresh, refetch } = useProtocol(userAddress);

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
      const p = new ethers.BrowserProvider(window.ethereum);
      await p.send('eth_requestAccounts', []);
      const s    = await p.getSigner();
      const addr = await s.getAddress();
      const net  = await p.getNetwork();
      setProvider(p); setSigner(s); setUserAddress(addr); setChainId(Number(net.chainId));
      addToast(`Wallet connected`, 'success');
    } catch (e) {
      if (e.code !== 4001) addToast('Connection failed: ' + e.message, 'error');
    }
  };

  // Restore session on page load if MetaMask is already connected
  useEffect(() => {
    if (!window.ethereum) return;
    const restore = async () => {
      try {
        const accounts = await window.ethereum.request({ method: 'eth_accounts' });
        if (!accounts.length) return;
        const p   = new ethers.BrowserProvider(window.ethereum);
        const s   = await p.getSigner();
        const net = await p.getNetwork();
        setProvider(p); setSigner(s); setUserAddress(accounts[0]); setChainId(Number(net.chainId));
      } catch {}
    };
    restore();
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
        try { await window.ethereum.request({ method: 'wallet_addEthereumChain', params: [SOMNIA_NETWORK] }); }
        catch {}
      }
    }
  };

  // ── Transaction wrapper ───────────────────────────────────────────────────
  const withTx = useCallback(async (label, fn) => {
    const pid = addToast(`${label}: confirm in MetaMask…`, 'pending', '', 0);
    try {
      const tx = await fn();
      removeToast(pid);
      const wid = addToast(`${label}: confirming…`, 'pending', tx.hash, 0);
      await tx.wait();
      removeToast(wid);
      addToast(`${label}: success!`, 'success', tx.hash);
      setTimeout(refetch, 2000);
      return true;
    } catch (e) {
      removeToast(pid);
      if (e.code !== 4001) addToast(`${label} failed: ${e.reason || e.shortMessage || e.message}`, 'error');
      return false;
    }
  }, [addToast, removeToast, refetch]);

  // ── Contract accessors ────────────────────────────────────────────────────
  const c = useCallback(() => {
    if (!signer) return null;
    return {
      vault:    new ethers.Contract(ADDRESSES.vault,    ABIS.vault,    signer),
      sentinel: new ethers.Contract(ADDRESSES.sentinel, ABIS.sentinel, signer),
      usdc:     new ethers.Contract(ADDRESSES.usdc,     ABIS.usdc,     signer),
      marketA:  new ethers.Contract(ADDRESSES.marketA,  ABIS.market,   signer),
      marketB:  new ethers.Contract(ADDRESSES.marketB,  ABIS.market,   signer),
    };
  }, [signer]);

  // ── Action handlers ───────────────────────────────────────────────────────

  const handleCheckVault = async () => {
    const cx = c();
    if (!cx) return addToast('Connect wallet first', 'error');
    await withTx('AI Risk Check', () =>
      cx.sentinel.checkVault(ADDRESSES.vault, { value: ethers.parseEther(CHECK_DEPOSIT) })
    );
  };

  const handleUnpause = async () => {
    const cx = c();
    if (!cx) return addToast('Connect wallet first', 'error');
    await withTx('Unpause Deposits', () => cx.vault.unpauseDeposits());
  };

  const handleSetCritical = async () => {
    const cx = c();
    if (!cx) return addToast('Connect wallet first', 'error');
    const pid = addToast('Setting CRITICAL scenario…', 'pending', '', 0);
    try {
      const mktABalance = data?.markets?.[0]?.balance ?? 0;
      const target = 30000;
      if (mktABalance < target) {
        const toAdd = Math.floor((target - mktABalance) * 1e6);
        const t1 = await cx.vault.allocate(ADDRESSES.marketA, BigInt(toAdd));
        await t1.wait();
      }
      const t2 = await cx.marketA.setUtilization(96);
      await t2.wait();
      removeToast(pid);
      addToast('CRITICAL scenario set — Market A: 60% alloc, 96% util. Trigger AI Check now.', 'success');
      setTimeout(refetch, 2000);
    } catch (e) {
      removeToast(pid);
      if (e.code !== 4001) addToast('Failed: ' + (e.reason || e.shortMessage || e.message), 'error');
    }
  };

  const handleSetCaution = async () => {
    const cx = c();
    if (!cx) return addToast('Connect wallet first', 'error');
    await withTx('Set CAUTION', () => cx.marketA.setUtilization(85));
  };

  const handleSetSafe = async () => {
    const cx = c();
    if (!cx) return addToast('Connect wallet first', 'error');
    await withTx('Reset to SAFE', () => cx.marketA.setUtilization(30));
  };

  const handleMintUsdc = async () => {
    const cx = c();
    if (!cx || !userAddress) return addToast('Connect wallet first', 'error');
    await withTx('Mint USDC', () => cx.usdc.mint(userAddress, ethers.parseUnits('10000', 6)));
  };

  const handleDeposit = async (amount) => {
    const cx = c();
    if (!cx || !userAddress) return addToast('Connect wallet first', 'error');
    const parsedAmount = ethers.parseUnits(amount, 6);
    const pid = addToast('Step 1/2: Approving USDC…', 'pending', '', 0);
    try {
      const t1 = await cx.usdc.approve(ADDRESSES.vault, parsedAmount);
      await t1.wait();
      removeToast(pid);
      const wid = addToast('Step 2/2: Depositing into vault…', 'pending', '', 0);
      const t2 = await cx.vault.deposit(parsedAmount, userAddress);
      await t2.wait();
      removeToast(wid);
      addToast(`Deposited ${Number(amount).toLocaleString()} USDC! Shares minted to your wallet.`, 'success', t2.hash);
      setTimeout(refetch, 2000);
    } catch (e) {
      removeToast(pid);
      if (e.code !== 4001) addToast('Deposit failed: ' + (e.reason || e.shortMessage || e.message), 'error');
    }
  };

  const handleWithdraw = async (shares) => {
    const cx = c();
    if (!cx || !userAddress) return addToast('Connect wallet first', 'error');
    await withTx('Withdraw', () =>
      cx.vault.redeem(ethers.parseUnits(shares, 6), userAddress, userAddress)
    );
  };

  const handleSimulateYield = async () => {
    const cx = c();
    if (!cx) return addToast('Connect wallet first', 'error');
    const days = 30;
    const pid  = addToast(`Simulating ${days}-day yield on both markets…`, 'pending', '', 0);
    try {
      const t1 = await cx.marketA.fastForwardDays(days);
      await t1.wait();
      const t2 = await cx.marketB.fastForwardDays(days);
      await t2.wait();
      removeToast(pid);
      const yieldPct = ((Math.pow(1.05, days / 365) - 1) * 100).toFixed(2);
      addToast(`+${yieldPct}% yield applied (5% APY × ${days} days). Check vault share price.`, 'success');
      setTimeout(refetch, 2000);
    } catch (e) {
      removeToast(pid);
      if (e.code !== 4001) addToast('Failed: ' + (e.reason || e.shortMessage || e.message), 'error');
    }
  };

  // ── Derived state ─────────────────────────────────────────────────────────
  const isWrongNetwork = chainId !== null && chainId !== CHAIN_ID;
  const isPaused       = data?.vault?.depositsPaused;
  const riskLevel      = data?.sentinel?.latestLevel;

  return (
    <div className="min-h-screen bg-[#07090f]">
      {/* Subtle grid bg */}
      <div className="fixed inset-0 opacity-30 pointer-events-none"
        style={{ backgroundImage: 'radial-gradient(circle at 1px 1px, #1a2234 1px, transparent 0)', backgroundSize: '40px 40px' }}
      />

      <Header
        userAddress={userAddress}
        chainId={chainId}
        onConnect={connectWallet}
        onSwitchNetwork={switchNetwork}
        isWrongNetwork={isWrongNetwork}
      />

      <TabNav active={tab} onChange={setTab} riskLevel={riskLevel} />

      <CriticalBanner show={isPaused} />

      <Toast toasts={toasts} />

      {/* Wrong network overlay */}
      {isWrongNetwork && (
        <div className="max-w-7xl mx-auto px-4 sm:px-6 pt-4">
          <div className="bg-amber-950/40 border border-amber-700/40 rounded-2xl px-5 py-3.5 flex items-center justify-between">
            <div className="flex items-center gap-3">
              <span className="text-amber-400">⚠</span>
              <div>
                <div className="text-amber-300 font-semibold text-sm">Wrong Network — Switch to Somnia Testnet</div>
                <div className="text-amber-400/60 text-xs">Chain ID 50312 required</div>
              </div>
            </div>
            <button onClick={switchNetwork} className="px-4 py-2 rounded-xl bg-amber-600 hover:bg-amber-500 text-white text-xs font-semibold transition-colors">
              Switch
            </button>
          </div>
        </div>
      )}

      {/* Page content */}
      <main className="relative max-w-7xl mx-auto px-4 sm:px-6 py-6">
        {tab === 'dashboard' && (
          <DashboardPage data={data} isLoading={isLoading} onNavigate={setTab} />
        )}
        {tab === 'position' && (
          <PositionPage
            data={data}
            isLoading={isLoading}
            isConnected={!!signer && !isWrongNetwork}
            onDeposit={handleDeposit}
            onWithdraw={handleWithdraw}
          />
        )}
        {tab === 'sentinel' && (
          <SentinelPage
            data={data}
            isLoading={isLoading}
            isConnected={!!signer && !isWrongNetwork}
            onCheckVault={handleCheckVault}
          />
        )}
        {tab === 'demo' && (
          <DemoPage
            data={data}
            isConnected={!!signer && !isWrongNetwork}
            onSetCritical={handleSetCritical}
            onSetCaution={handleSetCaution}
            onSetSafe={handleSetSafe}
            onSimulateYield={handleSimulateYield}
            onMintUsdc={handleMintUsdc}
            onUnpause={handleUnpause}
          />
        )}

        {/* Footer */}
        <div className="flex items-center justify-between pt-8 pb-4 text-xs text-slate-700 border-t border-slate-800/40 mt-8">
          <span>Ephor Protocol · Built on <a href="https://somnia.network" target="_blank" rel="noreferrer" className="hover:text-slate-500 transition-colors">Somnia Network</a> · Encode Club Agentathon</span>
          {lastRefresh && <span>Refreshed {lastRefresh.toLocaleTimeString()}</span>}
        </div>
      </main>
    </div>
  );
}
