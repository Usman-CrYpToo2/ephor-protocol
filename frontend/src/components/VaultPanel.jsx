import React, { useState } from 'react';
import { formatUSDC } from '../config';

// ── Sub-components ────────────────────────────────────────────────────────────

function Row({ label, value, valueClass = 'text-white' }) {
  return (
    <div className="flex items-center justify-between py-2.5 border-b border-slate-800/60 last:border-0">
      <span className="text-sm text-slate-400">{label}</span>
      <span className={`text-sm font-medium font-mono ${valueClass}`}>{value}</span>
    </div>
  );
}

function ProgressBar({ pct, label }) {
  const color = pct >= 90 ? 'bg-red-500' : pct >= 70 ? 'bg-amber-500' : 'bg-indigo-500';
  return (
    <div className="space-y-1">
      <div className="flex justify-between text-xs text-slate-400">
        <span>{label}</span>
        <span className="font-mono text-white">{pct}%</span>
      </div>
      <div className="h-1.5 bg-slate-800 rounded-full overflow-hidden">
        <div className={`h-full rounded-full util-bar-fill ${color}`} style={{ width: `${Math.min(pct, 100)}%` }} />
      </div>
    </div>
  );
}

// ── Deposit / Withdraw form ───────────────────────────────────────────────────

function DepositWithdraw({ data, isConnected, onDeposit, onWithdraw }) {
  const [tab, setTab]       = useState('deposit');
  const [amount, setAmount] = useState('');
  const [loading, setLoading] = useState(false);

  const userUSDC   = data?.user?.usdcBalance ?? 0;
  const userShares = data?.user?.shares ?? 0;
  const sharePrice = data?.vault?.sharePrice ?? 1;
  const isPaused   = data?.vault?.depositsPaused;

  const parsedAmount = parseFloat(amount) || 0;
  const previewShares = tab === 'deposit' && parsedAmount ? (parsedAmount / sharePrice).toFixed(6) : null;
  const previewUsdc   = tab === 'withdraw' && parsedAmount ? (parsedAmount * sharePrice).toFixed(2) : null;

  const handleMax = () => {
    if (tab === 'deposit') setAmount(Math.floor(userUSDC * 100) / 100 + '');
    else setAmount(userShares > 0 ? userShares.toFixed(6) : '0');
  };

  const handleSubmit = async () => {
    if (!parsedAmount || parsedAmount <= 0) return;
    setLoading(true);
    try {
      if (tab === 'deposit') await onDeposit(amount);
      else await onWithdraw(amount);
      setAmount('');
    } finally {
      setLoading(false);
    }
  };

  const depositDisabled = !isConnected || loading || !parsedAmount || isPaused;
  const withdrawDisabled = !isConnected || loading || !parsedAmount || parsedAmount > userShares;

  return (
    <div className="border-t border-slate-800/60 pt-4 mt-1">
      <div className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-3">
        Vault Position
      </div>

      {/* Tab switcher */}
      <div className="flex gap-1 mb-4 p-1 bg-slate-800/40 rounded-xl border border-slate-700/30">
        {['deposit', 'withdraw'].map(t => (
          <button
            key={t}
            onClick={() => { setTab(t); setAmount(''); }}
            className={`flex-1 py-1.5 rounded-lg text-xs font-semibold transition-all capitalize
              ${tab === t
                ? 'bg-slate-700 text-white shadow-sm'
                : 'text-slate-500 hover:text-slate-300'}`}
          >
            {t}
          </button>
        ))}
      </div>

      {/* Input row */}
      <div className="relative mb-2">
        <input
          type="number"
          min="0"
          step="any"
          placeholder={tab === 'deposit' ? 'Amount in USDC' : 'Amount in shares'}
          value={amount}
          onChange={e => setAmount(e.target.value)}
          className="w-full bg-slate-800/60 border border-slate-700/60 rounded-xl pl-3 pr-16 py-2.5 text-sm text-white placeholder-slate-600 focus:outline-none focus:border-indigo-500/60 font-mono"
        />
        <div className="absolute right-3 top-1/2 -translate-y-1/2 flex items-center gap-2">
          <span className="text-xs text-slate-500">{tab === 'deposit' ? 'USDC' : 'shares'}</span>
          <button
            onClick={handleMax}
            className="text-xs text-indigo-400 hover:text-indigo-300 font-bold bg-indigo-500/10 px-1.5 py-0.5 rounded"
          >
            MAX
          </button>
        </div>
      </div>

      {/* Available balance */}
      <div className="flex justify-between text-xs text-slate-600 mb-3 px-1">
        <span>{tab === 'deposit' ? `Available: ${userUSDC.toFixed(2)} USDC` : `Shares held: ${userShares.toFixed(6)}`}</span>
        {tab === 'deposit' && isPaused && (
          <span className="text-red-400 font-medium">Deposits paused</span>
        )}
      </div>

      {/* Preview box */}
      {parsedAmount > 0 && (
        <div className="bg-slate-800/40 border border-slate-700/30 rounded-xl px-3 py-2.5 mb-3 space-y-1.5">
          <div className="flex justify-between text-xs">
            <span className="text-slate-500">You will receive</span>
            <span className="text-white font-mono font-semibold">
              {tab === 'deposit' ? `~${previewShares} shares` : `~$${previewUsdc} USDC`}
            </span>
          </div>
          <div className="flex justify-between text-xs">
            <span className="text-slate-600">Current share price</span>
            <span className="text-slate-400 font-mono">{sharePrice.toFixed(6)} USDC</span>
          </div>
          {tab === 'deposit' && parsedAmount > userUSDC && (
            <div className="text-xs text-red-400 mt-1">Insufficient USDC balance</div>
          )}
        </div>
      )}

      {/* Submit */}
      <button
        onClick={handleSubmit}
        disabled={tab === 'deposit' ? depositDisabled : withdrawDisabled}
        className={`w-full py-2.5 rounded-xl text-sm font-semibold transition-all duration-150
          disabled:opacity-40 disabled:cursor-not-allowed
          ${tab === 'deposit'
            ? 'bg-indigo-600 hover:bg-indigo-500 text-white shadow-lg shadow-indigo-500/20'
            : 'bg-slate-700 hover:bg-slate-600 text-white'
          }`}
      >
        {loading
          ? <span className="flex items-center justify-center gap-2">
              <svg className="w-3.5 h-3.5 animate-spin" fill="none" viewBox="0 0 24 24">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
              </svg>
              Processing…
            </span>
          : tab === 'deposit'
            ? isPaused ? 'Deposits Paused' : 'Approve & Deposit'
            : 'Withdraw USDC'
        }
      </button>

      {!isConnected && (
        <p className="text-xs text-center text-slate-600 mt-2">Connect wallet to transact</p>
      )}
    </div>
  );
}

