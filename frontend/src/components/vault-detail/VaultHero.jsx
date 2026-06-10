import React from 'react';
import { RISK_THEME, truncateAddress, formatUSDC, formatBps } from '../../config';

function CopyBtn({ text }) {
  const [copied, setCopied] = React.useState(false);
  const copy = (e) => {
    e.preventDefault();
    navigator.clipboard.writeText(text).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  };
  return (
    <button onClick={copy} className="text-zinc-600 hover:text-zinc-300 transition-colors text-xs ml-1">
      {copied ? '✓' : '⧉'}
    </button>
  );
}

function Metric({ label, value, sub, highlight }) {
  return (
    <div>
      <div className="text-xs text-zinc-500 mb-1">{label}</div>
      <div className={`text-xl font-mono font-semibold ${highlight ? 'text-green-400' : 'text-white'}`}>
        {value}
      </div>
      {sub && <div className="text-xs text-zinc-600 mt-0.5">{sub}</div>}
    </div>
  );
}

export default function VaultHero({ data, isLoading, vaultConfig }) {
  if (isLoading || !data) {
    return (
      <div className="space-y-4 animate-pulse">
        <div className="h-10 bg-white/[0.04] rounded w-64" />
        <div className="h-4 bg-white/[0.03] rounded w-96" />
        <div className="grid grid-cols-4 gap-6 mt-4">
          {[1,2,3,4].map(i => <div key={i} className="h-12 bg-white/[0.03] rounded" />)}
        </div>
      </div>
    );
  }

  const { vault, sentinel } = data;
  const riskTheme = RISK_THEME[sentinel.latestLevel] || RISK_THEME[0];

  return (
    <div>
      {/* Vault name + badge */}
      <div className="flex items-center gap-3 mb-3">
        <h1 className="text-3xl font-bold text-white">{vaultConfig.name}</h1>
        <span className="px-2 py-0.5 rounded-md bg-blue-600/20 border border-blue-500/30 text-blue-400 text-xs font-bold">AI</span>
      </div>

      {/* Chips row */}
      <div className="flex flex-wrap items-center gap-2 mb-3 text-xs">
        <span className="flex items-center gap-1 px-2.5 py-1 rounded-full border border-white/[0.08] text-zinc-400 font-mono">
          {truncateAddress(vaultConfig.address)}
          <CopyBtn text={vaultConfig.address} />
        </span>
        <span className="px-2.5 py-1 rounded-full border border-white/[0.08] text-zinc-400">Somnia Testnet</span>
        <span className="px-2.5 py-1 rounded-full border border-white/[0.08] text-zinc-400">Ephor AI</span>
        <span className="px-2.5 py-1 rounded-full border border-white/[0.08] text-zinc-400">{vaultConfig.asset}</span>
        <span className={`flex items-center gap-1 px-2.5 py-1 rounded-full border ${riskTheme.border} ${riskTheme.text} ${riskTheme.bg}`}>
          <span className={`w-1.5 h-1.5 rounded-full ${riskTheme.dot}`} />
          {riskTheme.label}
        </span>
      </div>

      {/* Description */}
      <p className="text-sm text-zinc-500 mb-6 max-w-2xl leading-relaxed">
        {vaultConfig.description}
      </p>

      {/* 4 metrics */}
      <div className="grid grid-cols-4 gap-6">
        <Metric
          label="Total Deposits"
          value={`$${formatUSDC(vault.totalAssets)}`}
          sub={`${formatUSDC(vault.totalAssets)} ${vaultConfig.asset}`}
        />
        <Metric
          label="Liquidity"
          value={`$${formatUSDC(vault.idleAmt)}`}
          sub={`${formatUSDC(vault.idleAmt)} ${vaultConfig.asset}`}
        />
        <Metric
          label="Exposure"
          value={`${vault.totalAssets < 1 ? 0 : data.markets.filter(m => m.allocationBps > 0).length} markets`}
          sub={`${formatBps(vault.maxMarketBps)} max/market`}
        />
        <Metric
          label="Net APY"
          value={`${vault.netApy.toFixed(2)}%`}
          sub="weighted average"
          highlight
        />
      </div>
    </div>
  );
}
