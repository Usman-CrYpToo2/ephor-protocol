import React from 'react';
import StatsBar from '../components/StatsBar';
import { RISK_THEME, ALLOCATION_MODES, formatUSDC, formatBps, formatTime } from '../config';

// ── Vault overview ────────────────────────────────────────────────────────────

function VaultOverviewCard({ data, isLoading }) {
  const vault  = data?.vault;
  const totalA = vault?.totalAssets ?? 0;
  const idle   = vault?.idleAmt ?? 0;
  const deployed = vault?.deployed ?? 0;

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
          <div className="mb-5">
            <div className="text-xs text-slate-500 mb-1">Total Assets</div>
            <div className="text-3xl font-bold font-mono text-white">${formatUSDC(totalA)}</div>
            <div className="text-sm text-slate-500 mt-0.5">USDC</div>
          </div>

          <div className="space-y-3 mb-5">
            {[
              { label: 'Idle Cash', value: idle,     pct: (totalA >= 1 && vault?.idleBufferBps) ? vault.idleBufferBps / 100 : 0, color: 'bg-slate-500' },
              { label: 'Deployed',  value: deployed, pct: totalA > 0 ? (deployed / totalA * 100) : 0,          color: 'bg-indigo-500' },
            ].map(row => (
              <div key={row.label}>
                <div className="flex justify-between text-xs mb-1">
                  <span className="text-slate-500">{row.label}</span>
                  <span className="font-mono text-slate-300">
                    ${formatUSDC(row.value)} <span className="text-slate-600">({row.pct.toFixed(1)}%)</span>
                  </span>
                </div>
                <div className="h-1.5 bg-slate-800 rounded-full overflow-hidden">
                  <div className={`h-full rounded-full util-bar-fill ${row.color}`} style={{ width: `${row.pct}%` }} />
                </div>
              </div>
            ))}
          </div>

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
            <div className="bg-slate-800/40 rounded-xl p-3">
              <div className="text-[10px] text-slate-600 uppercase tracking-wide mb-1">Epoch</div>
              <div className="text-sm font-mono font-bold text-violet-400">{vault?.currentEpoch ?? 0}</div>
            </div>
            <div className="bg-slate-800/40 rounded-xl p-3">
              <div className="text-[10px] text-slate-600 uppercase tracking-wide mb-1">Last Rebalance</div>
              <div className="text-sm text-slate-300">{vault?.lastRebalanceTime ? formatTime(vault.lastRebalanceTime) : 'Never'}</div>
            </div>
          </div>
        </>
      )}
    </div>
  );
}

// ── Market card ───────────────────────────────────────────────────────────────

function MarketCard({ market, isLoading }) {
  if (isLoading) {
    return <div className="glass-card rounded-2xl p-5 h-full animate-pulse"><div className="h-full bg-slate-800/40 rounded-xl" /></div>;
  }

  const util     = market.utilizationBps;
  const allocBps = market.allocationBps;
  const rate     = market.supplyRateBps;
  const isCritU  = util >= 9500;
  const isCritA  = allocBps >= 4000;

  const utilColor  = isCritU ? 'bg-red-500' : util >= 8000 ? 'bg-amber-500' : 'bg-emerald-500';
  const utilText   = isCritU ? 'text-red-400' : util >= 8000 ? 'text-amber-400' : 'text-emerald-400';
  const allocColor = isCritA ? 'text-red-400' : allocBps >= 2500 ? 'text-amber-400' : 'text-indigo-400';
  const allocBar   = isCritA ? 'bg-red-500'   : allocBps >= 2500 ? 'bg-amber-500'   : 'bg-indigo-500';

  return (
    <div className={`glass-card rounded-2xl p-5 h-full ${(isCritU && isCritA) ? 'border-red-500/20' : ''}`}>
      <div className="flex items-center gap-2 mb-4">
        <div className="w-7 h-7 rounded-lg bg-blue-500/15 border border-blue-500/25 flex items-center justify-center">
          <svg className="w-3.5 h-3.5 text-blue-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <line x1="18" y1="20" x2="18" y2="10"/>
            <line x1="12" y1="20" x2="12" y2="4"/>
            <line x1="6"  y1="20" x2="6"  y2="14"/>
          </svg>
        </div>
        <span className="font-semibold text-white">{market.name}</span>
        {(isCritU && isCritA) && (
          <span className="ml-auto text-xs text-red-400 bg-red-500/10 px-2 py-0.5 rounded-full border border-red-500/20">Risk</span>
        )}
        {rate > 0 && !(isCritU && isCritA) && (
          <span className="ml-auto text-xs font-mono text-emerald-400">{formatBps(rate)} p.a.</span>
        )}
      </div>

      <div className="text-2xl font-bold font-mono text-white mb-1">${formatUSDC(market.balance)}</div>
      <div className="text-xs text-slate-500 mb-4">USDC deployed</div>

      <div className="space-y-3">
        <div>
          <div className="flex justify-between text-xs mb-1">
            <span className="text-slate-500">Utilization</span>
            <span className={`font-mono font-semibold ${utilText}`}>{formatBps(util)}</span>
          </div>
          <div className="h-1.5 bg-slate-800 rounded-full overflow-hidden">
            <div className={`h-full rounded-full util-bar-fill ${utilColor}`} style={{ width: `${Math.min(util / 100, 100)}%` }} />
          </div>
        </div>
        <div>
          <div className="flex justify-between text-xs mb-1">
            <span className="text-slate-500">Vault Allocation</span>
            <span className={`font-mono font-semibold ${allocColor}`}>{formatBps(allocBps)}</span>
          </div>
          <div className="h-1.5 bg-slate-800 rounded-full overflow-hidden">
            <div className={`h-full rounded-full util-bar-fill ${allocBar}`} style={{ width: `${Math.min(allocBps / 100, 100)}%` }} />
          </div>
        </div>
      </div>
    </div>
  );
}

