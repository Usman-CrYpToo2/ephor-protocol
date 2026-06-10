import React from 'react';
import { Link, useLocation } from 'react-router-dom';
import { truncateAddress } from '../config';

export default function Header({ userAddress, chainId, onConnect, onSwitchNetwork, isWrongNetwork }) {
  const isConnected = !!userAddress;
  const location    = useLocation();

  const navLinks = [
    { to: '/', label: 'Vaults' },
  ];

  return (
    <header className="sticky top-0 z-40 border-b border-white/[0.06] bg-black/90 backdrop-blur-xl">
      <div className="max-w-7xl mx-auto px-6 h-14 flex items-center justify-between">

        {/* Brand + Nav */}
        <div className="flex items-center gap-8">
          <Link to="/" className="flex items-center">
            <img src="/logo.svg" alt="Ephor Protocol" className="h-8 w-auto" />
          </Link>

          <nav className="flex items-center gap-1">
            {navLinks.map(({ to, label }) => {
              const active = to === '/' ? location.pathname === '/' : location.pathname.startsWith(to);
              return (
                <Link
                  key={to}
                  to={to}
                  className={`px-3 py-1.5 rounded-lg text-sm transition-colors
                    ${active ? 'text-white bg-white/[0.06]' : 'text-zinc-400 hover:text-white hover:bg-white/[0.04]'}`}
                >
                  {label}
                </Link>
              );
            })}
          </nav>
        </div>

        {/* Right side */}
        <div className="flex items-center gap-3">
          <div className="hidden sm:flex items-center gap-1.5 px-2.5 py-1 rounded-full text-xs border border-white/[0.08] text-zinc-400">
            <span className="w-1.5 h-1.5 rounded-full bg-blue-400" />
            Somnia Testnet
          </div>

          {isConnected ? (
            <div className="flex items-center gap-2 px-3 py-1.5 rounded-xl border border-white/[0.08] text-sm">
              <span className="w-1.5 h-1.5 rounded-full bg-emerald-400" />
              <span className="font-mono text-zinc-300 text-xs">{truncateAddress(userAddress)}</span>
            </div>
          ) : (
            <button
              onClick={onConnect}
              className="px-4 py-1.5 rounded-xl bg-blue-600 hover:bg-blue-500 text-white text-sm font-medium transition-colors"
            >
              Connect
            </button>
          )}
        </div>
      </div>
    </header>
  );
}
