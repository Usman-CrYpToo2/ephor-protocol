import React, { useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { useVaultList } from '../hooks/useVaultList';
import { RISK_THEME } from '../config';

// ── Helpers ───────────────────────────────────────────────────────────────────

function fmt(amount, decimals = 2) {
  if (amount === null || amount === undefined) return '—';
  if (amount >= 1_000_000) return (amount / 1_000_000).toFixed(1) + 'M';
  if (amount >= 1_000)     return amount.toLocaleString('en-US', { maximumFractionDigits: decimals });
  return amount.toFixed(decimals);
}

function RiskDot({ level }) {
  if (level === null || level === undefined) return <span className="text-zinc-600 text-xs">—</span>;
  const theme = RISK_THEME[level] || RISK_THEME[0];
  return (
    <span className={`inline-flex items-center gap-1 text-xs font-mono font-semibold ${theme.text}`}>
      <span className={`w-1.5 h-1.5 rounded-full ${theme.dot}`} />
      {theme.label}
    </span>
  );
}

// Colored token badge — no emojis, looks clean
const ASSET_STYLE = {
  USDC: { bg: 'bg-blue-500/15 border-blue-500/25',   text: 'text-blue-300',   label: 'USDC' },
  WETH: { bg: 'bg-indigo-500/15 border-indigo-500/25', text: 'text-indigo-300', label: 'ETH'  },
  WBTC: { bg: 'bg-orange-500/15 border-orange-500/25', text: 'text-orange-300', label: 'BTC'  },
};

function AssetBadge({ asset }) {
  const s = ASSET_STYLE[asset] || { bg: 'bg-zinc-700/30 border-zinc-600/30', text: 'text-zinc-400', label: asset };
  return (
    <div className={`w-8 h-8 rounded-full border flex items-center justify-center text-[9px] font-bold ${s.bg} ${s.text}`}>
      {s.label}
    </div>
  );
}

// Show token amount + symbol (never fake USD for non-stablecoins)
function Amount({ amount, asset, assetDecimals }) {
  if (amount === null || amount === undefined) return <span className="text-zinc-600 text-sm">—</span>;

  // Only show "$" for stablecoins
  const isStable = asset === 'USDC' || asset === 'USDT' || asset === 'DAI';
  const prefix   = isStable ? '$' : '';
  const decimals = asset === 'WBTC' ? 4 : asset === 'WETH' ? 3 : 0;

  return (
    <div>
      <div className="text-sm text-white font-mono">{prefix}{fmt(amount, decimals)}</div>
      <div className="text-xs text-zinc-500 mt-0.5">{fmt(amount, decimals)} {asset}</div>
    </div>
  );
}

// ── Vault row ─────────────────────────────────────────────────────────────────

function VaultRow({ vault, onClick }) {
  const isLive = !vault.comingSoon && vault.address;

  return (
    <tr
      onClick={isLive ? onClick : undefined}
      className={`border-b border-white/[0.04] transition-colors
        ${isLive ? 'hover:bg-white/[0.03] cursor-pointer' : 'opacity-40 cursor-default'}`}
    >
      {/* Star */}
      <td className="pl-6 pr-2 py-4 w-8">
        <button onClick={e => e.stopPropagation()} className="text-zinc-700 hover:text-amber-400 transition-colors text-sm">
          ☆
        </button>
      </td>

      {/* Vault name + badge */}
      <td className="px-4 py-4">
        <div className="flex items-center gap-3">
          <AssetBadge asset={vault.asset} />
          <div>
            <div className="flex items-center gap-2">
              <span className="text-white font-medium text-sm">{vault.name}</span>
              {isLive ? (
                <span className="text-[10px] font-bold px-1.5 py-0.5 rounded bg-blue-600/20 border border-blue-500/30 text-blue-400">AI</span>
              ) : (
                <span className="text-[10px] font-bold px-1.5 py-0.5 rounded bg-zinc-800 border border-white/[0.06] text-zinc-500">Soon</span>
              )}
            </div>
            <div className="text-xs text-zinc-500 mt-0.5">{vault.symbol} · Somnia</div>
          </div>
        </div>
      </td>

      {/* Deposits */}
      <td className="px-4 py-4">
        {isLive && vault.totalAssets !== null
          ? <Amount amount={vault.totalAssets} asset={vault.asset} assetDecimals={vault.assetDecimals} />
          : <span className="text-zinc-600 text-sm">—</span>}
      </td>

      {/* Liquidity */}
      <td className="px-4 py-4">
        {isLive && vault.liquidity !== null
          ? <Amount amount={vault.liquidity} asset={vault.asset} assetDecimals={vault.assetDecimals} />
          : <span className="text-zinc-600 text-sm">—</span>}
      </td>

      {/* Curator + risk */}
      <td className="px-4 py-4">
        <div className="flex items-center gap-2">
          <div className="w-5 h-5 rounded-full bg-blue-600/20 border border-blue-500/30 flex items-center justify-center text-[9px] font-bold text-blue-400">E</div>
          <div>
            <div className="text-xs text-white">Ephor AI</div>
            {isLive && <RiskDot level={vault.level} />}
          </div>
        </div>
      </td>

      {/* APY */}
      <td className="px-4 pr-6 py-4 text-right">
        {isLive && vault.netApy !== null
          ? <span className="text-green-400 font-mono font-semibold">{vault.netApy.toFixed(2)}%</span>
          : <span className="text-zinc-600 text-sm">—</span>}
      </td>
    </tr>
  );
}

// ── Page ──────────────────────────────────────────────────────────────────────

export default function VaultListPage() {
  const navigate = useNavigate();
  const { vaults, isLoading } = useVaultList();
  const [assetFilter, setAssetFilter] = useState('All');
  const [search, setSearch] = useState('');

  // Total deposits — only USDC is a stablecoin so meaningful in $
  const usdcVault = vaults?.find(v => v.asset === 'USDC' && !v.comingSoon);
  const totalDepositsLabel = usdcVault?.totalAssets
    ? `$${fmt(usdcVault.totalAssets, 0)} USDC · ${vaults.filter(v => !v.comingSoon).length} vaults`
    : '—';

  const filtered = (vaults || []).filter(v => {
    if (assetFilter !== 'All' && v.asset !== assetFilter) return false;
    if (search && !v.name.toLowerCase().includes(search.toLowerCase())) return false;
    return true;
  });

  return (
    <div className="max-w-7xl mx-auto px-6 py-8">
      {/* Page header */}
      <div className="flex items-start justify-between mb-6">
        <div>
          <h1 className="text-2xl font-semibold text-white">Vaults</h1>
          <p className="text-sm text-zinc-500 mt-1">AI-monitored yield vaults on Somnia Network</p>
        </div>
        <div className="text-right">
          <div className="text-xs text-zinc-500 uppercase tracking-wider mb-1">Total Deposits</div>
          <div className="text-lg font-mono font-semibold text-white">
            {isLoading ? '…' : totalDepositsLabel}
          </div>
        </div>
      </div>

      {/* Filter bar */}
      <div className="flex items-center justify-between mb-4 gap-4">
        <div className="flex items-center gap-1">
          {['All', 'USDC', 'WETH', 'WBTC'].map(f => (
            <button
              key={f}
              onClick={() => setAssetFilter(f)}
              className={`px-3 py-1.5 rounded-lg text-sm transition-colors
                ${assetFilter === f ? 'bg-white/[0.08] text-white' : 'text-zinc-500 hover:text-white hover:bg-white/[0.04]'}`}
            >
              {f}
            </button>
          ))}
        </div>
        <input
          type="text"
          placeholder="Search vaults…"
          value={search}
          onChange={e => setSearch(e.target.value)}
          className="px-3 py-1.5 rounded-lg border border-white/[0.08] bg-white/[0.03] text-sm text-white placeholder-zinc-600 outline-none focus:border-white/[0.15] w-52"
        />
      </div>

      {/* Table */}
      <div className="rounded-2xl border border-white/[0.06] overflow-hidden">
        <table className="w-full">
          <thead>
            <tr className="border-b border-white/[0.06]">
              <th className="pl-6 pr-2 py-3 w-8" />
              <th className="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Vault</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Deposits</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Liquidity</th>
              <th className="px-4 py-3 text-left text-xs font-medium text-zinc-500 uppercase tracking-wider">Curator</th>
              <th className="px-4 pr-6 py-3 text-right text-xs font-medium text-zinc-500 uppercase tracking-wider">APY</th>
            </tr>
          </thead>
          <tbody>
            {isLoading ? (
              Array.from({ length: 3 }).map((_, i) => (
                <tr key={i} className="border-b border-white/[0.04]">
                  {[1,2,3,4,5,6].map(j => (
                    <td key={j} className="px-4 py-4">
                      <div className="h-4 bg-white/[0.04] rounded animate-pulse" />
                    </td>
                  ))}
                </tr>
              ))
            ) : filtered.length === 0 ? (
              <tr>
                <td colSpan={6} className="px-6 py-12 text-center text-zinc-600">No vaults found.</td>
              </tr>
            ) : (
              filtered.map(v => (
                <VaultRow
                  key={v.address || v.name}
                  vault={v}
                  onClick={() => v.address && navigate(`/vault/${v.address}`)}
                />
              ))
            )}
          </tbody>
        </table>
      </div>

      <p className="text-xs text-zinc-700 text-center mt-6">
        Ephor Protocol · Built on Somnia Network · Encode Club Agentathon
      </p>
    </div>
  );
}
