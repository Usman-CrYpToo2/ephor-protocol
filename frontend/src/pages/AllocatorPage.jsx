import React, { useState, useEffect } from 'react';
import { ALLOCATION_MODES, REBALANCE_DEPOSIT, REBALANCE_COOLDOWN, formatUSDC, formatBps, formatTime, formatCountdown } from '../config';

// ── Live cooldown countdown ───────────────────────────────────────────────────

function useCooldown(lastRequestAt) {
  const [left, setLeft] = useState(0);

  useEffect(() => {
    const calc = () => {
      const elapsed = Math.floor(Date.now() / 1000) - (lastRequestAt || 0);
      setLeft(Math.max(0, REBALANCE_COOLDOWN - elapsed));
    };
    calc();
    const t = setInterval(calc, 1000);
    return () => clearInterval(t);
  }, [lastRequestAt]);

  return left;
}

// ── Allocation mode badge ─────────────────────────────────────────────────────

function ModeBadge({ mode }) {
  const m = ALLOCATION_MODES[mode] ?? ALLOCATION_MODES[0];
  return (
    <span className={`inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs font-bold border
      ${mode === 1
        ? 'text-violet-400 bg-violet-500/10 border-violet-500/25'
        : 'text-indigo-400 bg-indigo-500/10 border-indigo-500/25'}`}>
      <span className="w-1.5 h-1.5 rounded-full bg-current" />
      {m.label} · {m.sub}
    </span>
  );
}

// ── Status card ───────────────────────────────────────────────────────────────

function StatusCard({ data, isLoading }) {
  const s       = data?.strategist;
  const v       = data?.vault;
  const cooldown = useCooldown(s?.lastRequestAt);

  const epochLength = v?.rebalanceEpochLength ?? 3600;
  const sinceRebal  = v?.lastRebalanceTime
    ? Math.floor(Date.now() / 1000) - v.lastRebalanceTime
    : null;
  const epochReady  = sinceRebal !== null ? sinceRebal >= epochLength : true;

  const stats = [
    { label: 'Allocation Mode', value: s ? <ModeBadge mode={s.allocationMode} /> : null },
    { label: 'Current Epoch',   value: <span className="text-white font-mono font-bold">{v?.currentEpoch ?? 0}</span>, sub: 'increments on every rebalance' },
    { label: 'Last Rebalance',  value: <span className="text-white font-mono">{v?.lastRebalanceTime ? formatTime(v.lastRebalanceTime) : 'Never'}</span>, sub: epochReady ? 'epoch window open' : `next in ${formatCountdown(epochLength - sinceRebal)}` },
    { label: 'Total Rebalances', value: <span className="text-white font-mono font-bold">{s?.rebalanceCount ?? 0}</span> },
  ];

  return (
    <div className="glass-card rounded-2xl p-5">
      <div className="flex items-center gap-2 mb-5">
        <div className="w-7 h-7 rounded-lg bg-violet-500/15 border border-violet-500/25 flex items-center justify-center">
          <svg className="w-3.5 h-3.5 text-violet-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
            <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>
            <polyline points="3.27 6.96 12 12.01 20.73 6.96"/>
            <line x1="12" y1="22.08" x2="12" y2="12"/>
          </svg>
        </div>
        <span className="font-semibold text-white">AllocationStrategist</span>
        {s?.isPending && (
          <span className="ml-auto flex items-center gap-1.5 text-xs text-blue-400">
            <svg className="w-3.5 h-3.5 animate-spin" fill="none" viewBox="0 0 24 24">
              <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
              <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
            </svg>
            AI Running
          </span>
        )}
      </div>

      {isLoading ? (
        <div className="grid grid-cols-2 gap-3">
          {[1,2,3,4].map(i => <div key={i} className="h-16 bg-slate-800/60 rounded-xl animate-pulse" />)}
        </div>
      ) : (
        <div className="grid grid-cols-2 sm:grid-cols-4 gap-3">
          {stats.map(st => (
            <div key={st.label} className="bg-slate-800/40 rounded-xl p-3">
              <div className="text-[10px] text-slate-600 uppercase tracking-wide mb-1.5">{st.label}</div>
              {st.value}
              {st.sub && <div className={`text-[10px] mt-1 ${epochReady && st.label === 'Last Rebalance' ? 'text-emerald-500' : 'text-slate-600'}`}>{st.sub}</div>}
            </div>
          ))}
        </div>
      )}

      {/* Cooldown bar */}
      {!isLoading && s?.lastRequestAt > 0 && (
        <div className="mt-4">
          <div className="flex justify-between text-xs text-slate-600 mb-1.5">
            <span>Cooldown (5 min between requests)</span>
            <span className={cooldown > 0 ? 'text-amber-400' : 'text-emerald-400'}>
              {cooldown > 0 ? formatCountdown(cooldown) : 'Ready'}
            </span>
          </div>
          <div className="h-1 bg-slate-800 rounded-full overflow-hidden">
            <div
              className={`h-full rounded-full transition-all duration-1000 ${cooldown > 0 ? 'bg-amber-500' : 'bg-emerald-500'}`}
              style={{ width: `${Math.round((1 - cooldown / REBALANCE_COOLDOWN) * 100)}%` }}
            />
          </div>
        </div>
      )}
    </div>
  );
}

