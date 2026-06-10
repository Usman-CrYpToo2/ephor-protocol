import React from 'react';
import { RISK_THEME, formatTime } from '../../config';

function EventRow({ item }) {
  const theme = RISK_THEME[item.level] || RISK_THEME[0];
  return (
    <div className="flex items-start gap-4 px-4 py-3 border-b border-white/[0.04] last:border-0">
      <div className="flex-shrink-0 mt-0.5">
        <span className={`w-2 h-2 rounded-full ${theme.dot} block mt-1`} />
      </div>
      <div className="flex-1 min-w-0">
        <div className="flex items-center gap-2">
          <span className={`text-xs font-mono font-semibold ${theme.text}`}>{theme.label}</span>
          <span className="text-xs text-zinc-600">AI Risk Check</span>
        </div>
        {item.verdict && (
          <div className="text-xs text-zinc-700 mt-0.5 truncate font-mono">{item.verdict}</div>
        )}
        <div className="text-xs text-zinc-600 mt-0.5">
          TVL: ${item.totalAssets?.toLocaleString(undefined, { maximumFractionDigits: 0 }) ?? '—'}
          · Idle: {(item.idleBps / 100).toFixed(1)}%
        </div>
      </div>
      <div className="text-xs text-zinc-600 flex-shrink-0">{formatTime(item.timestamp)}</div>
    </div>
  );
}

export default function ActivityTab({ data, isLoading }) {
  if (isLoading || !data) {
    return (
      <div className="space-y-2 animate-pulse">
        {[1,2,3,4,5].map(i => <div key={i} className="h-14 bg-white/[0.03] rounded" />)}
      </div>
    );
  }

  const history = data.sentinel.history || [];

  return (
    <div className="space-y-4">
      <div className="text-xs text-zinc-600">
        Showing last {history.length} events
      </div>

      {history.length === 0 ? (
        <div className="rounded-xl border border-white/[0.06] py-12 text-center">
          <div className="text-zinc-700 text-sm">No activity yet.</div>
          <div className="text-zinc-800 text-xs mt-1">Trigger an AI Risk Check to see events here.</div>
        </div>
      ) : (
        <div className="rounded-xl border border-white/[0.06] overflow-hidden">
          {history.slice(0, 20).map((item, i) => (
            <EventRow key={i} item={item} />
          ))}
        </div>
      )}
    </div>
  );
}
