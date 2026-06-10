import React from 'react';

const TABS = [
  { id: 'overview',    label: 'Overview'    },
  { id: 'allocation',  label: 'Allocation'  },
  { id: 'performance', label: 'Performance' },
  { id: 'risk',        label: 'Risk AI'     },
  { id: 'activity',    label: 'Activity'    },
  { id: 'demo',        label: 'Demo'        },
];

export default function TabBar({ active, onChange, data }) {
  const sentinelPending = data?.sentinel?.isCheckPending;
  const stratPending    = data?.strategist?.isPending;

  return (
    <div className="border-b border-white/[0.06] flex gap-0">
      {TABS.map(t => {
        const isActive = active === t.id;
        const hasBadge = (t.id === 'risk' && (sentinelPending || stratPending));
        return (
          <button
            key={t.id}
            onClick={() => onChange(t.id)}
            className={`relative px-4 py-2.5 text-sm font-medium transition-colors
              ${isActive ? 'text-white' : 'text-zinc-500 hover:text-zinc-300'}`}
          >
            {t.label}
            {hasBadge && (
              <span className="absolute top-2 right-2 w-1.5 h-1.5 rounded-full bg-blue-400" />
            )}
            {isActive && (
              <span className="absolute bottom-0 left-0 right-0 h-[2px] bg-white rounded-full" />
            )}
          </button>
        );
      })}
    </div>
  );
}
