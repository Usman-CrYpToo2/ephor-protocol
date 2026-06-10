import React, { useState } from 'react';
import { useVault } from '../hooks/useVault';
import { VAULTS, REBALANCE_DEPOSIT } from '../config';

// ── Demo card ─────────────────────────────────────────────────────────────────

function DemoCard({ title, description, buttonLabel, onClick, variant = 'default', badge, warning, disabled = false }) {
  const [loading, setLoading] = useState(false);
  const handle = async () => {
    setLoading(true);
    try { await onClick(); } finally { setLoading(false); }
  };

  const styles = {
    critical: { card: 'border-red-500/20',     badge: 'text-red-400 bg-red-500/10 border-red-500/20',       btn: 'bg-red-700 hover:bg-red-600 text-white' },
    caution:  { card: 'border-amber-500/20',   badge: 'text-amber-400 bg-amber-500/10 border-amber-500/20',   btn: 'bg-amber-700 hover:bg-amber-600 text-white' },
    safe:     { card: 'border-emerald-500/20', badge: 'text-emerald-400 bg-emerald-500/10 border-emerald-500/20', btn: 'bg-emerald-700 hover:bg-emerald-600 text-white' },
    info:     { card: 'border-blue-500/20',    badge: 'text-blue-400 bg-blue-500/10 border-blue-500/20',       btn: 'bg-blue-700 hover:bg-blue-600 text-white' },
    default:  { card: 'border-white/[0.06]',   badge: 'text-zinc-400 bg-zinc-700/40 border-zinc-600/40',       btn: 'bg-zinc-700 hover:bg-zinc-600 text-white' },
  };
  const s = styles[variant] ?? styles.default;

  return (
    <div className={`rounded-2xl p-5 border ${s.card} bg-white/[0.02] flex flex-col gap-4`}>
      <div>
        <div className="flex items-center gap-2 mb-2">
          <span className="font-semibold text-white text-sm">{title}</span>
          {badge && (
            <span className={`text-xs font-mono font-bold px-2 py-0.5 rounded-full border ${s.badge}`}>{badge}</span>
          )}
        </div>
        <p className="text-xs text-zinc-500 leading-relaxed">{description}</p>
      </div>
      {warning && (
        <div className="text-xs text-amber-400/80 bg-amber-500/8 border border-amber-500/15 rounded-lg px-3 py-2">
          {warning}
        </div>
      )}
      <button
        onClick={handle}
        disabled={disabled || loading}
        className={`w-full py-2.5 rounded-xl text-sm font-semibold transition-all disabled:opacity-40 disabled:cursor-not-allowed ${s.btn}`}
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

export default function DemoPage({ walletProps, makeActions }) {
  const primaryVault  = VAULTS.find(v => !v.comingSoon);
  const { data, refetch } = useVault(primaryVault?.address, walletProps.userAddress);
  const actions = makeActions(primaryVault, refetch);
  const { isConnected } = walletProps;

  const isPaused = data?.vault?.depositsPaused;
  const canAct   = isConnected;

  return (
    <div className="max-w-7xl mx-auto px-6 py-8 space-y-7">
      <div>
        <h2 className="text-2xl font-semibold text-white mb-1">Demo Controls</h2>
        <p className="text-sm text-zinc-500">
          Testnet helpers for showcasing the protocol. Set vault conditions and trigger AI flows
          to see the sentinel and allocator respond in real time.
        </p>
      </div>

      {!isConnected && (
        <div className="rounded-2xl border border-white/[0.06] p-6 text-center">
          <p className="text-sm text-zinc-500">Connect your wallet to use demo controls.</p>
        </div>
      )}

      {/* Risk scenarios */}
      <section>
        <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">Risk Scenarios</div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <DemoCard
            title="Set CRITICAL" badge="CRITICAL" variant="critical"
            description="Sets Market B utilization to 96%. Market B has >40% allocation — both CRITICAL thresholds met. Then trigger AI Risk Check to see sentinel pause and deallocate."
            buttonLabel="Set CRITICAL Conditions"
            warning="Go to Vault → Risk AI tab and click 'Run Risk Check' immediately after."
            disabled={!canAct}
            onClick={actions.onSetCritical}
          />
          <DemoCard
            title="Set CAUTION" badge="CAUTION" variant="caution"
            description="Sets Market A utilization to 85% (above 80% caution threshold). AI returns CAUTION: risk alert emitted, no automated vault action."
            buttonLabel="Set CAUTION Conditions"
            disabled={!canAct}
            onClick={actions.onSetCaution}
          />
          <DemoCard
            title="Reset to SAFE" badge="SAFE" variant="safe"
            description="Resets both markets to safe utilization levels. AI will return SAFE and take no automated action."
            buttonLabel="Reset to SAFE"
            disabled={!canAct}
            onClick={actions.onSetSafe}
          />
        </div>
      </section>

      {/* Verdict reference */}
      <section>
        <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">Sentinel Verdict Outcomes</div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-3">
          {[
            { label: 'SAFE',     color: 'text-emerald-400', bg: 'bg-emerald-500/8 border-emerald-500/20', trigger: 'Util < 80% and alloc < 25%.',          outcome: 'VaultChecked emitted. No action.' },
            { label: 'CAUTION',  color: 'text-amber-400',   bg: 'bg-amber-500/8 border-amber-500/20',     trigger: 'Util 80–95% or alloc 25–40%.',          outcome: 'RiskAlert emitted. Monitor.' },
            { label: 'CRITICAL', color: 'text-red-400',     bg: 'bg-red-500/8 border-red-500/20',         trigger: 'Util >95% AND alloc >40%.',             outcome: 'pauseDeposits() + emergencyDeallocate(50%).' },
          ].map(({ label, color, bg, trigger, outcome }) => (
            <div key={label} className={`rounded-2xl border p-4 space-y-2 ${bg}`}>
              <div className={`font-bold font-mono text-sm ${color}`}>{label}</div>
              <div>
                <div className="text-[10px] text-zinc-500 uppercase tracking-wider mb-1">Triggers when</div>
                <p className="text-xs text-zinc-400">{trigger}</p>
              </div>
              <div>
                <div className="text-[10px] text-zinc-500 uppercase tracking-wider mb-1">Response</div>
                <p className="text-xs text-zinc-400">{outcome}</p>
              </div>
            </div>
          ))}
        </div>
      </section>

      {/* Yield + admin */}
      <section>
        <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">Vault Tools</div>
        <div className="grid grid-cols-1 sm:grid-cols-3 gap-4">
          <DemoCard
            title="Simulate 30-Day Yield" badge="+0.41%" variant="info"
            description="Calls fastForwardDays(30) on both lending markets, advancing interest as if 30 days passed at 5% APY. Deposit USDC first, then simulate to see share price rise."
            buttonLabel="Fast-forward 30 Days"
            disabled={!canAct}
            onClick={actions.onSimulateYield}
          />
          <DemoCard
            title="Mint 10,000 USDC" variant="default"
            description="Mints 10,000 test USDC to your wallet from the MockUSDC contract. Use this to fund yourself before depositing into the vault."
            buttonLabel="Mint Test USDC"
            disabled={!canAct}
            onClick={actions.onMintUsdc}
          />
          {isPaused && (
            <DemoCard
              title="Unpause Deposits" variant="safe"
              description="Re-enables new deposits. The sentinel pauses deposits automatically on CRITICAL verdict."
              buttonLabel="Unpause Vault Deposits"
              disabled={!canAct}
              onClick={actions.onUnpause}
            />
          )}
        </div>
      </section>

      {/* Flow summary */}
      <section className="rounded-2xl border border-white/[0.06] bg-white/[0.02] p-5">
        <div className="text-sm font-semibold text-zinc-300 mb-3">Complete Demo Flow</div>
        <ol className="space-y-2">
          {[
            'Mint 10,000 USDC and deposit into the vault (click the USDC vault on the Vaults page).',
            'Set CRITICAL Conditions — Market B util raises above 95% with >40% allocation.',
            'In the vault → Risk AI tab: click Run Risk Check (0.25 STT). Wait 1–5 min for Somnia consensus.',
            'Observe: deposits paused + Market B emergency deallocated 50%.',
            'Use Unpause Deposits to restore the vault, then Reset to SAFE.',
            'Click Request AI Rebalance (0.5 STT). LLM picks BALANCED / YIELD_TILT / DEFENSIVE.',
            'Observe: epoch increments, capital redistributed across markets.',
            'Simulate 30-day yield — watch share price increase.',
          ].map((text, i) => (
            <li key={i} className="flex gap-3 text-sm text-zinc-400">
              <span className="flex-shrink-0 w-5 h-5 rounded-full bg-blue-600/15 border border-blue-500/25 flex items-center justify-center text-xs font-bold text-blue-400 mt-0.5">
                {i + 1}
              </span>
              <span className="text-xs">{text}</span>
            </li>
          ))}
        </ol>
      </section>
    </div>
  );
}
