import React from 'react';
import StatsBar from '../components/StatsBar';
import { RISK_THEME, formatUSDC, formatTime } from '../config';

// ── Compact vault overview card ───────────────────────────────────────────────

function VaultOverviewCard({ data, isLoading }) {
  const vault  = data?.vault;
  const totalA = vault?.totalAssets ?? 0;
  const idle   = vault ? Math.round(vault.idleBufferPct * totalA / 100) : 0;
  const deployed = totalA - idle;

  return (
    <div className="glass-card rounded-2xl p-5 h-full">
      <div className="flex items-center gap-2 mb-5">
        <div className="w-7 h-7 rounded-lg bg-indigo-500/15 border border-indigo-500/25 flex items-center justify-center">
          <svg className="w-3.5 h-3.5 text-indigo-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <rect x="3" y="3" width="18" height="18" rx="2"/>
            <path d="M3 9h18M9 21V9"/>
          </svg>
        </div>
        <span className="font-semibold text-white">Vault</span>
        <span className="ml-auto text-xs text-slate-600">ERC-4626</span>
      </div>

      {isLoading ? (
        <div className="space-y-3">{[1,2,3].map(i => <div key={i} className="h-8 bg-slate-800/60 rounded-lg animate-pulse" />)}</div>
      ) : (
        <>
          {/* Big number */}
          <div className="mb-5">
            <div className="text-xs text-slate-500 mb-1">Total Assets</div>
            <div className="text-3xl font-bold font-mono text-white">${formatUSDC(totalA)}</div>
            <div className="text-sm text-slate-500 mt-0.5">USDC</div>
          </div>

          {/* Split bars */}
          <div className="space-y-3 mb-5">
            {[
              { label: 'Idle Cash', value: idle, pct: vault?.idleBufferPct ?? 0, color: 'bg-slate-400' },
              { label: 'Deployed', value: deployed, pct: 100 - (vault?.idleBufferPct ?? 0), color: 'bg-indigo-500' },
            ].map(row => (
              <div key={row.label}>
                <div className="flex justify-between text-xs mb-1">
                  <span className="text-slate-500">{row.label}</span>
                  <span className="font-mono text-slate-300">${formatUSDC(row.value)} <span className="text-slate-600">({row.pct}%)</span></span>
                </div>
                <div className="h-1.5 bg-slate-800 rounded-full overflow-hidden">
                  <div className={`h-full rounded-full util-bar-fill ${row.color}`} style={{ width: `${row.pct}%` }} />
                </div>
              </div>
            ))}
          </div>

          {/* Stats grid */}
          <div className="grid grid-cols-2 gap-2">
            <div className="bg-slate-800/40 rounded-xl p-3">
              <div className="text-[10px] text-slate-600 uppercase tracking-wide mb-1">Share Price</div>
              <div className={`text-sm font-mono font-bold ${(vault?.sharePrice ?? 1) > 1 ? 'text-emerald-400' : 'text-white'}`}>
                {vault?.sharePrice?.toFixed(6) ?? '1.000000'}
              </div>
            </div>
            <div className="bg-slate-800/40 rounded-xl p-3">
              <div className="text-[10px] text-slate-600 uppercase tracking-wide mb-1">Deposits</div>
              <div className={`text-sm font-bold ${vault?.depositsPaused ? 'text-red-400' : 'text-emerald-400'}`}>
                {vault?.depositsPaused ? 'Paused' : 'Open'}
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

// ── Compact market card ───────────────────────────────────────────────────────

function MarketCard({ market, isLoading }) {
  if (isLoading) {
    return <div className="glass-card rounded-2xl p-5 h-full animate-pulse"><div className="h-full bg-slate-800/40 rounded-xl" /></div>;
  }

  const utilPct = (market.utilizationBps / 100).toFixed(1);
  const isCritU = market.utilizationBps >= 9500;
  const isCritA = market.allocationPct >= 40;
  const utilColor = isCritU ? 'bg-red-500' : market.utilizationBps >= 8000 ? 'bg-amber-500' : 'bg-emerald-500';
  const utilTextColor = isCritU ? 'text-red-400' : market.utilizationBps >= 8000 ? 'text-amber-400' : 'text-emerald-400';
  const allocColor = isCritA ? 'text-red-400' : market.allocationPct >= 25 ? 'text-amber-400' : 'text-indigo-400';

  return (
    <div className={`glass-card rounded-2xl p-5 h-full ${(isCritU || isCritA) ? 'border-red-500/20' : ''}`}>
      <div className="flex items-center gap-2 mb-5">
        <div className="w-7 h-7 rounded-lg bg-blue-500/15 border border-blue-500/25 flex items-center justify-center">
          <svg className="w-3.5 h-3.5 text-blue-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/><line x1="6" y1="20" x2="6" y2="14"/>
          </svg>
        </div>
        <span className="font-semibold text-white">{market.name}</span>
        {(isCritU || isCritA) && (
          <span className="ml-auto text-xs text-red-400 bg-red-500/10 px-2 py-0.5 rounded-full border border-red-500/20">Risk</span>
        )}
      </div>

      <div className="mb-5">
        <div className="text-xs text-slate-500 mb-1">Vault Balance</div>
        <div className="text-2xl font-bold font-mono text-white">${formatUSDC(market.balance)}</div>
        <div className="text-sm text-slate-500 mt-0.5">USDC</div>
      </div>

      <div className="space-y-3">
        <div>
          <div className="flex justify-between text-xs mb-1">
            <span className="text-slate-500">Utilization</span>
            <span className={`font-mono font-semibold ${utilTextColor}`}>{utilPct}%</span>
          </div>
          <div className="h-2 bg-slate-800 rounded-full overflow-hidden">
            <div className={`h-full rounded-full util-bar-fill ${utilColor}`} style={{ width: `${Math.min(parseFloat(utilPct), 100)}%` }} />
          </div>
        </div>
        <div>
          <div className="flex justify-between text-xs mb-1">
            <span className="text-slate-500">Allocation</span>
            <span className={`font-mono font-semibold ${allocColor}`}>{market.allocationPct}%</span>
          </div>
          <div className="h-2 bg-slate-800 rounded-full overflow-hidden">
            <div className={`h-full rounded-full util-bar-fill ${isCritA ? 'bg-red-500' : market.allocationPct >= 25 ? 'bg-amber-500' : 'bg-indigo-500'}`}
              style={{ width: `${Math.min(market.allocationPct, 100)}%` }} />
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Compact sentinel summary ──────────────────────────────────────────────────

function SentinelSummary({ data, isLoading, onNavigate }) {
  const s = data?.sentinel;
  const level = s?.latestLevel ?? 0;
  const theme = RISK_THEME[level] ?? RISK_THEME[0];

  return (
    <div className="glass-card rounded-2xl p-5">
      <div className="flex items-center gap-2 mb-5">
        <div className="w-7 h-7 rounded-lg bg-violet-500/15 border border-violet-500/25 flex items-center justify-center">
          <svg className="w-3.5 h-3.5 text-violet-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
        <span className="font-semibold text-white">AI Sentinel</span>
        <button
          onClick={() => onNavigate('sentinel')}
          className="ml-auto text-xs text-indigo-400 hover:text-indigo-300 transition-colors"
        >
          View details →
        </button>
      </div>

      {isLoading ? (
        <div className="space-y-3">{[1,2].map(i => <div key={i} className="h-12 bg-slate-800/60 rounded-xl animate-pulse" />)}</div>
      ) : s?.isCheckPending ? (
        <div className={`rounded-xl border p-4 flex items-center gap-4 bg-blue-500/10 border-blue-500/25`}>
          <svg className="w-8 h-8 text-blue-400 animate-spin flex-shrink-0" fill="none" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
          </svg>
          <div>
            <div className="text-blue-400 font-bold">AI Check Running</div>
            <div className="text-xs text-slate-500 mt-0.5">Validators reaching consensus on Somnia…</div>
          </div>
        </div>
      ) : (
        <div className={`rounded-xl border p-4 flex items-center gap-4 ${theme.bg} ${theme.border}`}>
          <span className={`text-3xl font-bold flex-shrink-0 ${theme.text}`}>
            {level === 0 ? '✓' : level === 1 ? '!' : '⚠'}
          </span>
          <div>
            <div className={`text-xl font-bold font-mono ${theme.text}`}>{theme.label}</div>
            <div className="text-xs text-slate-500 mt-0.5">
              {formatTime(s?.latestVerdictTs)} · {s?.totalChecks ?? 0} total checks · {s?.criticalCount ?? 0} critical
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Dashboard page ────────────────────────────────────────────────────────────

export default function DashboardPage({ data, isLoading, onNavigate }) {
  const markets = data?.markets ?? [];

  return (
    <div className="space-y-5">
      <StatsBar data={data} isLoading={isLoading} />

      {/* Main 3-column grid */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-5">
        <VaultOverviewCard data={data} isLoading={isLoading} />
        {isLoading
          ? [0, 1].map(i => <MarketCard key={i} isLoading />)
          : markets.map(m => <MarketCard key={m.address} market={m} isLoading={false} />)
        }
      </div>

      {/* Sentinel row */}
      <SentinelSummary data={data} isLoading={isLoading} onNavigate={onNavigate} />
    </div>
  );
}
