import React, { useState } from 'react';
import { RISK_THEME } from '../../config';

// ── Scenario card ─────────────────────────────────────────────────────────────

function ScenarioCard({ level, title, subtitle, steps, outcome, onRun, busy, disabled }) {
  const theme = RISK_THEME[level];
  return (
    <div className={`rounded-2xl border p-5 space-y-4 ${theme.bg} ${theme.border}`}>
      {/* Header */}
      <div className="flex items-start justify-between gap-3">
        <div>
          <div className="flex items-center gap-2 mb-1">
            <span className={`w-2 h-2 rounded-full flex-shrink-0 ${theme.dot}`} />
            <span className={`text-xs font-bold tracking-wider uppercase ${theme.text}`}>{title}</span>
          </div>
          <p className="text-zinc-400 text-xs leading-relaxed">{subtitle}</p>
        </div>
      </div>

      {/* What it sets up */}
      <div className="space-y-1">
        {steps.map((s, i) => (
          <div key={i} className="flex items-start gap-2 text-xs text-zinc-500">
            <span className="mt-0.5 text-zinc-700">→</span>
            <span>{s}</span>
          </div>
        ))}
      </div>

      {/* Expected outcome */}
      <div className={`rounded-lg px-3 py-2 text-xs font-medium ${theme.bg} border ${theme.border} ${theme.text}`}>
        AI Risk Check will return: <span className="font-bold">{outcome}</span>
      </div>

      {/* Button */}
      <button
        onClick={onRun}
        disabled={busy || disabled}
        className={`w-full py-2.5 rounded-xl text-sm font-semibold transition-colors
          disabled:opacity-40 disabled:cursor-not-allowed
          border ${theme.border} ${theme.text} hover:${theme.bg} bg-black/30`}
      >
        {busy
          ? <span className="flex items-center justify-center gap-2">
              <svg className="animate-spin w-4 h-4" viewBox="0 0 24 24" fill="none">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"/>
              </svg>
              Setting up…
            </span>
          : `Set ${title}`
        }
      </button>
    </div>
  );
}

// ── Utility button ────────────────────────────────────────────────────────────

function UtilCard({ icon, title, description, buttonLabel, onRun, busy }) {
  return (
    <div className="rounded-2xl border border-white/[0.06] bg-white/[0.02] p-5 space-y-3">
      <div className="flex items-center gap-3">
        <span className="text-2xl">{icon}</span>
        <div>
          <div className="text-sm font-medium text-white">{title}</div>
          <div className="text-xs text-zinc-500 mt-0.5">{description}</div>
        </div>
      </div>
      <button
        onClick={onRun}
        disabled={busy}
        className="w-full py-2.5 rounded-xl text-sm font-medium border border-white/[0.08] text-zinc-300
          hover:bg-white/[0.06] hover:text-white transition-colors disabled:opacity-40 disabled:cursor-not-allowed"
      >
        {busy
          ? <span className="flex items-center justify-center gap-2">
              <svg className="animate-spin w-4 h-4" viewBox="0 0 24 24" fill="none">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"/>
              </svg>
              Processing…
            </span>
          : buttonLabel
        }
      </button>
    </div>
  );
}

// ── Main component ────────────────────────────────────────────────────────────

