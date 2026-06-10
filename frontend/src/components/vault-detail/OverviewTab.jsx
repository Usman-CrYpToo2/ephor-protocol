import React from 'react';
import { formatBps, formatTime, truncateAddress } from '../../config';

function Section({ title, children }) {
  return (
    <div className="mb-6">
      <div className="text-xs font-medium text-zinc-500 uppercase tracking-wider mb-3">{title}</div>
      <div className="rounded-xl border border-white/[0.06] overflow-hidden">
        {children}
      </div>
    </div>
  );
}

function KV({ label, value, mono, copy }) {
  const [copied, setCopied] = React.useState(false);
  const doCopy = () => {
    navigator.clipboard.writeText(value).then(() => {
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    });
  };
  return (
    <div className="flex items-center justify-between px-4 py-3 border-b border-white/[0.04] last:border-0">
      <span className="text-sm text-zinc-500">{label}</span>
      <div className="flex items-center gap-2">
        <span className={`text-sm text-white ${mono ? 'font-mono' : ''}`}>{value}</span>
        {copy && (
          <button onClick={doCopy} className="text-zinc-600 hover:text-zinc-300 text-xs">
            {copied ? '✓' : '⧉'}
          </button>
        )}
      </div>
    </div>
  );
}

export default function OverviewTab({ data, isLoading, vaultConfig }) {
  if (isLoading || !data) {
    return (
      <div className="space-y-3 animate-pulse">
        {[1,2,3,4,5].map(i => <div key={i} className="h-10 bg-white/[0.03] rounded" />)}
      </div>
    );
  }

  const { vault } = data;

  return (
    <div>
      <Section title="Vault Configuration">
        <KV label="Version"       value="AI (Ephor v1)" />
        <KV label="Chain"         value="Somnia Testnet" />
        <KV label="Vault address" value={truncateAddress(vaultConfig.address)} mono copy={vaultConfig.address} />
        <KV label="Asset"         value={`${vaultConfig.asset} (${vaultConfig.assetDecimals} decimals)`} />
        <KV label="Performance fee" value={`${(vault.performanceFeeBps / 100).toFixed(0)}%`} />
        <KV label="Fee recipient" value={truncateAddress(vault.feeRecipient)} mono copy={vault.feeRecipient} />
      </Section>

      <Section title="Risk Parameters">
        <KV label="Min idle buffer"    value={formatBps(vault.minIdleBufferBps)} />
        <KV label="Max per-market"     value={formatBps(vault.maxMarketBps)} />
        <KV label="Max turnover/epoch" value={formatBps(vault.maxTurnoverBps)} />
        <KV label="Epoch length"       value={vault.rebalanceEpochLength < 120 ? `${vault.rebalanceEpochLength}s` : `${Math.round(vault.rebalanceEpochLength/60)}m`} />
      </Section>

      <Section title="Epoch Status">
        <KV label="Current epoch"   value={`#${vault.currentEpoch}`} mono />
        <KV label="Last rebalance"  value={vault.lastRebalanceTime ? formatTime(vault.lastRebalanceTime) : 'Never'} />
        <KV label="Share price"     value={vault.sharePrice.toFixed(6)} mono />
        <KV label="Total supply"    value={`${vault.totalSupply.toLocaleString()} ${vaultConfig.symbol}`} mono />
        <KV label="Idle buffer"     value={vault.totalAssets < 1 ? '0%' : formatBps(vault.idleBufferBps)} />
      </Section>

      <Section title="Contracts">
        <KV label="Vault"      value={truncateAddress(vaultConfig.address)}   mono copy={vaultConfig.address} />
        <KV label="Sentinel"   value={truncateAddress(vaultConfig.sentinel)}  mono copy={vaultConfig.sentinel} />
        <KV label="Strategist" value={truncateAddress(vaultConfig.strategist)} mono copy={vaultConfig.strategist} />
      </Section>
    </div>
  );
}