// ── Market allocation cards ───────────────────────────────────────────────────

function MarketAllocationCard({ market, totalAssets, isLoading }) {
  if (isLoading) {
    return <div className="glass-card rounded-2xl p-5 animate-pulse"><div className="h-32 bg-slate-800/40 rounded-xl" /></div>;
  }

  const util     = market.utilizationBps;
  const allocBps = market.allocationBps;
  const rate     = market.supplyRateBps;
  const apy      = rate ? ((Math.pow(1 + rate / 1e4 / 365, 365) - 1) * 100).toFixed(2) : null;

  const utilColor  = util >= 9500 ? 'bg-red-500' : util >= 8000 ? 'bg-amber-500' : 'bg-emerald-500';
  const utilText   = util >= 9500 ? 'text-red-400' : util >= 8000 ? 'text-amber-400' : 'text-emerald-400';
  const allocColor = allocBps >= 4000 ? 'bg-red-500' : allocBps >= 2500 ? 'bg-amber-500' : 'bg-indigo-500';
  const allocText  = allocBps >= 4000 ? 'text-red-400' : allocBps >= 2500 ? 'text-amber-400' : 'text-indigo-400';

  return (
    <div className={`glass-card rounded-2xl p-5 ${util >= 9500 && allocBps >= 4000 ? 'border-red-500/20' : ''}`}>
      <div className="flex items-center justify-between mb-4">
        <div className="flex items-center gap-2">
          <div className="w-7 h-7 rounded-lg bg-blue-500/15 border border-blue-500/25 flex items-center justify-center">
            <svg className="w-3.5 h-3.5 text-blue-400" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="2">
              <line x1="18" y1="20" x2="18" y2="10"/>
              <line x1="12" y1="20" x2="12" y2="4"/>
              <line x1="6"  y1="20" x2="6"  y2="14"/>
            </svg>
          </div>
          <span className="font-semibold text-white">{market.name}</span>
        </div>
        {apy && (
          <span className="text-xs font-mono font-bold text-emerald-400 bg-emerald-500/10 border border-emerald-500/20 px-2 py-0.5 rounded-full">
            {apy}% APY
          </span>
        )}
      </div>

      <div className="text-2xl font-bold font-mono text-white mb-1">${formatUSDC(market.balance)}</div>
      <div className="text-xs text-slate-500 mb-4">USDC deployed</div>

      <div className="space-y-3">
        <div>
          <div className="flex justify-between text-xs mb-1.5">
            <span className="text-slate-500">Utilization</span>
            <span className={`font-mono font-semibold ${utilText}`}>{formatBps(util)}</span>
          </div>
          <div className="h-2 bg-slate-800 rounded-full overflow-hidden">
            <div className={`h-full rounded-full util-bar-fill ${utilColor}`} style={{ width: `${Math.min(util / 100, 100)}%` }} />
          </div>
          <div className="flex justify-between text-[10px] text-slate-700 mt-1">
            <span>Safe &lt;80%</span><span>Caution 80–95%</span><span>Critical &gt;95%</span>
          </div>
        </div>

        <div>
          <div className="flex justify-between text-xs mb-1.5">
            <span className="text-slate-500">Vault Allocation</span>
            <span className={`font-mono font-semibold ${allocText}`}>{formatBps(allocBps)}</span>
          </div>
          <div className="h-2 bg-slate-800 rounded-full overflow-hidden">
            <div className={`h-full rounded-full util-bar-fill ${allocColor}`} style={{ width: `${Math.min(allocBps / 100, 100)}%` }} />
          </div>
          <div className="flex justify-between text-[10px] text-slate-700 mt-1">
            <span>Safe &lt;25%</span><span>Caution 25–40%</span><span>Critical &gt;40%</span>
          </div>
        </div>

        {rate > 0 && (
          <div className="flex justify-between items-center pt-1">
            <span className="text-xs text-slate-500">Supply Rate</span>
            <span className="text-xs font-mono text-slate-300">{formatBps(rate)} p.a.</span>
          </div>
        )}
      </div>
    </div>
  );
}

