import React, { useState } from 'react';
import { CHECK_DEPOSIT } from '../config';

function ActionButton({ label, sub, onClick, variant = 'primary', disabled = false, loading = false }) {
  const base = 'w-full text-left px-4 py-3 rounded-xl border transition-all duration-150 disabled:opacity-50 disabled:cursor-not-allowed';

  const variants = {
    primary:   'bg-indigo-600 hover:bg-indigo-500 active:bg-indigo-700 border-indigo-500/50 text-white shadow-lg shadow-indigo-500/20 hover:shadow-indigo-500/30',
    danger:    'bg-red-900/30 hover:bg-red-900/50 active:bg-red-900/60 border-red-700/50 text-red-300 hover:text-red-200',
    warning:   'bg-amber-900/20 hover:bg-amber-900/40 border-amber-700/40 text-amber-300 hover:text-amber-200',
    ghost:     'bg-slate-800/50 hover:bg-slate-700/50 border-slate-700/50 text-slate-300 hover:text-white',
    success:   'bg-emerald-900/20 hover:bg-emerald-900/40 border-emerald-700/40 text-emerald-300 hover:text-emerald-200',
  };

  return (
    <button
      onClick={onClick}
      disabled={disabled || loading}
      className={`${base} ${variants[variant]}`}
    >
      <div className="flex items-center justify-between">
        <div>
          <div className="text-sm font-medium">{label}</div>
          {sub && <div className="text-xs opacity-60 mt-0.5">{sub}</div>}
        </div>
        {loading ? (
          <svg className="w-4 h-4 animate-spin opacity-70" fill="none" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
          </svg>
        ) : (
          <svg className="w-4 h-4 opacity-50" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <path strokeLinecap="round" strokeLinejoin="round" d="M9 5l7 7-7 7"/>
          </svg>
        )}
      </div>
    </button>
  );
}

export default function ActionsPanel({
  data, isConnected, isWrongNetwork,
  onCheckVault, onUnpause, onSetCritical, onSetSafe, onMintUsdc, onSimulateYield,
}) {
  const [loading, setLoading] = useState({});

  const run = async (key, fn) => {
    setLoading(l => ({ ...l, [key]: true }));
    try { await fn(); }
    finally { setLoading(l => ({ ...l, [key]: false })); }
  };

  const canAct    = isConnected && !isWrongNetwork;
  const isPending = data?.sentinel?.isCheckPending;
  const isPaused  = data?.vault?.depositsPaused;

  // Cooldown check
  const lastChecked = data?.sentinel?.lastCheckedAt ?? 0;
  const cooldownLeft = Math.max(0, 300 - (Math.floor(Date.now() / 1000) - lastChecked));
  const onCooldown = cooldownLeft > 0 && lastChecked > 0;

  const checkLabel = isPending
    ? 'Check in Progress…'
    : onCooldown
    ? `Cooldown: ${cooldownLeft}s`
    : `Trigger AI Risk Check`;

  const checkSub = isPending
    ? 'Validators running on Somnia'
    : onCooldown
    ? 'Minimum 5 minutes between checks'
    : `Sends ${CHECK_DEPOSIT} STT to Somnia LLM Agent`;

  return (
    <div className="glass-card rounded-2xl overflow-hidden">
      {/* Header */}
      <div className="px-5 py-4 border-b border-slate-800/60 flex items-center gap-2">
        <div className="w-7 h-7 rounded-lg bg-emerald-500/15 border border-emerald-500/25 flex items-center justify-center">
          <svg className="w-3.5 h-3.5 text-emerald-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <polyline points="13 2 3 14 12 14 11 22 21 10 12 10 13 2"/>
          </svg>
        </div>
        <span className="font-semibold text-white text-sm">Actions</span>
      </div>

      <div className="px-4 py-4 space-y-4">
        {/* Not connected warning */}
        {!isConnected && (
          <div className="text-xs text-slate-500 text-center py-2 bg-slate-800/30 rounded-lg border border-slate-700/40">
            Connect wallet to execute transactions
          </div>
        )}

        {/* Primary action */}
        <ActionButton
          label={checkLabel}
          sub={checkSub}
          variant="primary"
          disabled={!canAct || isPending || onCooldown}
          loading={loading.check}
          onClick={() => run('check', onCheckVault)}
        />

        {/* Unpause (only show when paused) */}
        {isPaused && (
          <ActionButton
            label="Unpause Deposits"
            sub="Admin only — resumes normal vault operations"
            variant="success"
            disabled={!canAct}
            loading={loading.unpause}
            onClick={() => run('unpause', onUnpause)}
          />
        )}

        {/* Divider */}
        <div className="relative">
          <div className="absolute inset-0 flex items-center">
            <div className="w-full border-t border-slate-800/60" />
          </div>
          <div className="relative flex justify-center">
            <span className="bg-[#0d1117] px-3 text-xs text-slate-600 uppercase tracking-wider">Demo Controls</span>
          </div>
        </div>

        {/* Demo helpers */}
        <div className="space-y-2">
          <ActionButton
            label="Set CRITICAL Scenario"
            sub="Market A → 60% alloc, 96% util — triggers CRITICAL verdict"
            variant="danger"
            disabled={!canAct}
            loading={loading.critical}
            onClick={() => run('critical', onSetCritical)}
          />

          <ActionButton
            label="Reset to SAFE Scenario"
            sub="Set Market A utilization to 30% — should yield SAFE verdict"
            variant="success"
            disabled={!canAct}
            loading={loading.safe}
            onClick={() => run('safe', onSetSafe)}
          />

          <ActionButton
            label="Simulate 30-day Yield"
            sub="Fast-forward 5% APY on both markets — watch share price increase"
            variant="ghost"
            disabled={!canAct}
            loading={loading.yield}
            onClick={() => run('yield', onSimulateYield)}
          />

          <ActionButton
            label="Mint 10,000 USDC"
            sub="Mint test tokens to your wallet"
            variant="ghost"
            disabled={!canAct}
            loading={loading.mint}
            onClick={() => run('mint', onMintUsdc)}
          />
        </div>

        {/* Info note */}
        <div className="text-xs text-slate-600 leading-relaxed border-t border-slate-800/40 pt-3">
          AI checks use Somnia's on-chain LLM Inference Agent. Validators run
          deterministically (fixed seed, temp=0) and reach consensus before
          calling back <code className="font-mono text-slate-500">handleResponse()</code>.
        </div>
      </div>
    </div>
  );
}
