import React, { useState } from 'react';
import { formatUSDC } from '../config';

// ── Portfolio summary ─────────────────────────────────────────────────────────

function PortfolioCard({ data }) {
  const user       = data?.user;
  const vault      = data?.vault;
  const sharePrice = vault?.sharePrice ?? 1;
  const positionValue = user?.shares ? (user.shares * sharePrice) : 0;
  const pnl = user?.shares && vault?.sharePrice ? ((vault.sharePrice - 1) * 100).toFixed(4) : null;

  return (
    <div className="glass-card rounded-2xl p-6">
      <h3 className="text-sm font-semibold text-slate-400 uppercase tracking-wider mb-5">Your Portfolio</h3>

      <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
        {/* USDC balance */}
        <div className="bg-slate-800/40 rounded-xl p-4">
          <div className="text-xs text-slate-500 mb-2">Wallet USDC</div>
          <div className="text-2xl font-bold font-mono text-white">${formatUSDC(user?.usdcBalance ?? 0)}</div>
          <div className="text-xs text-slate-600 mt-1">Available to deposit</div>
        </div>

        {/* Vault shares */}
        <div className="bg-indigo-500/8 border border-indigo-500/15 rounded-xl p-4">
          <div className="text-xs text-slate-500 mb-2">Vault Shares</div>
          <div className="text-2xl font-bold font-mono text-indigo-400">
            {user?.shares > 0 ? user.shares.toFixed(4) : '0'}
          </div>
          <div className="text-xs text-slate-600 mt-1">Yield-bearing shares</div>
        </div>

        {/* Position value */}
        <div className="bg-emerald-500/8 border border-emerald-500/15 rounded-xl p-4">
          <div className="text-xs text-slate-500 mb-2">Position Value</div>
          <div className="text-2xl font-bold font-mono text-emerald-400">${positionValue.toFixed(2)}</div>
          <div className="text-xs mt-1">
            {pnl !== null && parseFloat(pnl) > 0
              ? <span className="text-emerald-500">+{pnl}% yield earned</span>
              : <span className="text-slate-600">at current share price</span>
            }
          </div>
        </div>
      </div>

      {/* Share price detail */}
      <div className="mt-4 flex items-center gap-4 px-1">
        <div className="text-xs text-slate-600">
          Share price: <span className={`font-mono ml-1 ${sharePrice > 1 ? 'text-emerald-400' : 'text-white'}`}>
            {sharePrice.toFixed(6)} USDC
          </span>
        </div>
        {sharePrice > 1 && (
          <div className="text-xs text-emerald-500 bg-emerald-500/10 px-2 py-0.5 rounded-full">
            +{((sharePrice - 1) * 100).toFixed(4)}% above par
          </div>
        )}
      </div>
    </div>
  );
}

// ── Deposit / Withdraw form ───────────────────────────────────────────────────

