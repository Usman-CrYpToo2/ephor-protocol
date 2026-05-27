import React from 'react';
import { RISK_THEME, formatTime } from '../config';

function MetricRow({ label, value, valueClass = 'text-white' }) {
  return (
    <div className="flex items-center justify-between py-2 border-b border-slate-800/50 last:border-0">
      <span className="text-xs text-slate-500">{label}</span>
      <span className={`text-xs font-medium font-mono ${valueClass}`}>{value}</span>
    </div>
  );
}

export default function SentinelPanel({ data, isLoading }) {
  const sentinel  = data?.sentinel;
  const isPending = sentinel?.isCheckPending;
  const level     = sentinel?.latestLevel ?? 0;
  const theme     = RISK_THEME[level] ?? RISK_THEME[0];

  return (
    <div className="glass-card rounded-2xl overflow-hidden">
      {/* Header */}
      <div className="px-5 py-4 border-b border-slate-800/60 flex items-center justify-between">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 rounded-lg bg-violet-500/15 border border-violet-500/25 flex items-center justify-center">
            <svg className="w-3.5 h-3.5 text-violet-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
              <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" strokeLinecap="round" strokeLinejoin="round"/>
            </svg>
          </div>
          <span className="font-semibold text-white text-sm">AI Sentinel</span>
        </div>
        {isPending && (
          <span className="flex items-center gap-1.5 text-xs text-blue-400">
            <span className="w-1.5 h-1.5 rounded-full bg-blue-400 animate-pulse" />
            Running
          </span>
        )}
      </div>

      <div className="px-5 py-4 space-y-4">
        {isLoading ? (
          <div className="space-y-3">
            {[1,2,3].map(i => <div key={i} className="h-12 bg-slate-800/60 rounded-xl animate-pulse" />)}
          </div>
        ) : isPending ? (
          /* Pending state */
          <div className="flex flex-col items-center gap-3 py-6">
            <div className="relative">
              <div className="w-16 h-16 rounded-full bg-blue-500/10 border border-blue-500/30 flex items-center justify-center">
                <svg className="w-6 h-6 text-blue-400 animate-spin" fill="none" viewBox="0 0 24 24">
                  <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                  <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
                </svg>
              </div>
            </div>
            <div className="text-center">
              <div className="text-sm font-semibold text-blue-400">AI Check In Progress</div>
              <div className="text-xs text-slate-500 mt-1">Somnia validators reaching consensus</div>
              <div className="text-xs text-slate-600 mt-0.5">Request #{sentinel?.activeRequestId}</div>
            </div>
            <div className="text-xs text-slate-500 italic">Typically 1–5 minutes</div>
          </div>
        ) : (
          <>
            {/* Latest verdict badge */}
            <div className={`rounded-xl border p-4 flex items-center gap-4 ${theme.bg} ${theme.border}`}>
              <div className={`relative flex items-center justify-center w-12 h-12 rounded-full ${theme.bg} border ${theme.border} flex-shrink-0`}>
                <span className={`text-lg font-bold ${theme.text}`}>
                  {level === 0 ? '✓' : level === 1 ? '!' : '⚠'}
                </span>
              </div>
              <div>
                <div className={`text-xl font-bold font-mono ${theme.text}`}>
                  {sentinel?.latestVerdict || 'NO DATA'}
                </div>
                <div className="text-xs text-slate-500">
                  {formatTime(sentinel?.latestVerdictTs)}
                  {sentinel?.latestVerdictTs > 0 && ` · ${new Date(sentinel.latestVerdictTs * 1000).toLocaleTimeString()}`}
                </div>
              </div>
            </div>

            {/* Metrics */}
            <div>
              <MetricRow label="Total Checks" value={sentinel?.totalChecks ?? 0} />
              <MetricRow
                label="Critical Events"
                value={sentinel?.criticalCount ?? 0}
                valueClass={sentinel?.criticalCount > 0 ? 'text-red-400' : 'text-white'}
              />
              <MetricRow
                label="Auto-Pause"
                value={sentinel?.autoPauseEnabled ? 'Enabled' : 'Disabled'}
                valueClass={sentinel?.autoPauseEnabled ? 'text-emerald-400' : 'text-slate-400'}
              />
              <MetricRow
                label="Vault Registered"
                value={sentinel?.registered ? 'Yes' : 'No'}
                valueClass={sentinel?.registered ? 'text-emerald-400' : 'text-red-400'}
              />
            </div>

            {/* Cooldown info */}
            {sentinel?.lastCheckedAt > 0 && (
              <div className="text-xs text-slate-600 text-center pt-1">
                Next check available in{' '}
                {Math.max(0, 300 - (Math.floor(Date.now() / 1000) - sentinel.lastCheckedAt))}s
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}
