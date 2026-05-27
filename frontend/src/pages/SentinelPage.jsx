import React from 'react';
import { RISK_THEME, formatUSDC, formatTime, CHECK_DEPOSIT } from '../config';

// ── Large verdict display ─────────────────────────────────────────────────────

function VerdictCard({ data, isLoading }) {
  const s     = data?.sentinel;
  const level = s?.latestLevel ?? 0;
  const theme = RISK_THEME[level] ?? RISK_THEME[0];

  return (
    <div className="glass-card rounded-2xl p-6">
      <div className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-5">Latest AI Verdict</div>

      {isLoading ? (
        <div className="h-24 bg-slate-800/60 rounded-xl animate-pulse" />
      ) : s?.isCheckPending ? (
        <div className="flex items-center gap-5 p-5 bg-blue-500/10 border border-blue-500/25 rounded-xl">
          <div className="flex-shrink-0 w-14 h-14 rounded-full bg-blue-500/10 border border-blue-500/25 flex items-center justify-center">
            <svg className="w-7 h-7 text-blue-400 animate-spin" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
            </svg>
          </div>
          <div>
            <div className="text-xl font-bold text-blue-400">Check In Progress</div>
            <div className="text-sm text-slate-500 mt-1">Somnia validators are reaching consensus via LLM inference.</div>
            <div className="text-xs text-slate-600 mt-1">Request #{s?.activeRequestId} · Typically 1–5 minutes</div>
          </div>
        </div>
      ) : (
        <div className={`flex items-center gap-5 p-5 rounded-xl border ${theme.bg} ${theme.border}`}>
          <div className={`flex-shrink-0 w-14 h-14 rounded-full ${theme.bg} border ${theme.border} flex items-center justify-center text-2xl font-bold ${theme.text}`}>
            {level === 0 ? '✓' : level === 1 ? '!' : '⚠'}
          </div>
          <div>
            <div className={`text-2xl font-bold font-mono ${theme.text}`}>{theme.label}</div>
            <div className="text-sm text-slate-500 mt-1">
              {level === 0 && 'No risk conditions detected. Vault operating normally.'}
              {level === 1 && 'Elevated risk conditions. Monitor closely, no automated action taken.'}
              {level === 2 && 'Critical risk detected. Deposits paused and emergency deallocation executed.'}
            </div>
            <div className="text-xs text-slate-600 mt-1">
              {formatTime(s?.latestVerdictTs)}
              {s?.latestVerdictTs > 0 && ` · ${new Date(s.latestVerdictTs * 1000).toLocaleString()}`}
            </div>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Trigger check card ────────────────────────────────────────────────────────

function TriggerCard({ data, isConnected, onCheckVault }) {
  const s            = data?.sentinel;
  const isPending    = s?.isCheckPending;
  const lastChecked  = s?.lastCheckedAt ?? 0;
  const cooldownLeft = Math.max(0, 300 - (Math.floor(Date.now() / 1000) - lastChecked));
  const onCooldown   = cooldownLeft > 0 && lastChecked > 0;
  const canTrigger   = isConnected && !isPending && !onCooldown;

  return (
    <div className="glass-card rounded-2xl p-6">
      <div className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-4">Trigger New Check</div>

      <div className="flex flex-col sm:flex-row items-start sm:items-center gap-4">
        <div className="flex-1">
          <div className="text-sm text-slate-300">
            Sends vault metrics to Somnia's LLM Inference Agent. Validators run the model deterministically and return <span className="font-mono text-slate-400">SAFE</span>, <span className="font-mono text-amber-400">CAUTION</span>, or <span className="font-mono text-red-400">CRITICAL</span>.
          </div>
          <div className="flex items-center gap-4 mt-3 text-xs text-slate-600">
            <span>Cost: {CHECK_DEPOSIT} STT</span>
            <span>·</span>
            <span>3 validators</span>
            <span>·</span>
            {onCooldown
              ? <span className="text-amber-400">Cooldown: {cooldownLeft}s</span>
              : <span>5-min cooldown between checks</span>
            }
          </div>
        </div>
        <button
          onClick={onCheckVault}
          disabled={!canTrigger}
          className="flex-shrink-0 px-6 py-3 rounded-xl bg-indigo-600 hover:bg-indigo-500 disabled:opacity-40 disabled:cursor-not-allowed text-white font-semibold text-sm transition-all shadow-lg shadow-indigo-500/20 hover:shadow-indigo-500/30 whitespace-nowrap"
        >
          {isPending ? 'Check Running…' : onCooldown ? `Cooldown (${cooldownLeft}s)` : 'Trigger AI Check'}
        </button>
      </div>
    </div>
  );
}

// ── Metrics row ───────────────────────────────────────────────────────────────

function MetricsRow({ data, isLoading }) {
  const s = data?.sentinel;
  const metrics = [
    { label: 'Total Checks',    value: s?.totalChecks ?? 0,   color: 'text-white' },
    { label: 'Critical Events', value: s?.criticalCount ?? 0, color: s?.criticalCount > 0 ? 'text-red-400' : 'text-white' },
    { label: 'Auto-Pause',      value: s?.autoPauseEnabled ? 'Enabled' : 'Disabled', color: s?.autoPauseEnabled ? 'text-emerald-400' : 'text-slate-400' },
    { label: 'Vault Registered', value: s?.registered ? 'Yes' : 'No', color: s?.registered ? 'text-emerald-400' : 'text-red-400' },
  ];

  return (
    <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
      {metrics.map(m => (
        <div key={m.label} className="glass-card rounded-xl p-4">
          <div className="text-xs text-slate-500 mb-1.5">{m.label}</div>
          {isLoading
            ? <div className="h-5 bg-slate-800 rounded animate-pulse" />
            : <div className={`text-lg font-bold font-mono ${m.color}`}>{m.value}</div>
          }
        </div>
      ))}
    </div>
  );
}

// ── Audit trail ───────────────────────────────────────────────────────────────

function AuditTable({ data, isLoading }) {
  const history = data?.sentinel?.history ?? [];

  return (
    <div className="glass-card rounded-2xl overflow-hidden">
      <div className="px-6 py-4 border-b border-slate-800/60 flex items-center justify-between">
        <span className="font-semibold text-white">Audit Trail</span>
        <span className="text-xs text-slate-500">{history.length} check{history.length !== 1 ? 's' : ''} on-chain</span>
      </div>

      {isLoading ? (
        <div className="p-6 space-y-3">
          {[1,2,3].map(i => <div key={i} className="h-12 bg-slate-800/60 rounded-xl animate-pulse" />)}
        </div>
      ) : history.length === 0 ? (
        <div className="flex flex-col items-center py-16 text-center">
          <div className="w-12 h-12 rounded-full bg-slate-800/60 flex items-center justify-center mb-3">
            <svg className="w-5 h-5 text-slate-600" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.5">
              <circle cx="12" cy="12" r="10"/><line x1="12" y1="8" x2="12" y2="12"/><line x1="12" y1="16" x2="12.01" y2="16"/>
            </svg>
          </div>
          <div className="text-sm text-slate-500">No checks recorded yet</div>
          <div className="text-xs text-slate-600 mt-1">Trigger an AI check to populate this trail</div>
        </div>
      ) : (
        <div className="overflow-x-auto">
          <table className="w-full">
            <thead>
              <tr className="border-b border-slate-800/60">
                {['Time', 'Verdict', 'Total Assets', 'Idle', 'Outcome'].map(h => (
                  <th key={h} className="text-left px-6 py-3 text-xs font-medium text-slate-500 uppercase tracking-wider">{h}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {history.map((item, i) => {
                const theme = RISK_THEME[item.level] ?? RISK_THEME[0];
                const date  = new Date(item.timestamp * 1000);
                return (
                  <tr key={i} className="border-b border-slate-800/40 last:border-0 hover:bg-slate-800/20 transition-colors">
                    <td className="px-6 py-4">
                      <div className="text-sm text-white font-mono">{date.toLocaleDateString()}</div>
                      <div className="text-xs text-slate-500">{date.toLocaleTimeString()}</div>
                    </td>
                    <td className="px-6 py-4">
                      <span className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-bold font-mono border ${theme.text} ${theme.bg} ${theme.border}`}>
                        <span className={`w-1.5 h-1.5 rounded-full ${theme.dot}`} />
                        {item.verdict}
                      </span>
                    </td>
                    <td className="px-6 py-4">
                      <span className="text-sm font-mono text-white">${formatUSDC(item.totalAssets)}</span>
                    </td>
                    <td className="px-6 py-4">
                      <span className="text-sm font-mono text-slate-300">{item.idlePct}%</span>
                    </td>
                    <td className="px-6 py-4">
                      <span className={`text-xs ${item.level === 2 ? 'text-red-400' : item.level === 1 ? 'text-amber-400' : 'text-slate-500'}`}>
                        {item.level === 2 ? 'Deposits paused + Emergency deallocate'
                        : item.level === 1 ? 'Risk alert emitted'
                        : 'No action taken'}
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

// ── Sentinel page ─────────────────────────────────────────────────────────────

export default function SentinelPage({ data, isLoading, isConnected, onCheckVault }) {
  return (
    <div className="space-y-5">
      <div>
        <h2 className="text-xl font-bold text-white mb-1">AI Sentinel</h2>
        <p className="text-sm text-slate-500">
          Autonomous risk monitor powered by Somnia's on-chain LLM Inference Agent.
          Reaches consensus across 3 validators, then acts on the verdict automatically.
        </p>
      </div>

      <VerdictCard data={data} isLoading={isLoading} />
      <TriggerCard data={data} isConnected={isConnected} onCheckVault={onCheckVault} />
      <MetricsRow data={data} isLoading={isLoading} />
      <AuditTable data={data} isLoading={isLoading} />
    </div>
  );
}
