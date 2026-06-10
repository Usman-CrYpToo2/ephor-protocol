import React, { useState } from 'react';
import { RISK_THEME, formatTime, REBALANCE_COOLDOWN, CHECK_COOLDOWN, CHECK_DEPOSIT, REBALANCE_DEPOSIT } from '../../config';

function Countdown({ lastAt, cooldown }) {
  const [now, setNow] = React.useState(Math.floor(Date.now() / 1000));
  React.useEffect(() => {
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, []);
  const remaining = Math.max(0, (lastAt + cooldown) - now);
  if (remaining === 0) return <span className="text-green-400 text-xs font-medium">Ready ✓</span>;
  return <span className="text-zinc-500 text-xs font-mono">{remaining}s cooldown</span>;
}

export default function RiskTab({ data, isLoading, isConnected, actions }) {
  const [checkBusy,  setCheckBusy]  = useState(false);
  const [rebalBusy, setRebalBusy]  = useState(false);
  const [showHow,   setShowHow]    = useState(false);

  if (isLoading || !data) {
    return <div className="space-y-4 animate-pulse">{[1,2,3].map(i => <div key={i} className="h-24 bg-white/[0.03] rounded" />)}</div>;
  }

  const { sentinel, strategist, markets } = data;
  const riskTheme = RISK_THEME[sentinel.latestLevel] || RISK_THEME[0];

  const handleCheck = async () => {
    setCheckBusy(true);
    await actions.onCheckVault();
    setCheckBusy(false);
  };

  const handleRebal = async () => {
    setRebalBusy(true);
    await actions.onRequestRebalance();
    setRebalBusy(false);
  };

  return (
    <div className="space-y-6">
      {/* Sentinel card */}
      <div className={`rounded-xl border p-5 ${riskTheme.border} ${riskTheme.bg}`}>
        <div className="flex items-start justify-between mb-3">
          <div className="flex items-center gap-2">
            <span className={`w-3 h-3 rounded-full ${riskTheme.dot}`} />
            <span className={`text-lg font-bold font-mono ${riskTheme.text}`}>{riskTheme.label}</span>
            {sentinel.isCheckPending && (
              <span className="text-xs text-blue-400 animate-pulse ml-2">● Check in progress…</span>
            )}
          </div>
          <span className="text-xs text-zinc-500">
            {sentinel.lastCheckedAt ? formatTime(sentinel.lastCheckedAt) : 'Never checked'}
          </span>
        </div>

        <div className="grid grid-cols-3 gap-4 text-xs">
          <div>
            <div className="text-zinc-500 mb-0.5">Hard floor</div>
            <div className="text-white font-mono">{RISK_THEME[sentinel.hardLevel]?.label ?? '—'}</div>
          </div>
          <div>
            <div className="text-zinc-500 mb-0.5">Total checks</div>
            <div className="text-white font-mono">{sentinel.totalChecks}</div>
          </div>
          <div>
            <div className="text-zinc-500 mb-0.5">Critical events</div>
            <div className={`font-mono ${sentinel.criticalCount > 0 ? 'text-red-400' : 'text-white'}`}>
              {sentinel.criticalCount}
            </div>
          </div>
        </div>

        {sentinel.latestVerdict && (
          <div className="mt-3 text-xs text-zinc-600 font-mono border-t border-white/[0.04] pt-3 break-all">
            {sentinel.latestVerdict}
          </div>
        )}
      </div>

      {/* Thresholds */}
      <div>
        <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">Verdict Thresholds</div>
        <div className="rounded-xl border border-white/[0.06] overflow-hidden">
          {[
            { level: 0, trigger: 'Util < 80% AND alloc < 25% on all markets' },
            { level: 1, trigger: 'Util 80–95% OR alloc 25–40% on any market' },
            { level: 2, trigger: 'Util > 95% AND alloc > 40% on any market → auto-pause + emergency deallocate' },
          ].map(({ level, trigger }) => {
            const t = RISK_THEME[level];
            return (
              <div key={level} className="flex items-center gap-4 px-4 py-3 border-b border-white/[0.04] last:border-0">
                <span className={`w-2 h-2 rounded-full flex-shrink-0 ${t.dot}`} />
                <span className={`text-xs font-mono font-semibold w-16 flex-shrink-0 ${t.text}`}>{t.label}</span>
                <span className="text-xs text-zinc-500">{trigger}</span>
              </div>
            );
          })}
        </div>
      </div>

      {/* How it works — expandable */}
      <div className="rounded-xl border border-white/[0.06] overflow-hidden">
        <button
          onClick={() => setShowHow(h => !h)}
          className="w-full flex items-center justify-between px-4 py-3 text-sm text-zinc-400 hover:text-white transition-colors"
        >
          <span>▶ How does AI Risk work?</span>
          <span className="text-zinc-600">{showHow ? '▲' : '▼'}</span>
        </button>
        {showHow && (
          <div className="px-4 pb-4 text-xs text-zinc-500 space-y-2 border-t border-white/[0.04] pt-3">
            <p>1. Anyone calls <span className="font-mono text-zinc-300">checkVault()</span> with 0.25 STT attached.</p>
            <p>2. Sentinel reads 5 on-chain metrics: totalAssets, idleBufferPct, allocationPct, marketCount, utilizationBps per market.</p>
            <p>3. Metrics are encoded into a plain-English prompt and sent to Somnia's Qwen3-30B LLM via native inference.</p>
            <p>4. Validators run LLM deterministically (fixed seed, temp=0) and reach consensus on SAFE/CAUTION/CRITICAL.</p>
            <p>5. Platform calls back <span className="font-mono text-zinc-300">handleResponse()</span> with the verdict.</p>
            <p>6. CRITICAL → pauseDeposits() + emergencyDeallocate(50%) on highest-util market.</p>
          </div>
        )}
      </div>

      {/* AI Allocator */}
      <div>
        <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">AI Allocator</div>
        <div className="rounded-xl border border-white/[0.06] p-4 space-y-4">
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
            <div>
              <div className="text-zinc-500 mb-1">Last strategy</div>
              <div className="text-white font-mono font-semibold">{strategist.lastLabel ?? '—'}</div>
            </div>
            <div>
              <div className="text-zinc-500 mb-1">Rebalances</div>
              <div className="text-white font-mono font-semibold">{strategist.rebalanceCount ?? 0}</div>
            </div>
            <div>
              <div className="text-zinc-500 mb-1">Epoch</div>
              <div className="text-white font-mono font-semibold">{data?.vault?.currentEpoch ?? 0}</div>
            </div>
            <div>
              <div className="text-zinc-500 mb-1">Cooldown</div>
              <Countdown lastAt={strategist.lastRequestAt} cooldown={REBALANCE_COOLDOWN} />
            </div>
          </div>

          <div className="grid grid-cols-2 gap-3 pt-2 border-t border-white/[0.06]">
            <button
              onClick={handleCheck}
              disabled={!isConnected || checkBusy || sentinel.isCheckPending}
              className="py-2.5 px-3 rounded-xl border border-white/[0.08] text-sm font-medium text-zinc-300 hover:bg-white/[0.04] disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
            >
              {checkBusy || sentinel.isCheckPending ? (
                <span className="flex items-center justify-center gap-2">
                  <svg className="w-3 h-3 animate-spin" fill="none" viewBox="0 0 24 24">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
                  </svg>
                  Checking…
                </span>
              ) : `Run Risk Check — ${CHECK_DEPOSIT} STT`}
            </button>

            <button
              onClick={handleRebal}
              disabled={!isConnected || rebalBusy || strategist.isPending}
              className="py-2.5 px-3 rounded-xl bg-blue-600/20 border border-blue-500/30 text-sm font-medium text-blue-300 hover:bg-blue-600/30 disabled:opacity-40 disabled:cursor-not-allowed transition-colors"
            >
              {rebalBusy || strategist.isPending ? (
                <span className="flex items-center justify-center gap-2">
                  <svg className="w-3 h-3 animate-spin" fill="none" viewBox="0 0 24 24">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
                  </svg>
                  Rebalancing…
                </span>
              ) : `AI Rebalance — ${REBALANCE_DEPOSIT} STT`}
            </button>
          </div>

          {!isConnected && (
            <div className="text-xs text-zinc-600 text-center">Connect wallet to trigger AI actions</div>
          )}
          <div className="grid grid-cols-2 gap-3 text-center">
            <Countdown lastAt={sentinel.lastCheckedAt} cooldown={CHECK_COOLDOWN} />
            <Countdown lastAt={strategist.lastRequestAt} cooldown={REBALANCE_COOLDOWN} />
          </div>
        </div>
      </div>
    </div>
  );
}
