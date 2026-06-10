import React from 'react';
import { formatUSDC, RISK_THEME } from '../../config';

function MiniChart({ points }) {
  if (!points || points.length < 2) {
    return (
      <div className="h-32 flex items-center justify-center text-xs text-zinc-700">
        Not enough history yet
      </div>
    );
  }

  const W = 500, H = 120, pad = 10;
  const values = points.map(p => p.sharePrice ?? 1);
  const minV = Math.min(...values);
  const maxV = Math.max(...values);
  const range = maxV - minV || 0.001;
  const step  = (W - 2 * pad) / (points.length - 1);

  const pts = points.map((p, i) => {
    const x = pad + i * step;
    const y = H - pad - ((p.sharePrice - minV) / range) * (H - 2 * pad);
    return `${x},${y}`;
  });

  const polyline = pts.join(' ');
  const area = `M${pts[0]} L${pts.join(' L')} L${pad + (points.length - 1) * step},${H} L${pad},${H} Z`;

  return (
    <svg viewBox={`0 0 ${W} ${H}`} className="w-full h-32" preserveAspectRatio="none">
      <defs>
        <linearGradient id="chartGrad" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0%" stopColor="#4ade80" stopOpacity="0.15" />
          <stop offset="100%" stopColor="#4ade80" stopOpacity="0" />
        </linearGradient>
      </defs>
      <path d={area} fill="url(#chartGrad)" />
      <polyline points={polyline} fill="none" stroke="#4ade80" strokeWidth="1.5" strokeLinejoin="round" />
    </svg>
  );
}

export default function PerformanceTab({ data, isLoading }) {
  if (isLoading || !data) {
    return <div className="h-40 bg-white/[0.03] rounded animate-pulse" />;
  }

  const { vault, sentinel } = data;
  const history = sentinel.history || [];

  const chartPoints = history
    .map(h => ({ sharePrice: h.totalAssets > 0 ? h.totalAssets / 1000 : 1, ts: h.timestamp }))
    .slice(0, 20);

  const pctGain = ((vault.sharePrice - 1) * 100).toFixed(4);

  return (
    <div className="space-y-6">
      <div className="grid grid-cols-3 gap-4">
        <div className="rounded-xl border border-white/[0.06] p-4">
          <div className="text-xs text-zinc-500 mb-1">Net APY</div>
          <div className="text-2xl font-mono font-semibold text-green-400">{vault.netApy.toFixed(2)}%</div>
          <div className="text-xs text-zinc-600 mt-1">weighted market average</div>
        </div>
        <div className="rounded-xl border border-white/[0.06] p-4">
          <div className="text-xs text-zinc-500 mb-1">Share Price</div>
          <div className="text-2xl font-mono font-semibold text-white">{vault.sharePrice.toFixed(6)}</div>
          <div className={`text-xs mt-1 ${Number(pctGain) >= 0 ? 'text-green-400' : 'text-red-400'}`}>
            {Number(pctGain) >= 0 ? '+' : ''}{pctGain}% since genesis
          </div>
        </div>
        <div className="rounded-xl border border-white/[0.06] p-4">
          <div className="text-xs text-zinc-500 mb-1">Total Checks</div>
          <div className="text-2xl font-mono font-semibold text-white">{sentinel.totalChecks}</div>
          <div className="text-xs text-zinc-600 mt-1">{sentinel.criticalCount} critical events</div>
        </div>
      </div>

      <div>
        <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">
          Share Price History
        </div>
        <div className="rounded-xl border border-white/[0.06] p-4">
          <MiniChart points={chartPoints} />
        </div>
      </div>
    </div>
  );
}
