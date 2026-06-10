import React, { useState } from 'react';
import { useParams } from 'react-router-dom';
import { useVault } from '../hooks/useVault';
import VaultHero      from '../components/vault-detail/VaultHero';
import DepositSidebar from '../components/vault-detail/DepositSidebar';
import TabBar         from '../components/vault-detail/TabBar';
import OverviewTab    from '../components/vault-detail/OverviewTab';
import AllocationTab  from '../components/vault-detail/AllocationTab';
import PerformanceTab from '../components/vault-detail/PerformanceTab';
import RiskTab        from '../components/vault-detail/RiskTab';
import ActivityTab    from '../components/vault-detail/ActivityTab';
import DemoTab        from '../components/vault-detail/DemoTab';
import { VAULTS } from '../config';

export default function VaultDetailPage({ walletProps, makeActions }) {
  const { vaultAddress }  = useParams();
  const { data, isLoading, error, refetch, vaultConfig } = useVault(vaultAddress, walletProps.userAddress);
  const [activeTab, setActiveTab]  = useState('overview');

  const actions = makeActions(vaultConfig, refetch);
  const { isConnected } = walletProps;

  // Not found
  if (!vaultConfig) {
    return (
      <div className="max-w-7xl mx-auto px-6 py-20 text-center">
        <div className="text-zinc-500 text-lg">Vault not found.</div>
        <div className="text-zinc-700 text-sm mt-2">{vaultAddress}</div>
      </div>
    );
  }

  return (
    <div className="max-w-7xl mx-auto px-6 py-8">
      <div className="flex gap-8 items-start">
        {/* Left — scrollable content */}
        <div className="flex-1 min-w-0">
          <VaultHero data={data} isLoading={isLoading} vaultConfig={vaultConfig} />

          <div className="mt-6">
            <TabBar active={activeTab} onChange={setActiveTab} data={data} />
          </div>

          <div className="mt-6">
            {activeTab === 'overview'     && <OverviewTab    data={data} isLoading={isLoading} vaultConfig={vaultConfig} />}
            {activeTab === 'allocation'   && <AllocationTab  data={data} isLoading={isLoading} />}
            {activeTab === 'performance'  && <PerformanceTab data={data} isLoading={isLoading} />}
            {activeTab === 'risk'         && <RiskTab        data={data} isLoading={isLoading} isConnected={isConnected} actions={actions} />}
            {activeTab === 'activity'     && <ActivityTab    data={data} isLoading={isLoading} />}
            {activeTab === 'demo'         && <DemoTab        data={data} isLoading={isLoading} isConnected={isConnected} vaultConfig={vaultConfig} actions={actions} />}
          </div>
        </div>

        {/* Right — sticky sidebar */}
        <div className="w-[340px] flex-shrink-0 sticky top-[80px]">
          <DepositSidebar
            data={data}
            isLoading={isLoading}
            isConnected={isConnected}
            vaultConfig={vaultConfig}
            walletProps={walletProps}
            actions={actions}
          />
        </div>
      </div>
    </div>
  );
}
