export const CHAIN_ID = 50312;
export const CHAIN_HEX = '0xC478';
export const CHECK_DEPOSIT = '0.25';

export const SOMNIA_NETWORK = {
  chainId: CHAIN_HEX,
  chainName: 'Somnia Testnet',
  nativeCurrency: { name: 'STT', symbol: 'STT', decimals: 18 },
  rpcUrls: ['https://dream-rpc.somnia.network'],
  blockExplorerUrls: ['https://shannon-explorer.somnia.network'],
};

export const RPC_URL = 'https://dream-rpc.somnia.network';

export const ADDRESSES = {
  vault:    '0x9E37575c04A8B39A81B901ADb4514552DC450833',
  sentinel: '0x89e5EadA95CB904B90495dbEb6df1Cf4B3e05412',
  usdc:     '0xdF9F879e07bE0378e051B5319cEA7ea6e01D3a57',
  marketA:  '0x94AfD5262f71bf368580249af7fDc41805b64465',
  marketB:  '0x19Ff7b4e162D68103D18e1CEe518a3cA65198605',
};

export const MARKET_NAMES = {
  [ADDRESSES.marketA]: 'Market A',
  [ADDRESSES.marketB]: 'Market B',
};

export const ABIS = {
  vault: [
    'function totalAssets() view returns (uint256)',
    'function depositsPaused() view returns (bool)',
    'function idleBufferPct() view returns (uint256)',
    'function marketCount() view returns (uint256)',
    'function marketList(uint256) view returns (address)',
    'function marketAllocationPct(address) view returns (uint256)',
    'function markets(address) view returns (bool enabled, uint256 supplyCap)',
    'function sharePrice() view returns (uint256)',
    'function totalSupply() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function unpauseDeposits()',
    'function allocate(address, uint256)',
    'function deallocate(address, uint256)',
    'function deposit(uint256, address) returns (uint256)',
    'function approve(address, uint256) returns (bool)',
    'function previewDeposit(uint256) view returns (uint256)',
    'function previewRedeem(uint256) view returns (uint256)',
    'function redeem(uint256, address, address) returns (uint256)',
  ],
  sentinel: [
    'function vaultInfo(address) view returns (bool registered, bool autoPauseEnabled, uint8 lastLevel, uint256 lastCheckedAt, uint256 totalChecks, uint256 criticalCount)',
    'function isCheckPending(address) view returns (bool)',
    'function activeRequest(address) view returns (uint256)',
    'function getLatestRisk(address) view returns (uint8 level, uint256 ts, string verdict)',
    'function getHistory(address) view returns (tuple(uint256 timestamp, uint8 level, string rawVerdict, uint256 totalAssets, uint256 idlePct)[])',
    'function checkVault(address) payable',
  ],
  usdc: [
    'function balanceOf(address) view returns (uint256)',
    'function approve(address, uint256) returns (bool)',
    'function mint(address, uint256)',
    'function decimals() view returns (uint8)',
  ],
  market: [
    'function utilizationBps() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function setUtilization(uint256)',
    'function fastForwardDays(uint256)',
  ],
};

export const RISK_LABELS = ['SAFE', 'CAUTION', 'CRITICAL'];

export const RISK_THEME = {
  0: {
    label: 'SAFE',
    text: 'text-emerald-400',
    bg: 'bg-emerald-500/10',
    border: 'border-emerald-500/25',
    dot: 'bg-emerald-400',
    bar: 'bg-emerald-500',
    glow: 'shadow-emerald-500/20',
  },
  1: {
    label: 'CAUTION',
    text: 'text-amber-400',
    bg: 'bg-amber-500/10',
    border: 'border-amber-500/25',
    dot: 'bg-amber-400',
    bar: 'bg-amber-500',
    glow: 'shadow-amber-500/20',
  },
  2: {
    label: 'CRITICAL',
    text: 'text-red-400',
    bg: 'bg-red-500/10',
    border: 'border-red-500/25',
    dot: 'bg-red-400',
    bar: 'bg-red-500',
    glow: 'shadow-red-500/20',
  },
};

export function formatTime(ts) {
  if (!ts) return 'Never';
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 60) return 'just now';
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

export function formatUSDC(amount) {
  if (amount === undefined || amount === null) return '—';
  return amount.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 });
}

export function truncateAddress(addr) {
  if (!addr) return '';
  return `${addr.slice(0, 6)}...${addr.slice(-4)}`;
}
