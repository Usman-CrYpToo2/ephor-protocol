import React, { useState } from 'react';

// ── Single demo action card ───────────────────────────────────────────────────

function DemoCard({
  title, description, buttonLabel, onClick,
  variant = 'default', badge, warning, disabled = false,
}) {
  const [loading, setLoading] = useState(false);

  const handle = async () => {
    setLoading(true);
    try { await onClick(); }
    finally { setLoading(false); }
  };

  const variantStyles = {
    critical: {
      card:   'border-red-500/20 bg-red-500/4',
      badge:  'text-red-400 bg-red-500/10 border-red-500/20',
      button: 'bg-red-700 hover:bg-red-600 text-white shadow-red-500/20',
    },
    caution: {
      card:   'border-amber-500/20 bg-amber-500/4',
      badge:  'text-amber-400 bg-amber-500/10 border-amber-500/20',
      button: 'bg-amber-700 hover:bg-amber-600 text-white shadow-amber-500/20',
    },
    safe: {
      card:   'border-emerald-500/20 bg-emerald-500/4',
      badge:  'text-emerald-400 bg-emerald-500/10 border-emerald-500/20',
      button: 'bg-emerald-700 hover:bg-emerald-600 text-white shadow-emerald-500/20',
    },
    info: {
      card:   'border-blue-500/20 bg-blue-500/4',
      badge:  'text-blue-400 bg-blue-500/10 border-blue-500/20',
      button: 'bg-blue-700 hover:bg-blue-600 text-white shadow-blue-500/20',
    },
    default: {
      card:   'border-slate-700/60',
      badge:  'text-slate-400 bg-slate-700/40 border-slate-600/40',
      button: 'bg-slate-700 hover:bg-slate-600 text-white',
    },
  };

  const s = variantStyles[variant] ?? variantStyles.default;

  return (
    <div className={`glass-card rounded-2xl p-5 border ${s.card} flex flex-col gap-4`}>
      <div className="flex items-start justify-between gap-3">
        <div className="flex-1">
          <div className="flex items-center gap-2 mb-2">
            <span className="font-semibold text-white">{title}</span>
            {badge && (
              <span className={`text-xs font-mono font-bold px-2 py-0.5 rounded-full border ${s.badge}`}>
                {badge}
              </span>
            )}
          </div>
          <p className="text-sm text-slate-400 leading-relaxed">{description}</p>
        </div>
      </div>

      {warning && (
        <div className="text-xs text-amber-400/80 bg-amber-500/8 border border-amber-500/15 rounded-lg px-3 py-2">
          {warning}
        </div>
      )}

      <button
        onClick={handle}
        disabled={disabled || loading}
        className={`w-full py-2.5 rounded-xl text-sm font-semibold transition-all shadow-sm disabled:opacity-40 disabled:cursor-not-allowed ${s.button}`}
      >
        {loading ? (
          <span className="flex items-center justify-center gap-2">
            <svg className="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
            </svg>
            Running…
          </span>
        ) : buttonLabel}
      </button>
    </div>
  );
}

// ── Demo page ─────────────────────────────────────────────────────────────────