// ── Sentinel summary ──────────────────────────────────────────────────────────

function SentinelCard({ data, isLoading, onNavigate }) {
  const s     = data?.sentinel;
  const level = s?.latestLevel ?? 0;
  const theme = RISK_THEME[level] ?? RISK_THEME[0];

  return (
    <div className="glass-card rounded-2xl p-5">
      <div className="flex items-center gap-2 mb-4">
        <div className="w-7 h-7 rounded-lg bg-violet-500/15 border border-violet-500/25 flex items-center justify-center">
          <svg className="w-3.5 h-3.5 text-violet-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" strokeLinecap="round" strokeLinejoin="round"/>
          </svg>
        </div>
        <span className="font-semibold text-white">AI Sentinel</span>
        <button onClick={() => onNavigate('sentinel')} className="ml-auto text-xs text-indigo-400 hover:text-indigo-300 transition-colors">
          Details →
        </button>
      </div>

      {isLoading ? (
        <div className="h-16 bg-slate-800/60 rounded-xl animate-pulse" />
      ) : s?.isCheckPending ? (
        <div className="rounded-xl border p-4 flex items-center gap-4 bg-blue-500/10 border-blue-500/25">
          <svg className="w-7 h-7 text-blue-400 animate-spin flex-shrink-0" fill="none" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
          </svg>
          <div>
            <div className="text-blue-400 font-bold text-sm">AI Check Running</div>
            <div className="text-xs text-slate-500 mt-0.5">Validators reaching consensus on Somnia…</div>
          </div>
        </div>
      ) : (
        <div className={`rounded-xl border p-4 flex items-center gap-4 ${theme.bg} ${theme.border}`}>
          <span className={`text-2xl font-bold flex-shrink-0 ${theme.text}`}>
            {level === 0 ? '✓' : level === 1 ? '!' : '⚠'}
          </span>
          <div>
            <div className={`text-lg font-bold font-mono ${theme.text}`}>{theme.label}</div>
            <div className="text-xs text-slate-500 mt-0.5">
              {formatTime(s?.latestVerdictTs)} · {s?.totalChecks ?? 0} checks · {s?.criticalCount ?? 0} critical
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Strategist summary ────────────────────────────────────────────────────────

function AllocatorCard({ data, isLoading, onNavigate }) {
  const s = data?.strategist;
  const v = data?.vault;
  const mode = ALLOCATION_MODES[s?.allocationMode ?? 0];

  return (
    <div className="glass-card rounded-2xl p-5">
      <div className="flex items-center gap-2 mb-4">
        <div className="w-7 h-7 rounded-lg bg-indigo-500/15 border border-indigo-500/25 flex items-center justify-center">
          <svg className="w-3.5 h-3.5 text-indigo-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>
            <polyline points="3.27 6.96 12 12.01 20.73 6.96"/>
            <line x1="12" y1="22.08" x2="12" y2="12"/>
          </svg>
        </div>
        <span className="font-semibold text-white">AI Allocator</span>
        <button onClick={() => onNavigate('allocator')} className="ml-auto text-xs text-indigo-400 hover:text-indigo-300 transition-colors">
          Details →
        </button>
      </div>

      {isLoading ? (
        <div className="h-16 bg-slate-800/60 rounded-xl animate-pulse" />
      ) : s?.isPending ? (
        <div className="rounded-xl border p-4 flex items-center gap-4 bg-violet-500/10 border-violet-500/25">
          <svg className="w-7 h-7 text-violet-400 animate-spin flex-shrink-0" fill="none" viewBox="0 0 24 24">
            <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
            <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
          </svg>
          <div>
            <div className="text-violet-400 font-bold text-sm">Rebalance Running</div>
            <div className="text-xs text-slate-500 mt-0.5">AI determining optimal allocation…</div>
          </div>
        </div>
      ) : (
        <div className="grid grid-cols-3 gap-2">
          <div className="bg-slate-800/40 rounded-xl p-3 col-span-1">
            <div className="text-[10px] text-slate-600 uppercase tracking-wide mb-1">Epoch</div>
            <div className="text-lg font-bold font-mono text-violet-400">{v?.currentEpoch ?? 0}</div>
          </div>
          <div className="bg-slate-800/40 rounded-xl p-3 col-span-2">
            <div className="text-[10px] text-slate-600 uppercase tracking-wide mb-1">Mode</div>
            <div className="text-sm font-bold text-white">{mode?.label}</div>
            <div className="text-[10px] text-slate-500">{mode?.sub}</div>
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

      {/* Markets + Vault grid */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-5">
        <VaultOverviewCard data={data} isLoading={isLoading} />
        {isLoading
          ? [0,1].map(i => <MarketCard key={i} isLoading />)
          : markets.map(m => <MarketCard key={m.address} market={m} isLoading={false} />)
        }
      </div>

      {/* AI modules row */}
      <div className="grid grid-cols-1 sm:grid-cols-2 gap-5">
        <SentinelCard  data={data} isLoading={isLoading} onNavigate={onNavigate} />
        <AllocatorCard data={data} isLoading={isLoading} onNavigate={onNavigate} />
      </div>
    </div>
  );
}
