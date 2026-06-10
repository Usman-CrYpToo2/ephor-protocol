import React from 'react';

const TABS = [
  {
    id: 'dashboard',
    label: 'Dashboard',
    icon: (
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.75">
        <rect x="3" y="3" width="7" height="7" rx="1"/>
        <rect x="14" y="3" width="7" height="7" rx="1"/>
        <rect x="3" y="14" width="7" height="7" rx="1"/>
        <rect x="14" y="14" width="7" height="7" rx="1"/>
      </svg>
    ),
  },
  {
    id: 'position',
    label: 'My Position',
    icon: (
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.75">
        <path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/>
      </svg>
    ),
  },
  {
    id: 'sentinel',
    label: 'AI Sentinel',
    icon: (
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.75">
        <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" strokeLinecap="round" strokeLinejoin="round"/>
      </svg>
    ),
    badge: 'risk',
  },
  {
    id: 'allocator',
    label: 'AI Allocator',
    icon: (
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.75">
        <path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/>
        <polyline points="3.27 6.96 12 12.01 20.73 6.96"/>
        <line x1="12" y1="22.08" x2="12" y2="12"/>
      </svg>
    ),
    badge: 'epoch',
  },
  {
    id: 'demo',
    label: 'Demo',
    icon: (
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.75">
        <circle cx="12" cy="12" r="3"/>
        <path d="M12 1v4M12 19v4M4.22 4.22l2.83 2.83M16.95 16.95l2.83 2.83M1 12h4M19 12h4M4.22 19.78l2.83-2.83M16.95 7.05l2.83-2.83"/>
      </svg>
    ),
  },
];

export default function TabNav({ active, onChange, riskLevel, currentEpoch, stratPending }) {
  const riskDot = riskLevel === 2 ? 'bg-red-400' : riskLevel === 1 ? 'bg-amber-400' : 'bg-emerald-400';

  return (
    <div className="border-b border-slate-800/60 bg-[#07090f]/60 backdrop-blur">
      <div className="max-w-7xl mx-auto px-4 sm:px-6">
        <nav className="flex gap-0.5 overflow-x-auto scrollbar-none">
          {TABS.map(tab => {
            const isActive = active === tab.id;
            return (
              <button
                key={tab.id}
                onClick={() => onChange(tab.id)}
                className={`relative flex items-center gap-2 px-4 py-3.5 text-sm font-medium whitespace-nowrap transition-all duration-150 border-b-2
                  ${isActive
                    ? 'text-white border-indigo-500'
                    : 'text-slate-500 border-transparent hover:text-slate-300 hover:border-slate-700'
                  }`}
              >
                <span className={isActive ? 'text-indigo-400' : 'text-slate-600'}>{tab.icon}</span>
                {tab.label}

                {/* Sentinel risk dot */}
                {tab.badge === 'risk' && riskLevel !== undefined && (
                  <span className={`w-2 h-2 rounded-full flex-shrink-0 ${riskDot}`} />
                )}

                {/* Allocator: epoch pill or pending dot */}
                {tab.badge === 'epoch' && currentEpoch !== undefined && (
                  stratPending ? (
                    <span className="w-2 h-2 rounded-full bg-blue-400 animate-pulse flex-shrink-0" />
                  ) : (
                    <span className="text-[10px] font-mono font-bold px-1.5 py-0.5 rounded bg-indigo-500/15 border border-indigo-500/25 text-indigo-400 flex-shrink-0">
                      E{currentEpoch}
                    </span>
                  )
                )}
              </button>
            );
          })}
        </nav>
      </div>
    </div>
  );
}