export default function DemoPage({
  data, isConnected,
  onSetCritical, onSetCaution, onSetSafe, onSimulateYield, onMintUsdc, onUnpause,
}) {
  const isPaused = data?.vault?.depositsPaused;
  const canAct   = isConnected;

  return (
    <div className="space-y-6">
      <div>
        <h2 className="text-xl font-bold text-white mb-1">Demo Controls</h2>
        <p className="text-sm text-slate-500">
          Testnet helpers for showcasing the protocol. Set up vault conditions, simulate time passing,
          and trigger AI risk checks to see the sentinel respond in real time.
        </p>
      </div>

      {!isConnected && (
        <div className="glass-card rounded-2xl p-4 text-center">
          <p className="text-sm text-slate-500">Connect your wallet to use demo controls.</p>
        </div>
      )}

      {/* Risk scenario section */}
      <div>
        <div className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-3">Risk Scenarios</div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <DemoCard
            title="Set CRITICAL Scenario"
            badge="CRITICAL"
            variant="critical"
            description="Allocates 60% of vault assets to Market A and sets utilization to 96%. Both CRITICAL thresholds met (alloc >40% and util >95%) — AI will pause deposits and emergency deallocate."
            buttonLabel="Set CRITICAL Conditions"
            warning="This will allocate real vault funds. Trigger an AI Check on the Sentinel tab to see the automated response."
            disabled={!canAct}
            onClick={onSetCritical}
          />

          <DemoCard
            title="Set CAUTION Scenario"
            badge="CAUTION"
            variant="caution"
            description="Sets Market A utilization to 85% — above the 80% caution threshold but below the 95% critical threshold. AI will return CAUTION: risk alert emitted, no automated action taken."
            buttonLabel="Set CAUTION Conditions"
            disabled={!canAct}
            onClick={onSetCaution}
          />

          <DemoCard
            title="Reset to SAFE Scenario"
            badge="SAFE"
            variant="safe"
            description="Sets Market A utilization to 30% (well below all risk thresholds). With low allocation and low utilization, the AI will return SAFE: vault operating normally, no action taken."
            buttonLabel="Reset to SAFE Conditions"
            disabled={!canAct}
            onClick={onSetSafe}
          />
        </div>
      </div>

      {/* Yield simulation */}
      <div>
        <div className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-3">Yield Simulation</div>
        <DemoCard
          title="Simulate 30-Day Yield"
          badge="+0.41%"
          variant="info"
          description="Calls fastForwardDays(30) on both lending markets, advancing the interest index as if 30 days passed at 5% APY. The vault's totalAssets() increases, raising the share price. Deposit USDC first (in My Position tab), then simulate yield to watch your position value grow."
          buttonLabel="Fast-forward 30 Days of Yield"
          disabled={!canAct}
          onClick={onSimulateYield}
        />
      </div>

      {/* Admin tools */}
      <div>
        <div className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-3">Admin Tools</div>
        <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
          {isPaused && (
            <DemoCard
              title="Unpause Deposits"
              variant="safe"
              description="Re-enables new deposits on the vault. The AI sentinel pauses deposits automatically when a CRITICAL verdict is received. Use this to restore normal operations after reviewing the risk."
              buttonLabel="Unpause Vault Deposits"
              disabled={!canAct}
              onClick={onUnpause}
            />
          )}

          <DemoCard
            title="Mint 10,000 USDC"
            variant="default"
            description="Mints 10,000 test USDC tokens directly to your wallet. Only works because this is a MockUSDC contract on testnet — real deployments would use actual USDC."
            buttonLabel="Mint Test USDC"
            disabled={!canAct}
            onClick={onMintUsdc}
          />
        </div>
      </div>

      {/* Verdict outcomes */}
      <div>
        <div className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-3">Expected Verdict Outcomes</div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          {[
            {
              label: 'SAFE',
              color: 'text-emerald-400',
              bg: 'bg-emerald-500/8 border-emerald-500/20',
              icon: '✓',
              trigger: 'Utilization < 80% and allocation < 25% on all markets.',
              outcome: 'No automated action. VaultChecked event emitted. Vault continues operating normally.',
            },
            {
              label: 'CAUTION',
              color: 'text-amber-400',
              bg: 'bg-amber-500/8 border-amber-500/20',
              icon: '!',
              trigger: 'Utilization 80–95% or allocation 25–40% on any market.',
              outcome: 'No automated action. RiskAlert event emitted. Monitoring recommended.',
            },
            {
              label: 'CRITICAL',
              color: 'text-red-400',
              bg: 'bg-red-500/8 border-red-500/20',
              icon: '⚠',
              trigger: 'Utilization > 95% and allocation > 40% on any market.',
              outcome: 'pauseDeposits() called automatically + emergencyDeallocate(50%) on the highest-util market.',
            },
          ].map(({ label, color, bg, icon, trigger, outcome }) => (
            <div key={label} className={`rounded-2xl border p-4 space-y-3 ${bg}`}>
              <div className={`flex items-center gap-2 font-bold font-mono ${color}`}>
                <span className={`w-7 h-7 rounded-full border flex items-center justify-center text-sm ${bg}`}>{icon}</span>
                {label}
              </div>
              <div>
                <div className="text-xs text-slate-500 uppercase tracking-wider mb-1">Triggers when</div>
                <p className="text-xs text-slate-400 leading-relaxed">{trigger}</p>
              </div>
              <div>
                <div className="text-xs text-slate-500 uppercase tracking-wider mb-1">On-chain response</div>
                <p className="text-xs text-slate-400 leading-relaxed">{outcome}</p>
              </div>
            </div>
          ))}
        </div>
      </div>

      {/* How it works section */}
      <div className="glass-card rounded-2xl p-5 space-y-3">
        <div className="text-sm font-semibold text-slate-300">How the AI Risk Check Works</div>
        <ol className="space-y-2.5">
          {[
            { step: '1', text: 'checkVault() reads 5 on-chain metrics: totalAssets, idleBufferPct, marketAllocationPct (×2), utilizationBps (×2).' },
            { step: '2', text: 'Metrics are encoded into a plain-English prompt and sent to Somnia\'s LLM Inference Agent via createRequest().' },
            { step: '3', text: '3 validators run Qwen3-30B with fixed seed and temperature=0, ensuring deterministic output across all validators.' },
            { step: '4', text: 'Once consensus is reached, the platform calls handleResponse() on the VaultSentinel contract.' },
            { step: '5', text: 'CRITICAL → pauseDeposits() + emergencyDeallocate(50% of highest-util market). CAUTION → event only. SAFE → event only.' },
          ].map(({ step, text }) => (
            <li key={step} className="flex gap-3 text-sm text-slate-400">
              <span className="flex-shrink-0 w-5 h-5 rounded-full bg-indigo-500/15 border border-indigo-500/25 flex items-center justify-center text-xs font-bold text-indigo-400 mt-0.5">
                {step}
              </span>
              <span>{text}</span>
            </li>
          ))}
        </ol>
      </div>
    </div>
  );
}
