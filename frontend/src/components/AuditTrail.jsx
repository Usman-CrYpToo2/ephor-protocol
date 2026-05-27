import React from 'react';
import { RISK_THEME, formatUSDC } from '../config';

function getActionTaken(item) {
  if (item.level === 2) return 'Deposits paused + Emergency deallocate';
  if (item.level === 1) return 'Risk alert emitted';
  return 'No action';
}

export default function AuditTrail({ data, isLoading }) {
  const history = data?.sentinel?.history ?? [];

  return (
    <div className="glass-card rounded-2xl overflow-hidden">
      {/* Header */}
      <div className="px-5 py-4 border-b border-slate-800/60 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 rounded-lg bg-slate-700/50 border border-slate-600/30 flex items-center justify-center">
            <svg className="w-3.5 h-3.5 text-slate-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
              <polyline points="22 12 18 12 15 21 9 3 6 12 2 12"/>
            </svg>
          </div>
          <span className="font-semibold text-white text-sm">Audit Trail</span>
        </div>
        <span className="text-xs text-slate-500">{history.length} recorded check{history.length !== 1 ? 's' : ''}</span>
      </div>

      {isLoading ? (
        <div className="p-5 space-y-3">
          {[1,2,3].map(i => (
            <div key={i} className="h-12 bg-slate-800/60 rounded-xl animate-pulse" />
          ))}
        </div>
      ) : history.length === 0 ? (
        <div className="flex flex-col items-center justify-center py-12 text-center px-5">
          <div className="w-12 h-12 rounded-full bg-slate-800/60 flex items-center justify-center mb-3">
            <svg className="w-5 h-5 text-slate-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.5">
              <circle cx="12" cy="12" r="10"/>
              <line x1="12" y1="8" x2="12" y2="12"/>
              <line x1="12" y1="16" x2="12.01" y2="16"/>
            </svg>
          </div>
          <div className="text-sm text-slate-500">No AI checks recorded yet</div>
          <div className="text-xs text-slate-600 mt-1">Trigger an AI risk check to populate the audit trail</div>
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="border-b border-slate-800/60">
                <th className="text-left px-5 py-3 text-xs font-medium text-slate-500 uppercase tracking-wider">Timestamp</th>
                <th className="text-left px-4 py-3 text-xs font-medium text-slate-500 uppercase tracking-wider">AI Verdict</th>
                <th className="text-right px-4 py-3 text-xs font-medium text-slate-500 uppercase tracking-wider hidden sm:table-cell">Total Assets</th>
                <th className="text-right px-4 py-3 text-xs font-medium text-slate-500 uppercase tracking-wider hidden md:table-cell">Idle %</th>
                <th className="text-left px-4 py-3 text-xs font-medium text-slate-500 uppercase tracking-wider hidden lg:table-cell">Action Taken</th>
              </tr>
            </thead>
            <tbody>
              {history.map((item, i) => {
                const theme = RISK_THEME[item.level] ?? RISK_THEME[0];
                const date  = new Date(item.timestamp * 1000);
                return (
                  <tr
                    key={i}
                    className="border-b border-slate-800/40 last:border-0 hover:bg-slate-800/20 transition-colors"
                  >
                    <td className="px-5 py-3">
                      <div className="text-xs text-white font-mono">{date.toLocaleDateString()}</div>
                      <div className="text-xs text-slate-500">{date.toLocaleTimeString()}</div>
                    </td>
                    <td className="px-4 py-3">
                      <span className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-bold font-mono border ${theme.text} ${theme.bg} ${theme.border}`}>
                        <span className={`w-1.5 h-1.5 rounded-full ${theme.dot}`} />
                        {item.verdict}
                      </span>
                    </td>
                    <td className="px-4 py-3 text-right hidden sm:table-cell">
                      <span className="text-xs text-white font-mono">${formatUSDC(item.totalAssets)}</span>
                    </td>
                    <td className="px-4 py-3 text-right hidden md:table-cell">
                      <span className="text-xs text-slate-300 font-mono">{item.idlePct}%</span>
                    </td>
                    <td className="px-4 py-3 hidden lg:table-cell">
                      <span className={`text-xs ${item.level === 2 ? 'text-red-400' : item.level === 1 ? 'text-amber-400' : 'text-slate-500'}`}>
                        {getActionTaken(item)}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}