// ── Main panel ────────────────────────────────────────────────────────────────

export default function VaultPanel({ data, isLoading, isConnected, onDeposit, onWithdraw }) {
  const vault    = data?.vault;
  const user     = data?.user;
  const totalA   = vault?.totalAssets ?? 0;
  const idle     = vault ? Math.round(vault.idleBufferPct * totalA / 100) : 0;
  const deployed = totalA - idle;

  return (
    <div className="glass-card rounded-2xl overflow-hidden">
      {/* Header */}
      <div className="px-5 py-4 border-b border-slate-800/60 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 rounded-lg bg-indigo-500/15 border border-indigo-500/25 flex items-center justify-center">
            <svg className="w-3.5 h-3.5 text-indigo-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
              <rect x="3" y="3" width="18" height="18" rx="2"/>
              <path d="M3 9h18M9 21V9"/>
            </svg>
          </div>
          <span className="font-semibold text-white text-sm">Vault</span>
        </div>
        <span className="text-xs text-slate-500">ERC-4626</span>
      </div>

      <div className="px-5 py-4 space-y-4">
        {isLoading ? (
          <div className="space-y-3">
            {[1,2,3,4,5].map(i => <div key={i} className="h-9 bg-slate-800/60 rounded animate-pulse" />)}
          </div>
        ) : (
          <>
            {/* Asset split */}
            <div className="grid grid-cols-3 gap-2">
              <div className="bg-slate-800/50 rounded-xl p-3 text-center">
                <div className="text-[10px] text-slate-500 mb-1 uppercase tracking-wide">Total</div>
                <div className="text-sm font-bold font-mono text-white">${formatUSDC(totalA)}</div>
              </div>
              <div className="bg-indigo-500/8 border border-indigo-500/15 rounded-xl p-3 text-center">
                <div className="text-[10px] text-slate-500 mb-1 uppercase tracking-wide">Deployed</div>
                <div className="text-sm font-bold font-mono text-indigo-400">${formatUSDC(deployed)}</div>
              </div>
              <div className="bg-slate-800/50 rounded-xl p-3 text-center">
                <div className="text-[10px] text-slate-500 mb-1 uppercase tracking-wide">Idle</div>
                <div className="text-sm font-bold font-mono text-slate-300">${formatUSDC(idle)}</div>
              </div>
            </div>

            {/* Bars */}
            <div className="space-y-3">
              <ProgressBar label="Idle Buffer" pct={vault?.idleBufferPct ?? 0} />
              <ProgressBar label="Deployed" pct={100 - (vault?.idleBufferPct ?? 0)} />
            </div>

            {/* Stats */}
            <div>
              <Row
                label="Share Price"
                value={`${vault?.sharePrice?.toFixed(6) ?? '—'} USDC`}
                valueClass={vault?.sharePrice > 1 ? 'text-emerald-400' : 'text-white'}
              />
              <Row
                label="Total Shares"
                value={vault ? Number(vault.totalSupply).toLocaleString(undefined, { maximumFractionDigits: 2 }) : '—'}
              />
              <Row
                label="Deposits"
                value={vault?.depositsPaused ? 'PAUSED' : 'OPEN'}
                valueClass={vault?.depositsPaused ? 'text-red-400' : 'text-emerald-400'}
              />
            </div>

            {/* User portfolio */}
            {user?.address && (
              <div className="bg-slate-800/30 border border-slate-700/30 rounded-xl p-3 space-y-1">
                <div className="text-xs text-slate-500 font-medium uppercase tracking-wider mb-2">Your Portfolio</div>
                <div className="grid grid-cols-3 gap-2">
                  <div className="text-center">
                    <div className="text-[10px] text-slate-600 mb-0.5">USDC</div>
                    <div className="text-xs font-mono font-semibold text-white">${formatUSDC(user.usdcBalance)}</div>
                  </div>
                  <div className="text-center">
                    <div className="text-[10px] text-slate-600 mb-0.5">Shares</div>
                    <div className="text-xs font-mono font-semibold text-indigo-300">
                      {user.shares > 0 ? user.shares.toFixed(4) : '0'}
                    </div>
                  </div>
                  <div className="text-center">
                    <div className="text-[10px] text-slate-600 mb-0.5">STT</div>
                    <div className="text-xs font-mono font-semibold text-slate-300">{user.sttBalance?.toFixed(3) ?? '0'}</div>
                  </div>
                </div>
                {user.shares > 0 && vault?.sharePrice && (
                  <div className="text-center pt-1 border-t border-slate-700/30 mt-2">
                    <span className="text-xs text-slate-500">Position value: </span>
                    <span className="text-xs font-mono text-emerald-400">
                      ${(user.shares * vault.sharePrice).toFixed(2)} USDC
                    </span>
                  </div>
                )}
              </div>
            )}

            {/* Deposit / Withdraw form */}
            <DepositWithdraw
              data={data}
              isConnected={isConnected}
              onDeposit={onDeposit}
              onWithdraw={onWithdraw}
            />
          </>
        )}
      </div>
    </div>
  );
}
