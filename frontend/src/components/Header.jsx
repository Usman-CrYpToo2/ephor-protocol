import React from 'react';
import { CHAIN_ID, truncateAddress } from '../config';

export default function Header({ userAddress, chainId, onConnect, onSwitchNetwork, isWrongNetwork, lastRefresh }) {
  const isConnected = !!userAddress;

  return (
    <header className="sticky top-0 z-40 border-b border-slate-800/60 bg-[#07090f]/90 backdrop-blur-xl">
      <div className="max-w-7xl mx-auto px-4 sm:px-6 h-16 flex items-center justify-between">

        {/* Brand */}
        <div className="flex items-center">
          <img src="/logo.svg" alt="Ephor Protocol" className="h-9 w-auto" />
        </div>

        {/* Right controls */}
        <div className="flex items-center gap-2 sm:gap-3">
          {/* Somnia badge */}
          <div className="hidden sm:flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs bg-indigo-500/10 border border-indigo-500/20 text-indigo-300">
            <span className="text-[10px]">⚡</span>
            Somnia Testnet
          </div>

          {/* Network status */}
          {isConnected && (
            <div className={`hidden md:flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs border
              ${isWrongNetwork
                ? 'bg-red-500/10 border-red-500/25 text-red-400'
                : 'bg-emerald-500/10 border-emerald-500/25 text-emerald-400'
              }`}>
              <span className={`w-1.5 h-1.5 rounded-full animate-pulse ${isWrongNetwork ? 'bg-red-400' : 'bg-emerald-400'}`} />
              {isWrongNetwork ? 'Wrong Network' : 'Connected'}
            </div>
          )}

          {/* Wallet button */}
          {isConnected ? (
            <div className="flex items-center gap-2 px-3 py-1.5 rounded-xl bg-slate-800/80 border border-slate-700/60 text-sm">
              <div className="w-2 h-2 rounded-full bg-emerald-400 shadow-sm shadow-emerald-400/50" />
              <span className="font-mono text-slate-300 text-xs">{truncateAddress(userAddress)}</span>
            </div>
          ) : (
            <button
              onClick={onConnect}
              className="px-4 py-2 rounded-xl bg-indigo-600 hover:bg-indigo-500 active:bg-indigo-700 text-white text-sm font-medium transition-all duration-150 shadow-lg shadow-indigo-500/25 hover:shadow-indigo-500/40"
            >
              Connect Wallet
            </button>
          )}

          {isWrongNetwork && isConnected && (
            <button
              onClick={onSwitchNetwork}
              className="px-3 py-1.5 rounded-xl bg-amber-600 hover:bg-amber-500 text-white text-xs font-medium transition-colors"
            >
              Switch Network
            </button>
          )}
        </div>
      </div>
    </header>
  );
}
