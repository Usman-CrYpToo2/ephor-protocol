import React from 'react';
import { formatUSDC, formatBps } from '../../config';

const BAR_COLORS = [
  { bg: 'bg-indigo-500', text: 'text-indigo-400', border: 'border-indigo-500/30' },
  { bg: 'bg-violet-500', text: 'text-violet-400', border: 'border-violet-500/30' },
  { bg: 'bg-blue-500',   text: 'text-blue-400',   border: 'border-blue-500/30'   },
  { bg: 'bg-cyan-500',   text: 'text-cyan-400',   border: 'border-cyan-500/30'   },
];

function UtilBar({ bps }) {
  const pct = Math.min(bps / 100, 100);
  const color = pct < 80 ? 'bg-green-500' : pct < 95 ? 'bg-amber-500' : 'bg-red-500';
  return (
    <div className="flex items-center gap-2">
      <div className="flex-1 h-1.5 bg-white/[0.06] rounded-full overflow-hidden">
        <div className={`h-full rounded-full util-bar-fill ${color}`} style={{ width: `${pct}%` }} />
      </div>
      <span className={`text-xs font-mono w-10 text-right ${pct >= 95 ? 'text-red-400' : pct >= 80 ? 'text-amber-400' : 'text-zinc-400'}`}>
        {(bps / 100).toFixed(0)}%{pct >= 80 && '⚠'}
      </span>
    </div>
  );
}

export default function AllocationTab({ data, isLoading }) {
  if (isLoading || !data) {
    return (
      <div className="space-y-4 animate-pulse">
        <div className="h-8 bg-white/[0.04] rounded" />
        <div className="h-40 bg-white/[0.03] rounded" />
      </div>
    );
  }

  const { markets, vault } = data;
  const totalAssets = vault.totalAssets;
  const idleBps = vault.idleBufferBps;
  const idleAmt = vault.idleAmt;

  // Treat as empty when totalAssets < $1 — dust from accrued interest can inflate
  // allocation percentages to misleading values (e.g. 13.6%) while balances show $0.
  const isEmpty = totalAssets < 1;

  const segments = isEmpty ? [] : [
    ...markets.map((m, i) => ({
      name:  m.name,
      bps:   m.allocationBps,
      color: BAR_COLORS[i % BAR_COLORS.length],
    })),
    {
      name:  'Idle',
      bps:   idleBps,
      color: { bg: 'bg-zinc-700', text: 'text-zinc-500', border: 'border-zinc-600/30' },
    },
  ].filter(s => s.bps > 0);

  return (
    <div className="space-y-6">
      {/* Stacked bar */}
      <div>
        <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">Allocation</div>
        {isEmpty ? (
          <div className="flex rounded-xl overflow-hidden h-8 bg-white/[0.03] items-center justify-center">
            <span className="text-xs text-zinc-600">No assets deposited</span>
          </div>
        ) : (
          <>
            <div className="flex rounded-xl overflow-hidden h-8 gap-px">
              {segments.map((s, i) => (
                <div
                  key={i}
                  className={`${s.color.bg} flex items-center justify-center text-xs font-medium text-white/80`}
                  style={{ width: `${s.bps / 100}%` }}
                  title={`${s.name}: ${(s.bps / 100).toFixed(1)}%`}
                >
                  {s.bps >= 800 && `${s.name}`}
                </div>
              ))}
            </div>
            <div className="flex flex-wrap gap-3 mt-2">
              {segments.map((s, i) => (
                <div key={i} className="flex items-center gap-1.5 text-xs text-zinc-500">
                  <span className={`w-2 h-2 rounded-sm ${s.color.bg}`} />
                  {s.name} ({(s.bps / 100).toFixed(1)}%)
                </div>
              ))}
            </div>
          </>
        )}
      </div>

      {/* Market table */}
      <div>
        <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">Markets</div>
        <div className="rounded-xl border border-white/[0.06] overflow-hidden">
          <table className="w-full text-sm">
            <thead>
              <tr className="border-b border-white/[0.06]">
                {['Market','Allocation','Balance','Utilization','APY','Cap'].map(h => (
                  <th key={h} className="px-4 py-3 text-left text-xs font-medium text-zinc-600 uppercase tracking-wider first:pl-5 last:pr-5">
                    {h}
                  </th>
                ))}
              </tr>
            </thead>
            <tbody>
              {markets.map((m, i) => {
                const color = BAR_COLORS[i % BAR_COLORS.length];
                return (
                  <tr key={m.address} className="border-b border-white/[0.04] last:border-0">
                    <td className="pl-5 px-4 py-3">
                      <div className="flex items-center gap-2">
                        <span className={`w-2 h-2 rounded-full ${color.bg}`} />
                        <span className="text-white">{m.name}</span>
                      </div>
                    </td>
                    <td className="px-4 py-3">
                      <div className={`text-xs font-mono ${isEmpty ? 'text-zinc-600' : color.text}`}>
                        {isEmpty ? '0%' : formatBps(m.allocationBps)}
                      </div>
                      <div className="text-xs text-zinc-600">${formatUSDC(isEmpty ? 0 : m.balance)}</div>
                    </td>
                    <td className="px-4 py-3 font-mono text-zinc-300">${formatUSDC(isEmpty ? 0 : m.balance)}</td>
                    <td className="px-4 py-3 w-36"><UtilBar bps={m.utilizationBps} /></td>
                    <td className="px-4 py-3 font-mono text-green-400">{formatBps(m.supplyRateBps)}</td>
                    <td className="pr-5 px-4 py-3 font-mono text-zinc-400">${formatUSDC(m.supplyCap)}</td>
                  </tr>
                );
              })}
              <tr className="border-t border-white/[0.06]">
                <td className="pl-5 px-4 py-3">
                  <div className="flex items-center gap-2">
                    <span className="w-2 h-2 rounded-full bg-zinc-600" />
                    <span className="text-zinc-500">Idle</span>
                  </div>
                </td>
                <td className="px-4 py-3">
                  <div className="text-xs font-mono text-zinc-500">{isEmpty ? '0%' : formatBps(idleBps)}</div>
                  <div className="text-xs text-zinc-600">${formatUSDC(isEmpty ? 0 : idleAmt)}</div>
                </td>
                <td className="px-4 py-3 font-mono text-zinc-500">${formatUSDC(isEmpty ? 0 : idleAmt)}</td>
                <td colSpan={3} className="px-4 py-3 text-zinc-700 text-xs">—</td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}