// ── Allocation distribution bar ───────────────────────────────────────────────

function AllocationBar({ data, isLoading }) {
  const vault   = data?.vault;
  const markets = data?.markets ?? [];
  const total   = vault?.totalAssets ?? 0;

  if (isLoading || total === 0) {
    return <div className="glass-card rounded-2xl p-5"><div className="h-12 bg-slate-800/60 rounded-xl animate-pulse" /></div>;
  }

  const idlePct = vault?.idleBufferBps ? vault.idleBufferBps / 100 : 0;
  const segments = [
    ...markets.map(m => ({
      label: m.name,
      pct:   m.allocationBps / 100,
      color: 'bg-indigo-500',
      textColor: 'text-indigo-400',
    })),
    { label: 'Idle Cash', pct: idlePct, color: 'bg-slate-600', textColor: 'text-slate-400' },
  ].filter(s => s.pct > 0);

  return (
    <div className="glass-card rounded-2xl p-5">
      <div className="flex items-center justify-between mb-4">
        <span className="font-semibold text-white">Capital Distribution</span>
        <span className="text-xs text-slate-500 font-mono">${formatUSDC(total)} total</span>
      </div>

      {/* Segmented bar */}
      <div className="flex h-5 rounded-full overflow-hidden gap-0.5 mb-4">
        {segments.map((seg, i) => (
          <div
            key={i}
            className={`${seg.color} util-bar-fill flex-shrink-0`}
            style={{ width: `${seg.pct}%` }}
            title={`${seg.label}: ${seg.pct.toFixed(1)}%`}
          />
        ))}
      </div>

      {/* Legend */}
      <div className="flex flex-wrap gap-4">
        {segments.map((seg, i) => (
          <div key={i} className="flex items-center gap-1.5">
            <span className={`w-2.5 h-2.5 rounded-sm ${seg.color}`} />
            <span className="text-xs text-slate-400">{seg.label}</span>
            <span className={`text-xs font-mono font-bold ${seg.textColor}`}>{seg.pct.toFixed(1)}%</span>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── Trigger card ─────────────────────────────────────────────────────────────

function TriggerCard({ data, isConnected, onRequestRebalance }) {
  const s        = data?.strategist;
  const v        = data?.vault;
  const cooldown = useCooldown(s?.lastRequestAt);

  const epochLength = v?.rebalanceEpochLength ?? 3600;
  const sinceRebal  = v?.lastRebalanceTime
    ? Math.floor(Date.now() / 1000) - v.lastRebalanceTime
    : epochLength;
  const epochReady  = sinceRebal >= epochLength;

  const isPending  = s?.isPending;
  const onCooldown = cooldown > 0 && (s?.lastRequestAt ?? 0) > 0;
  const canTrigger = isConnected && !isPending && !onCooldown && epochReady;

  let btnLabel = 'Request AI Rebalance';
  if (isPending)       btnLabel = 'AI Rebalance Running…';
  else if (onCooldown) btnLabel = `Cooldown — ${formatCountdown(cooldown)}`;
  else if (!epochReady) btnLabel = `Epoch window — ${formatCountdown(epochLength - sinceRebal)}`;

  const modeInfo = ALLOCATION_MODES[s?.allocationMode ?? 0];

  return (
    <div className="glass-card rounded-2xl p-6">
      <div className="text-xs font-medium text-slate-500 uppercase tracking-wider mb-4">Request AI Rebalance</div>

      <div className="flex flex-col sm:flex-row items-start sm:items-center gap-4 mb-5">
        <div className="flex-1">
          <p className="text-sm text-slate-300 leading-relaxed">
            Sends live vault metrics to Somnia's LLM. The AI picks an allocation strategy,
            which AllocationProjection converts into cap-respecting target amounts.
            <span className="text-slate-500"> vault.reallocate() executes atomically in the callback.</span>
          </p>
          <div className="flex flex-wrap items-center gap-3 mt-3 text-xs text-slate-600">
            <span>Cost: {REBALANCE_DEPOSIT} STT</span>
            <span>·</span>
            {s && <ModeBadge mode={s.allocationMode} />}
            <span>·</span>
            <span>{modeInfo?.desc.split(';')[0]}</span>
          </div>
        </div>
        <button
          onClick={onRequestRebalance}
          disabled={!canTrigger}
          className="flex-shrink-0 px-6 py-3 rounded-xl bg-violet-600 hover:bg-violet-500 disabled:opacity-40 disabled:cursor-not-allowed text-white font-semibold text-sm transition-all shadow-lg shadow-violet-500/20 hover:shadow-violet-500/30 whitespace-nowrap"
        >
          {isPending ? (
            <span className="flex items-center gap-2">
              <svg className="w-4 h-4 animate-spin" fill="none" viewBox="0 0 24 24">
                <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4"/>
                <path className="opacity-75" fill="currentColor" d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4z"/>
              </svg>
              {btnLabel}
            </span>
          ) : btnLabel}
        </button>
      </div>

      {/* What AI sees */}
      {data?.markets && (
        <div className="bg-slate-900/60 border border-slate-800 rounded-xl p-4">
          <div className="text-[10px] text-slate-600 uppercase tracking-wider mb-2">AI Will Analyze</div>
          <div className="grid grid-cols-2 sm:grid-cols-4 gap-3 text-xs">
            {[
              { label: 'Total Assets', value: `$${formatUSDC(v?.totalAssets)}` },
              { label: 'Idle Buffer',  value: formatBps(v?.idleBufferBps) },
              ...data.markets.map(m => ({
                label: `${m.name} Util`, value: formatBps(m.utilizationBps),
              })),
            ].map(item => (
              <div key={item.label}>
                <div className="text-slate-600 mb-0.5">{item.label}</div>
                <div className="font-mono font-semibold text-slate-300">{item.value}</div>
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

// ── Strategy outcomes reference ───────────────────────────────────────────────

function StrategyReference() {
  const strategies = [
    {
      label: 'BALANCED',
      color: 'text-indigo-400',
      bg: 'bg-indigo-500/8 border-indigo-500/20',
      trigger: 'Markets healthy, rates similar.',
      outcome: 'Equal weight per market. Capital split proportionally.',
    },
    {
      label: 'YIELD_TILT',
      color: 'text-emerald-400',
      bg: 'bg-emerald-500/8 border-emerald-500/20',
      trigger: 'All markets healthy, meaningful rate difference.',
      outcome: 'Weights proportional to utilization. More capital to higher-rate market.',
    },
    {
      label: 'DEFENSIVE',
      color: 'text-amber-400',
      bg: 'bg-amber-500/8 border-amber-500/20',
      trigger: 'At least one market near caution threshold.',
      outcome: 'Inverse-util weights. Pull back from high-utilization markets.',
    },
    {
      label: 'DERISK',
      color: 'text-red-400',
      bg: 'bg-red-500/8 border-red-500/20',
      trigger: 'Multiple markets at caution or above.',
      outcome: 'All-zero weights. Everything stays idle. No vault movement.',
    },
  ];

  return (
    <div className="glass-card rounded-2xl overflow-hidden">
      <div className="px-5 py-4 border-b border-slate-800/60">
        <span className="font-semibold text-white">Strategy Reference</span>
        <span className="ml-2 text-xs text-slate-500">Tier 1 · inferString labels</span>
      </div>
      <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-0 divide-x divide-y divide-slate-800/60">
        {strategies.map(s => (
          <div key={s.label} className={`p-4 space-y-2 ${s.bg}`}>
            <div className={`font-bold font-mono text-sm ${s.color}`}>{s.label}</div>
            <div>
              <div className="text-[10px] text-slate-600 uppercase tracking-wider mb-1">Triggers when</div>
              <p className="text-xs text-slate-400 leading-relaxed">{s.trigger}</p>
            </div>
            <div>
              <div className="text-[10px] text-slate-600 uppercase tracking-wider mb-1">Outcome</div>
              <p className="text-xs text-slate-400 leading-relaxed">{s.outcome}</p>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── How it works ──────────────────────────────────────────────────────────────

function HowItWorks({ mode }) {
  const tier1Steps = [
    'requestRebalance() snapshots vault metrics: totalAssets, idleBuffer, per-market allocationBps and utilizationBps.',
    'A single inferString call sends a feature-block prompt to Somnia\'s LLM (Qwen3-30B, temp=0).',
    'Validators reach consensus on one label: BALANCED / YIELD_TILT / DEFENSIVE / DERISK.',
    'handleResponse() maps the label to per-market weights via AllocationProjection.',
    'vault.reallocate() executes atomically — caps, turnover limits, and idle floor all enforced on-chain.',
  ];

  const tier2Steps = [
    'requestRebalance() issues N separate inferNumber calls — one per market — each describing that market\'s conditions.',
    'Each validator independently scores every market 0–10000 (higher = more attractive).',
    'As callbacks arrive, scores are stored. When all N arrive, scores normalize to portfolio weights.',
    'AllocationProjection converts weights to cap-respecting target amounts for each market.',
    'vault.reallocate() executes with the computed targets. Epoch increments on success.',
  ];

  const steps = mode === 1 ? tier2Steps : tier1Steps;

  return (
    <div className="glass-card rounded-2xl p-5">
      <div className="flex items-center gap-3 mb-4">
        <span className="font-semibold text-white">How It Works</span>
        <ModeBadge mode={mode ?? 0} />
      </div>
      <ol className="space-y-3">
        {steps.map((text, i) => (
          <li key={i} className="flex gap-3 text-sm text-slate-400">
            <span className="flex-shrink-0 w-5 h-5 rounded-full bg-violet-500/15 border border-violet-500/25 flex items-center justify-center text-xs font-bold text-violet-400 mt-0.5">
              {i + 1}
            </span>
            <span className="leading-relaxed">{text}</span>
          </li>
        ))}
      </ol>
    </div>
  );
}

// ── Allocator page ────────────────────────────────────────────────────────────

export default function AllocatorPage({ data, isLoading, isConnected, onRequestRebalance }) {
  const markets = data?.markets ?? [];
  const mode    = data?.strategist?.allocationMode ?? 0;

  return (
    <div className="space-y-5">
      <div>
        <h2 className="text-xl font-bold text-white mb-1">AI Allocator</h2>
        <p className="text-sm text-slate-500">
          AllocationStrategist queries Somnia's on-chain LLM to determine optimal capital
          distribution across lending markets. Weights flow through AllocationProjection
          and execute via vault.reallocate() — all on-chain, no trusted intermediary.
        </p>
      </div>

      <StatusCard data={data} isLoading={isLoading} />

      <AllocationBar data={data} isLoading={isLoading} />

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-5">
        {isLoading
          ? [0, 1].map(i => <MarketAllocationCard key={i} isLoading />)
          : markets.map(m => (
              <MarketAllocationCard
                key={m.address}
                market={m}
                totalAssets={data?.vault?.totalAssets}
                isLoading={false}
              />
            ))}
      </div>

      <TriggerCard
        data={data}
        isConnected={isConnected}
        onRequestRebalance={onRequestRebalance}
      />

      <StrategyReference />

      <HowItWorks mode={mode} />
    </div>
  );
}
