import React from 'react';

const TABS = [
  {
    id: 'dashboard',
    label: 'Dashboard',
    icon: (
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.75">
        <rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/>
        <rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>
      </svg>
    ),
  },
  {
    id: 'position',
    label: 'My Position',
    icon: (
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.75">
        <path d="M12 2C6.48 2 2 6.48 2 12s4.48 10 10 10 10-4.48 10-10S17.52 2 12 2z"/>
        <path d="M12 6v6l4 2"/>
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
  },
  {
    id: 'demo',
    label: 'Demo Controls',
    icon: (
      <svg className="w-4 h-4" fill="none" viewBox="0 0 24 24" stroke="currentColor" strokeWidth="1.75">
        <circle cx="12" cy="12" r="3"/><path d="M12 1v4M12 19v4M4.22 4.22l2.83 2.83M16.95 16.95l2.83 2.83M1 12h4M19 12h4M4.22 19.78l2.83-2.83M16.95 7.05l2.83-2.83"/>
      </svg>
    ),
  },
];

export default function TabNav({ active, onChange, riskLevel }) {
  const riskDot = riskLevel === 2 ? 'bg-red-400' : riskLevel === 1 ? 'bg-amber-400' : 'bg-emerald-400';

  return (
    <div className="border-b border-slate-800/60 bg-[#07090f]/60 backdrop-blur">
      <div className="max-w-7xl mx-auto px-4 sm:px-6">
        <nav className="flex gap-1 overflow-x-auto scrollbar-none">
          {TABS.map(tab => {
            const isActive = active === tab.id;
            return (
              <button
                key={tab.id}
                onClick={() => onChange(tab.id)}
                className={`relative flex items-center gap-2 px-4 py-3.5 text-sm font-medium whitespace-nowrap transition-all duration-150 border-b-2
                  ${isActive
                    ? 'text-white border-indigo-500'
                    : 'text-slate-500 border-transparent hover:text-slate-300 hover:border-slate-600'
                  }`}
              >
                <span className={isActive ? 'text-indigo-400' : ''}>{tab.icon}</span>
                {tab.label}
                {/* Sentinel badge */}
                {tab.id === 'sentinel' && riskLevel !== undefined && (
                  <span className={`w-2 h-2 rounded-full ${riskDot} ml-0.5`} />
                )}
              </button>
            );
          })}
        </nav>
      </div>
    </div>
  );
}