export default function DemoTab({ data, isLoading, isConnected, vaultConfig, actions }) {
  const [busy, setBusy] = useState(null); // which action is running

  const run = async (key, fn) => {
    if (busy) return;
    setBusy(key);
    await fn();
    setBusy(null);
  };

  const asset = vaultConfig?.asset ?? 'Token';

  return (
    <div className="space-y-6">

      {/* Notice banner */}
      <div className="rounded-2xl border border-blue-500/20 bg-blue-500/[0.04] px-5 py-4">
        <div className="flex items-start gap-3">
          <span className="text-blue-400 text-lg mt-0.5">⚡</span>
          <div>
            <div className="text-sm font-medium text-white mb-1">Testnet Demo Mode</div>
            <p className="text-xs text-zinc-400 leading-relaxed">
              Use these controls to set up precise risk scenarios for this vault, then run a live AI risk
              check from the <span className="text-white font-medium">Risk AI</span> tab to see the on-chain
              verdict. Scenario buttons require the deployer wallet (has ALLOCATOR + SENTINEL owner roles).
            </p>
          </div>
        </div>
      </div>

      {/* Scenario setup */}
      <div>
        <div className="flex items-center gap-2 mb-4">
          <span className="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Scenario Setup</span>
          <div className="flex-1 h-px bg-white/[0.06]" />
          <span className="text-xs text-zinc-600">then go to Risk AI → Run Risk Check</span>
        </div>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <ScenarioCard
            level={0}
            title="SAFE"
            subtitle="Deallocates all markets and sets low utilization so both on-chain conditions for SAFE are met."
            steps={[
              'Disable oracle (spot reads)',
              'Deallocate all markets → allocation 0%',
              'Set 20% utilization on both markets',
            ]}
            outcome="SAFE"
            busy={busy === 'safe'}
            disabled={!isConnected || !!busy}
            onRun={() => run('safe', actions.onSetSafe)}
          />

          <ScenarioCard
            level={1}
            title="CAUTION"
            subtitle="Sets 85% utilization on one market, crossing the 80% threshold that triggers a Caution verdict."
            steps={[
              'Disable oracle (spot reads)',
              'Market A → 85% utilization (> 80% threshold)',
              'Market B → 50% utilization',
            ]}
            outcome="CAUTION"
            busy={busy === 'caution'}
            disabled={!isConnected || !!busy}
            onRun={() => run('caution', actions.onSetCaution)}
          />

          <ScenarioCard
            level={2}
            title="CRITICAL"
            subtitle="Allocates 45% of vault to one market and sets 96% utilization — both Critical thresholds hit on the same market."
            steps={[
              'Disable oracle (spot reads)',
              'Reallocate 45% of vault to Market B',
              'Market B → 96% utilization (> 95% threshold)',
            ]}
            outcome="CRITICAL"
            busy={busy === 'critical'}
            disabled={!isConnected || !!busy}
            onRun={() => run('critical', actions.onSetCritical)}
          />
        </div>

        <p className="text-xs text-zinc-700 mt-3 text-center">
          CRITICAL requires util &gt; 95% AND allocation &gt; 40% on the same market simultaneously.
        </p>
      </div>

      {/* Utilities */}
      <div>
        <div className="flex items-center gap-2 mb-4">
          <span className="text-xs font-semibold text-zinc-400 uppercase tracking-wider">Vault Utilities</span>
          <div className="flex-1 h-px bg-white/[0.06]" />
        </div>

        <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
          <UtilCard
            icon="🪙"
            title={`Mint 10,000 ${asset}`}
            description={`Mints 10,000 ${asset} test tokens to your connected wallet for depositing.`}
            buttonLabel={`Mint 10,000 ${asset} to Wallet`}
            busy={busy === 'mint'}
            onRun={() => run('mint', actions.onMintToken)}
          />

          <UtilCard
            icon="📈"
            title="Simulate 30-Day Yield"
            description="Fast-forwards 365 days of compound interest (~5% yield). Prefunds markets with yield buffer to prevent liquidity failures."
            buttonLabel="Simulate Yield (+5%)"
            busy={busy === 'yield'}
            onRun={() => run('yield', actions.onSimulateYield)}
          />
        </div>

        {/* Reset card */}
        <div className="rounded-2xl border border-zinc-700/40 bg-zinc-900/40 p-5 space-y-3">
          <div className="flex items-center gap-3">
            <span className="text-2xl">↺</span>
            <div>
              <div className="text-sm font-medium text-white">Reset to Seed State</div>
              <div className="text-xs text-zinc-500 mt-0.5">
                Restores vault to its initial deployment state — reallocates markets, resets utilization and supply rates.
              </div>
            </div>
          </div>

          <div className="grid grid-cols-3 gap-2 text-xs text-zinc-600 bg-black/20 rounded-xl px-3 py-2">
            <div><span className="text-zinc-400 font-mono">Mkt A</span> · 30% alloc</div>
            <div><span className="text-zinc-400 font-mono">Mkt B</span> · 20% alloc</div>
            <div><span className="text-zinc-400 font-mono">Idle</span> · 50% · 50% cap free</div>
          </div>

          <button
            onClick={() => run('reset', actions.onReset)}
            disabled={!!busy || !isConnected}
            className="w-full py-2.5 rounded-xl text-sm font-medium border border-zinc-600/50 text-zinc-400
              hover:bg-zinc-800/60 hover:text-white hover:border-zinc-500 transition-colors
              disabled:opacity-40 disabled:cursor-not-allowed"
          >
            {busy === 'reset'
              ? <span className="flex items-center justify-center gap-2">
                  <svg className="animate-spin w-4 h-4" viewBox="0 0 24 24" fill="none">
                    <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                    <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8v8H4z"/>
                  </svg>
                  Resetting…
                </span>
              : 'Reset Vault'
            }
          </button>
        </div>
      </div>

      {/* How it works */}
      <div className="rounded-2xl border border-white/[0.06] bg-white/[0.02] p-5">
        <div className="text-xs font-semibold text-zinc-400 uppercase tracking-wider mb-3">How the AI Risk Check Works</div>
        <div className="space-y-2 text-xs text-zinc-500 leading-relaxed">
          <div className="flex gap-2"><span className="text-zinc-700 flex-shrink-0">1.</span><span>VaultSentinel reads on-chain metrics (utilization, allocation, idle buffer) and sends them as a structured prompt to the Somnia LLM (Qwen3-30B).</span></div>
          <div className="flex gap-2"><span className="text-zinc-700 flex-shrink-0">2.</span><span>The on-chain <span className="text-zinc-300">assessOnChain()</span> function computes a deterministic HardLevel. The AI can only escalate, never lower this.</span></div>
          <div className="flex gap-2"><span className="text-zinc-700 flex-shrink-0">3.</span><span>Validators run the LLM with a fixed seed and reach consensus. The platform calls back <span className="text-zinc-300">handleResponse()</span> with the verdict.</span></div>
          <div className="flex gap-2"><span className="text-zinc-700 flex-shrink-0">4.</span><span>CRITICAL triggers <span className="text-zinc-300">pauseDeposits()</span> and a 50% emergency withdrawal from the highest-utilization market.</span></div>
        </div>
      </div>
    </div>
  );
}