function DepositWithdrawCard({ data, isConnected, onDeposit, onWithdraw }) {
  const [tab, setTab]         = useState('deposit');
  const [amount, setAmount]   = useState('');
  const [loading, setLoading] = useState(false);

  const userUSDC   = data?.user?.usdcBalance ?? 0;
  const userShares = data?.user?.shares ?? 0;
  const sharePrice = data?.vault?.sharePrice ?? 1;
  const isPaused   = data?.vault?.depositsPaused;
  const parsed     = parseFloat(amount) || 0;

  const previewShares = tab === 'deposit' && parsed ? (parsed / sharePrice).toFixed(6) : null;
  const previewUsdc   = tab === 'withdraw' && parsed ? (parsed * sharePrice).toFixed(4) : null;

  const handleMax = () => {
    if (tab === 'deposit') setAmount(Math.floor(userUSDC * 100) / 100 + '');
    else setAmount(userShares > 0 ? userShares.toFixed(6) : '0');
  };

  const handleSubmit = async () => {
    if (!parsed || parsed <= 0) return;
    setLoading(true);
    try {
      if (tab === 'deposit') await onDeposit(amount);
      else await onWithdraw(amount);
      setAmount('');
    } finally {
      setLoading(false);
    }
  };

  const notEnoughBalance = tab === 'deposit' && parsed > userUSDC;
  const notEnoughShares  = tab === 'withdraw' && parsed > userShares;
  const depositBlocked   = tab === 'deposit' && isPaused;
  const submitDisabled   = !isConnected || loading || !parsed || notEnoughBalance || notEnoughShares || depositBlocked;

  return (
    <div className="glass-card rounded-2xl p-6">
      {/* Tab toggle */}
      <div className="flex gap-1 p-1.5 bg-slate-800/50 rounded-xl border border-slate-700/40 mb-6">
        {['deposit', 'withdraw'].map(t => (
          <button
            key={t}
            onClick={() => { setTab(t); setAmount(''); }}
            className={`flex-1 py-2.5 rounded-lg text-sm font-semibold transition-all capitalize
              ${tab === t ? 'bg-slate-700 text-white shadow-sm' : 'text-slate-500 hover:text-slate-300'}`}
          >
            {t === 'deposit' ? 'Deposit USDC' : 'Withdraw USDC'}
          </button>
        ))}
      </div>

      {/* Input */}
      <div className="mb-2">
        <label className="block text-xs text-slate-500 mb-2 font-medium uppercase tracking-wider">
          {tab === 'deposit' ? 'Amount to deposit' : 'Shares to redeem'}
        </label>
        <div className="relative">
          <input
            type="number"
            min="0"
            step="any"
            placeholder="0.00"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            className="w-full bg-slate-800/60 border border-slate-700/60 rounded-xl pl-4 pr-24 py-3.5 text-lg font-mono text-white placeholder-slate-700 focus:outline-none focus:border-indigo-500/60 transition-colors"
          />
          <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
            <span className="text-sm text-slate-500 font-medium">{tab === 'deposit' ? 'USDC' : 'shares'}</span>
            <button
              onClick={handleMax}
              className="text-xs font-bold text-indigo-400 hover:text-indigo-300 bg-indigo-500/15 hover:bg-indigo-500/25 px-2 py-1 rounded-lg transition-colors"
            >
              MAX
            </button>
          </div>
        </div>
      </div>

      {/* Balance row */}
      <div className="flex justify-between text-xs text-slate-600 mb-6 px-1">
        <span>
          {tab === 'deposit'
            ? `Wallet balance: ${userUSDC.toFixed(2)} USDC`
            : `Vault shares: ${userShares.toFixed(6)}`}
        </span>
        {depositBlocked && <span className="text-red-400 font-medium">Deposits paused by AI</span>}
      </div>

      {/* Preview */}
      {parsed > 0 && (
        <div className="bg-slate-800/40 border border-slate-700/30 rounded-xl p-4 mb-6 space-y-2.5">
          <div className="flex justify-between">
            <span className="text-sm text-slate-500">You will receive</span>
            <span className="text-sm font-mono font-semibold text-white">
              {tab === 'deposit' ? `~${previewShares} shares` : `~${previewUsdc} USDC`}
            </span>
          </div>
          <div className="flex justify-between">
            <span className="text-sm text-slate-600">Exchange rate</span>
            <span className="text-sm font-mono text-slate-400">1 share = {sharePrice.toFixed(6)} USDC</span>
          </div>
          {notEnoughBalance && (
            <div className="text-xs text-red-400 flex items-center gap-1.5 pt-1 border-t border-slate-700/30">
              <span>⚠</span> Insufficient USDC balance
            </div>
          )}
          {notEnoughShares && (
            <div className="text-xs text-red-400 flex items-center gap-1.5 pt-1 border-t border-slate-700/30">
              <span>⚠</span> Insufficient shares
            </div>
          )}
        </div>
      )}

      {/* Submit button */}
      <button
        onClick={handleSubmit}
        disabled={submitDisabled}
        className={`w-full py-3.5 rounded-xl text-base font-semibold transition-all duration-150
          disabled:opacity-40 disabled:cursor-not-allowed
          ${tab === 'deposit'
            ? 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-lg shadow-indigo-500/20 hover:shadow-indigo-500/30'
            : 'bg-slate-700 hover:bg-slate-600 text-white'
          }`}
      >
        {loading ? (
          <span className="flex items-center justify-center gap-2">
            <svg className="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
            </svg>
            Processing…
          </span>
        ) : tab === 'deposit'
          ? (depositBlocked ? 'Deposits Currently Paused' : 'Approve & Deposit')
          : 'Redeem Shares'
        }
      </button>

      {!isConnected && (
        <p className="text-xs text-center text-slate-600 mt-3">Connect wallet to transact</p>
      )}

      {/* Info note */}
      <div className="mt-5 pt-4 border-t border-slate-800/60 text-xs text-slate-600 space-y-1 leading-relaxed">
        <p>• Shares are ERC-20 tokens representing proportional vault ownership.</p>
        <p>• Share price increases as markets earn yield — your USDC value grows.</p>
        <p>• Deposit is a two-step transaction: USDC approval then the deposit call.</p>
      </div>
    </div>
  );
}

// ── Position page ─────────────────────────────────────────────────────────────

export default function PositionPage({ data, isLoading, isConnected, onDeposit, onWithdraw }) {
  if (!isConnected) {
    return (
      <div className="flex flex-col items-center justify-center py-24 text-center">
        <div className="w-16 h-16 rounded-2xl bg-indigo-500/10 border border-indigo-500/20 flex items-center justify-center mb-4">
          <svg className="w-7 h-7 text-indigo-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.5">
            <path d="M19 21v-2a4 4 0 0 0-4-4H9a4 4 0 0 0-4 4v2"/><circle cx="12" cy="7" r="4"/>
          </svg>
        </div>
        <div className="text-lg font-semibold text-white mb-2">Connect Your Wallet</div>
        <div className="text-sm text-slate-500 max-w-xs">Connect MetaMask to view your position and interact with the vault.</div>
      </div>
    );
  }

  return (
    <div className="max-w-2xl mx-auto space-y-5">
      <div>
        <h2 className="text-xl font-bold text-white mb-1">My Position</h2>
        <p className="text-sm text-slate-500">Manage your USDC deposits and track yield earned on the vault.</p>
      </div>

      {isLoading ? (
        <div className="space-y-4">
          <div className="h-32 glass-card rounded-2xl animate-pulse" />
          <div className="h-64 glass-card rounded-2xl animate-pulse" />
        </div>
      ) : (
        <>
          <PortfolioCard data={data} />
          <DepositWithdrawCard
            data={data}
            isConnected={isConnected}
            onDeposit={onDeposit}
            onWithdraw={onWithdraw}
          />
        </>
      )}
    </div>
  );
}
