import React from 'react';
import { formatUSDC } from '../config';

function UtilBar({ bps }) {
  const pct   = bps / 100;
  const color = pct >= 95 ? 'bg-red-500'
              : pct >= 80 ? 'bg-amber-500'
              : pct >= 60 ? 'bg-yellow-500'
              : 'bg-emerald-500';
  const textColor = pct >= 95 ? 'text-red-400'
                  : pct >= 80 ? 'text-amber-400'
                  : 'text-emerald-400';

  return (
    <div className="space-y-1.5">
      <div className="flex justify-between text-xs">
        <span className="text-slate-500">Utilization</span>
        <span className={`font-mono font-semibold ${textColor}`}>{pct.toFixed(1)}%</span>
      </div>
      <div className="h-2 bg-slate-800 rounded-full overflow-hidden">
        <div
          className={`h-full rounded-full util-bar-fill ${color}`}
          style={{ width: `${Math.min(pct, 100)}%` }}
        />
      </div>
    </div>
  );
}

function AllocBar({ pct }) {
  const color = pct >= 40 ? 'bg-red-500'
              : pct >= 25 ? 'bg-amber-500'
              : 'bg-indigo-500';
  const textColor = pct >= 40 ? 'text-red-400'
                  : pct >= 25 ? 'text-amber-400'
                  : 'text-indigo-400';

  return (
    <div className="space-y-1.5">
      <div className="flex justify-between text-xs">
        <span className="text-slate-500">Allocation</span>
        <span className={`font-mono font-semibold ${textColor}`}>{pct}%</span>
      </div>
      <div className="h-2 bg-slate-800 rounded-full overflow-hidden">
        <div
          className={`h-full rounded-full util-bar-fill ${color}`}
          style={{ width: `${Math.min(pct, 100)}%` }}
        />
      </div>
    </div>
  );
}

function MarketCard({ market, isLoading }) {
  if (isLoading) {
    return (
      <div className="glass-card rounded-xl p-4 space-y-3 animate-pulse">
        <div className="h-4 bg-slate-800 rounded w-24" />
        <div className="h-8 bg-slate-800 rounded" />
        <div className="h-8 bg-slate-800 rounded" />
        <div className="h-5 bg-slate-800 rounded w-32" />
      </div>
    );
  }

  const utilPct = market.utilizationBps / 100;
  const isCriticalUtil = utilPct >= 95;
  const isCriticalAlloc = market.allocationPct >= 40;

  return (
    <div className={`glass-card rounded-xl p-4 space-y-3 transition-all duration-300
      ${(isCriticalUtil || isCriticalAlloc) ? 'border-red-500/25 shadow-sm shadow-red-500/10' : ''}`}>

      {/* Market name + address */}
      <div className="flex items-center justify-between">
        <span className="font-semibold text-white text-sm">{market.name}</span>
        <span className="text-xs text-slate-600 font-mono">
          {market.address.slice(0, 6)}…{market.address.slice(-4)}
        </span>
      </div>

      {/* Balance */}
      <div>
        <div className="text-xs text-slate-500 mb-0.5">Vault Balance</div>
        <div className="text-xl font-bold font-mono text-white">${formatUSDC(market.balance)}</div>
        <div className="text-xs text-slate-600">USDC</div>
      </div>

      {/* Bars */}
      <div className="space-y-2.5">
        <AllocBar pct={market.allocationPct} />
        <UtilBar bps={market.utilizationBps} />
      </div>

      {/* Warnings */}
      {isCriticalUtil && (
        <div className="flex items-center gap-1.5 text-xs text-red-400 bg-red-500/8 border border-red-500/20 rounded-lg px-2.5 py-1.5">
          <span>⚠</span>
          <span>Critically high utilization — risk of illiquidity</span>
        </div>
      )}
      {isCriticalAlloc && !isCriticalUtil && (
        <div className="flex items-center gap-1.5 text-xs text-amber-400 bg-amber-500/8 border border-amber-500/20 rounded-lg px-2.5 py-1.5">
          <span>!</span>
          <span>High concentration — over 40% in single market</span>
        </div>
      )}
    </div>
  );
}

export default function MarketsPanel({ data, isLoading }) {
  const markets = data?.markets ?? [{}, {}];

  return (
    <div className="glass-card rounded-2xl overflow-hidden">
      {/* Header */}
      <div className="px-5 py-4 border-b border-slate-800/60 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 rounded-lg bg-blue-500/15 border border-blue-500/25 flex items-center justify-center">
            <svg className="w-3.5 h-3.5 text-blue-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
              <line x1="18" y1="20" x2="18" y2="10"/><line x1="12" y1="20" x2="12" y2="4"/>
              <line x1="6" y1="20" x2="6" y2="14"/>
            </svg>
          </div>
          <span className="font-semibold text-white text-sm">Lending Markets</span>
        </div>
        <span className="text-xs text-slate-500">{markets.length} active</span>
      </div>

      <div className="p-4">
        {/* Risk thresholds legend */}
        <div className="grid grid-cols-3 gap-2 mb-4">
          {[
            { label: 'SAFE',     desc: 'alloc <25%  util <80%',  color: 'text-emerald-400', bg: 'bg-emerald-500/8 border-emerald-500/15' },
            { label: 'CAUTION',  desc: 'alloc 25–40%  util 80–95%', color: 'text-amber-400', bg: 'bg-amber-500/8 border-amber-500/15' },
            { label: 'CRITICAL', desc: 'alloc >40%  util >95%',   color: 'text-red-400', bg: 'bg-red-500/8 border-red-500/15' },
          ].map(t => (
            <div key={t.label} className={`border rounded-lg px-2 py-1.5 text-center ${t.bg}`}>
              <div className={`text-xs font-bold font-mono ${t.color}`}>{t.label}</div>
              <div className="text-[10px] text-slate-600 mt-0.5">{t.desc}</div>
            </div>
          ))}
        </div>

        {/* Market cards */}
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
          {isLoading
            ? [0,1].map(i => <MarketCard key={i} isLoading />)
            : markets.map(m => <MarketCard key={m.address} market={m} isLoading={false} />)
          }
        </div>
      </div>
    </div>
  );
}
