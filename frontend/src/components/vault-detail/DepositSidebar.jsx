import React, { useState, useRef } from 'react';
import { formatUSDC } from '../../config';

function Row({ label, value, highlight }) {
  return (
    <div className="flex items-center justify-between py-2 border-b border-white/[0.04]">
      <span className="text-xs text-zinc-500">{label}</span>
      <span className={`text-xs font-mono ${highlight ? 'text-green-400' : 'text-white'}`}>{value}</span>
    </div>
  );
}

export default function DepositSidebar({
  data, isLoading, isConnected, vaultConfig, walletProps, actions,
}) {
  const [mode, setMode]     = useState('deposit');
  const [amount, setAmount] = useState('');
  const [busy, setBusy]     = useState(false);
  const [shake, setShake]   = useState(false);
  const shakeTimer = useRef(null);

  const { onConnect } = walletProps;

  const vault      = data?.vault;
  const user       = data?.user;
  const isPaused   = vault?.depositsPaused;
  const apy        = vault?.netApy ?? 0;
  const maxDeposit = vault?.maxDeposit ?? null;
  const isAtCap    = maxDeposit !== null && maxDeposit <= 0;

  const amountNum    = parseFloat(amount) || 0;
  const sharePrice   = vault?.sharePrice ?? 1;
  const previewShares = amountNum / sharePrice;
  const previewAsset  = amountNum * sharePrice;
  const monthly      = amountNum * apy / 100 / 12;
  const yearly       = amountNum * apy / 100;

  const maxShares  = user ? Math.floor(user.shares * 100) / 100 : null;
  const exceedsMax = amountNum > 0 && (
    (mode === 'deposit'  && maxDeposit !== null && amountNum > maxDeposit) ||
    (mode === 'withdraw' && maxShares  !== null && amountNum > maxShares)
  );

  const triggerShake = () => {
    clearTimeout(shakeTimer.current);
    setShake(true);
    shakeTimer.current = setTimeout(() => setShake(false), 500);
  };

  const handleAmountChange = (e) => {
    const raw = e.target.value;
    const num = parseFloat(raw);

    if (mode === 'deposit' && maxDeposit !== null && num > maxDeposit) {
      setAmount(String(maxDeposit));
      triggerShake();
      return;
    }

    const maxShares = user ? Math.floor(user.shares * 100) / 100 : null;
    if (mode === 'withdraw' && maxShares !== null && num > maxShares) {
      setAmount(String(maxShares));
      triggerShake();
      return;
    }

    setAmount(raw);
  };

  const setMax = () => {
    if (!user) return;
    if (mode === 'deposit') {
      const bal = Math.floor(user.assetBalance);
      const cap = maxDeposit !== null ? Math.floor(maxDeposit) : bal;
      setAmount(String(Math.min(bal, cap)));
    } else {
      setAmount(String(maxShares ?? 0));
    }
  };

  const handleDeposit = async () => {
    if (!amountNum) return;
    setBusy(true);
    await actions.onDeposit(amount);
    setBusy(false);
    setAmount('');
  };

  const handleWithdraw = async () => {
    if (!amountNum) return;
    setBusy(true);
    await actions.onWithdraw(amount);
    setBusy(false);
    setAmount('');
  };

  return (
    <div className="rounded-2xl border border-white/[0.08] bg-white/[0.02] p-5 space-y-4">
      {/* Header */}
      <div className="flex items-center justify-between">
        <span className="text-sm font-medium text-white">
          {mode === 'deposit' ? `Deposit ${vaultConfig?.asset ?? 'USDC'}` : 'Withdraw'}
        </span>
        <span className="text-zinc-600 text-xs cursor-help" title="ERC-4626 vault">ⓘ</span>
      </div>

      {/* Mode toggle */}
      <div className="flex rounded-lg border border-white/[0.06] overflow-hidden">
        {['deposit', 'withdraw'].map(m => (
          <button
            key={m}
            onClick={() => { setMode(m); setAmount(''); }}
            className={`flex-1 py-1.5 text-xs font-medium capitalize transition-colors
              ${mode === m ? 'bg-white/[0.08] text-white' : 'text-zinc-500 hover:text-zinc-300'}`}
          >
            {m}
          </button>
        ))}
      </div>

      {/* Amount input */}
      <div>
        <div
          className={`relative flex items-center rounded-xl border px-3 py-2.5 transition-colors
            ${exceedsMax || shake
              ? 'border-red-500/70 bg-red-500/[0.06]'
              : 'border-white/[0.08] bg-white/[0.03]'}
            ${shake ? 'animate-shake' : ''}`}
        >
          <input
            type="number"
            placeholder="0.00"
            value={amount}
            onChange={handleAmountChange}
            className={`flex-1 bg-transparent text-xl font-mono outline-none placeholder-zinc-700
              ${exceedsMax || shake ? 'text-red-400' : 'text-white'}`}
          />
          <div className="flex items-center gap-2">
            <span className="text-xs text-zinc-500">{mode === 'deposit' ? vaultConfig?.asset : vaultConfig?.symbol}</span>
            <button onClick={setMax} className="text-xs text-blue-400 hover:text-blue-300 font-medium">MAX</button>
          </div>
        </div>

        {mode === 'deposit' && (
          <div className="flex items-center justify-between mt-1 px-1 text-xs">
            <span className={isAtCap ? 'text-amber-500' : 'text-zinc-600'}>
              {isAtCap
                ? 'Vault at capacity'
                : maxDeposit !== null
                  ? `Max: ${formatUSDC(maxDeposit)} ${vaultConfig?.asset}`
                  : ''}
            </span>
            <span className="text-zinc-600">
              {isLoading ? '…' : `${formatUSDC(user?.assetBalance ?? 0)} ${vaultConfig?.asset} balance`}
            </span>
          </div>
        )}

        {mode === 'withdraw' && (
          <div className="flex items-center justify-between mt-1 px-1 text-xs text-zinc-600">
            {amountNum > 0
              ? <span>Receive: ~{formatUSDC(previewAsset)} {vaultConfig?.asset}</span>
              : <span />}
            <span>{isLoading ? '…' : `${user?.shares?.toFixed(4) ?? '0'} ${vaultConfig?.symbol} balance`}</span>
          </div>
        )}
      </div>

      {/* Earn preview */}
      {mode === 'deposit' && amountNum > 0 && (
        <div className="text-xs text-zinc-500">
          You receive: ~{previewShares.toFixed(4)} {vaultConfig?.symbol}
        </div>
      )}

      {/* Info rows */}
      <div>
        <Row label="Network"  value="Somnia Testnet" />
        <Row label={mode === 'deposit' ? 'Asset' : 'Vault'} value={mode === 'deposit' ? vaultConfig?.asset : vaultConfig?.symbol} />
        <Row label="APY"      value={`${apy.toFixed(2)}%`}  highlight />
        {mode === 'deposit' && (
          <>
            <Row label="Est. monthly" value={`$${monthly.toFixed(2)}`} />
            <Row label="Est. yearly"  value={`$${yearly.toFixed(2)}`}  />
          </>
        )}
      </div>

      {/* Action button */}
      {!isConnected ? (
        <button
          onClick={onConnect}
          className="w-full py-3 rounded-xl bg-blue-600 hover:bg-blue-500 text-white font-semibold text-sm transition-colors"
        >
          Connect Wallet
        </button>
      ) : isAtCap && mode === 'deposit' ? (
        <div className="text-xs text-amber-400 bg-amber-500/10 border border-amber-500/20 rounded-lg px-3 py-2.5 text-center">
          Vault is at capacity — withdraw first to free space
        </div>
      ) : isPaused && mode === 'deposit' ? (
        <div className="space-y-2">
          <div className="text-xs text-amber-400 bg-amber-500/10 border border-amber-500/20 rounded-lg px-3 py-2">
            ⚠ Deposits paused — Sentinel detected elevated risk
          </div>
          <button
            onClick={actions.onUnpause}
            disabled={busy}
            className="w-full py-2.5 rounded-xl border border-white/[0.08] text-zinc-300 hover:bg-white/[0.04] text-sm font-medium transition-colors"
          >
            Unpause Deposits
          </button>
        </div>
      ) : (
        <button
          onClick={mode === 'deposit' ? handleDeposit : handleWithdraw}
          disabled={busy || !amountNum}
          className="w-full py-3 rounded-xl bg-blue-600 hover:bg-blue-500 disabled:opacity-40 disabled:cursor-not-allowed text-white font-semibold text-sm transition-colors"
        >
          {busy ? 'Confirming…' : mode === 'deposit' ? `Deposit ${vaultConfig?.asset}` : 'Withdraw'}
        </button>
      )}

      {/* Position */}
      {user && user.shares > 0 && (
        <div className="border-t border-white/[0.06] pt-4 space-y-1">
          <div className="text-xs font-medium text-zinc-400 mb-2">Your Position</div>
          <Row label="Value"  value={`$${formatUSDC(user.value)} ${vaultConfig?.asset}`} />
          <Row label="Shares" value={`${user.shares.toFixed(4)} ${vaultConfig?.symbol}`} />
          <div className="flex items-center justify-between py-2">
            <span className="text-xs text-zinc-500">P&L</span>
            <span className={`text-xs font-mono ${user.pnl >= 0 ? 'text-green-400' : 'text-red-400'}`}>
              {user.pnl >= 0 ? '+' : ''}{formatUSDC(user.pnl)} ({user.pnlPct.toFixed(2)}%)
            </span>
          </div>
          <Row label={`${vaultConfig?.asset} Balance`} value={`$${formatUSDC(user.assetBalance)}`} />
        </div>
      )}
    </div>
  );
}
