import React from 'react';
import { RISK_THEME, formatUSDC, formatBps, formatTime } from '../config';

function StatCard({ label, children, className = '' }) {
  return (
    <div className={`glass-card rounded-2xl px-5 py-4 flex flex-col gap-1 ${className}`}>
      <span className="text-xs text-slate-500 font-medium uppercase tracking-wider">{label}</span>
      {children}
    </div>
  );
}

export default function StatsBar({ data, isLoading }) {
  const riskLevel  = data?.sentinel?.latestLevel ?? 0;
  const riskTheme  = RISK_THEME[riskLevel] ?? RISK_THEME[0];
  const isPaused   = data?.vault?.depositsPaused;
  const isPending  = data?.sentinel?.isCheckPending;

  return (
    <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">

      {/* Total Assets */}
      <StatCard label="Total Vault Assets">
        {isLoading ? (
          <div className="h-7 w-32 bg-slate-800 rounded animate-pulse" />
        ) : (
          <>
            <div className="text-2xl font-bold text-white font-mono">
              ${formatUSDC(data?.vault?.totalAssets)}
            </div>
            <div className="text-xs text-slate-500">
              USDC · Share price {data?.vault?.sharePrice?.toFixed(4) ?? '—'}
            </div>
          </>
        )}
      </StatCard>

      {/* Vault Status */}
      <StatCard label="Vault Status">
        {isLoading ? (
          <div className="h-7 w-24 bg-slate-800 rounded animate-pulse" />
        ) : (
          <>
            <div className={`flex items-center gap-2 text-xl font-bold font-mono
              ${isPaused ? 'text-red-400' : 'text-emerald-400'}`}>
              <span className={`inline-block w-2.5 h-2.5 rounded-full ${isPaused ? 'bg-red-400 animate-pulse' : 'bg-emerald-400'}`} />
              {isPaused ? 'PAUSED' : 'ACTIVE'}
            </div>
            <div className="text-xs text-slate-500">
              {isPaused ? 'New deposits halted by AI' : 'Accepting deposits'}
            </div>
          </>
        )}
      </StatCard>

      {/* AI Risk Level */}
      <StatCard label="AI Risk Assessment">
        {isLoading ? (
          <div className="h-7 w-28 bg-slate-800 rounded animate-pulse" />
        ) : isPending ? (
          <>
            <div className="flex items-center gap-2 text-xl font-bold text-blue-400 font-mono">
              <span className="inline-block w-2.5 h-2.5 rounded-full bg-blue-400 animate-pulse" />
              CHECKING…
            </div>
            <div className="text-xs text-slate-500">AI validators running</div>
          </>
        ) : (
          <>
            <div className={`flex items-center gap-2 text-xl font-bold font-mono ${riskTheme.text}`}>
              <span className={`inline-block w-2.5 h-2.5 rounded-full ${riskTheme.dot}`} />
              {riskTheme.label}
            </div>
            <div className="text-xs text-slate-500">
              Last check {formatTime(data?.sentinel?.lastCheckedAt)}
            </div>
          </>
        )}
      </StatCard>
    </div>
  );
}
