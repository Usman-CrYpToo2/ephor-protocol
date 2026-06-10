export const CHAIN_ID  = 50312;
export const CHAIN_HEX = '0xC478';

export const CHECK_DEPOSIT      = '0.25';   // STT for sentinel
export const REBALANCE_DEPOSIT  = '0.5';    // STT for strategist (covers 2 sub-requests)
export const REBALANCE_COOLDOWN = 60;       // 1 min in seconds
export const CHECK_COOLDOWN     = 30;       // 30 sec in seconds

export const SOMNIA_NETWORK = {
  chainId: CHAIN_HEX,
  chainName: 'Somnia Testnet',
  nativeCurrency: { name: 'STT', symbol: 'STT', decimals: 18 },
  rpcUrls: ['https://dream-rpc.somnia.network'],
  blockExplorerUrls: ['https://shannon-explorer.somnia.network'],
};

export const RPC_URL = 'https://dream-rpc.somnia.network';

export const ADDRESSES = {
  vault:      '0x9c8512238532b37C0d01CA2d82dbB180eB11C346',
  sentinel:   '0xFd87296402b958ba822F529d9ffc9Fe7751574fD',
  strategist: '0x00913D41650F9eFEC0FD916c956b83915049Af3c',
  usdc:       '0x78BC5Dac41b7fAd2A500bc449C2B7Db15aCaCb6D',
  marketA:    '0x8c1B1c79390531Fecc30BF73776AA6DC5237aEF6',
  marketB:    '0x01fBDe048F572aFc23ba7Ae2939F573FC10c842f',
};

export const MARKET_NAMES = {
  [ADDRESSES.marketA]: 'Lending Pool A',
  [ADDRESSES.marketB]: 'Lending Pool B',
};

export const ABIS = {
  vault: [
    'function totalAssets() view returns (uint256)',
    'function depositsPaused() view returns (bool)',
    'function idleBufferBps() view returns (uint256)',
    'function minIdleBufferBps() view returns (uint256)',
    'function maxMarketBps() view returns (uint256)',
    'function maxTurnoverBps() view returns (uint256)',
    'function rebalanceEpochLength() view returns (uint256)',
    'function currentEpoch() view returns (uint256)',
    'function lastRebalanceTime() view returns (uint256)',
    'function marketCount() view returns (uint256)',
    'function marketList(uint256) view returns (address)',
    'function marketAllocationBps(address) view returns (uint256)',
    'function markets(address) view returns (bool enabled, uint256 supplyCap)',
    'function sharePrice() view returns (uint256)',
    'function totalSupply() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function maxDeposit(address) view returns (uint256)',
    'function performanceFeeBps() view returns (uint256)',
    'function feeRecipient() view returns (address)',
    'function allocate(address, uint256)',
    'function deallocate(address, uint256)',
    'function unpauseDeposits()',
    'function deposit(uint256, address) returns (uint256)',
    'function redeem(uint256, address, address) returns (uint256)',
    'function previewDeposit(uint256) view returns (uint256)',
    'function previewRedeem(uint256) view returns (uint256)',
    'error DepositExceedsCap(uint256 requested, uint256 available)',
    'error IdleFloorBreached(uint256 actualIdleBps, uint256 requiredBps)',
  ],
  sentinel: [
    'function vaultInfo(address) view returns (bool registered, bool autoPauseEnabled, uint8 lastLevel, uint256 lastCheckedAt, uint256 totalChecks, uint256 criticalCount)',
    'function isCheckPending(address) view returns (bool)',
    'function activeRequest(address) view returns (uint256)',
    'function getLatestRisk(address) view returns (uint8 level, uint256 ts, string verdict)',
    'function getHistory(address) view returns (tuple(uint256 timestamp, uint8 level, string rawVerdict, uint256 totalAssets, uint256 idleBps)[])',
    'function assessOnChain(address) view returns (uint8)',
    'function checkVault(address) payable',
    'function setOracle(address)',
  ],
  strategist: [
    'function lastRequestAt(address) view returns (uint256)',
    'function activeRequest(address) view returns (uint256)',
    'function REBALANCE_COOLDOWN() view returns (uint256)',
    'function admin() view returns (address)',
    'function requestRebalance(address) payable',
  ],
  usdc: [
    'function balanceOf(address) view returns (uint256)',
    'function approve(address, uint256) returns (bool)',
    'function mint(address, uint256)',
    'function decimals() view returns (uint8)',
  ],
  market: [
    'function utilizationBps() view returns (uint256)',
    'function supplyRateBps() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
    'function totalAssets() view returns (uint256)',
    'function setUtilization(uint256)',
    'function setSupplyRate(uint256)',
    'function fastForwardDays(uint256)',
  ],
};

// ── Risk theme tokens ─────────────────────────────────────────────────────────

export const RISK_THEME = {
  0: {
    label: 'SAFE',
    text:   'text-emerald-400',
    bg:     'bg-emerald-500/10',
    border: 'border-emerald-500/25',
    dot:    'bg-emerald-400',
    bar:    'bg-emerald-500',
    glow:   'shadow-emerald-500/20',
  },
  1: {
    label: 'CAUTION',
    text:   'text-amber-400',
    bg:     'bg-amber-500/10',
    border: 'border-amber-500/25',
    dot:    'bg-amber-400',
    bar:    'bg-amber-500',
    glow:   'shadow-amber-500/20',
  },
  2: {
    label: 'CRITICAL',
    text:   'text-red-400',
    bg:     'bg-red-500/10',
    border: 'border-red-500/25',
    dot:    'bg-red-400',
    bar:    'bg-red-500',
    glow:   'shadow-red-500/20',
  },
};

export const STRATEGY_LABELS = {
  BALANCED:   'Equal weight across all active markets.',
  YIELD_TILT: 'Favor highest-APY markets with more capital.',
  DEFENSIVE:  'Reduce market exposure, increase idle buffer.',
  DERISK:     'Skip reallocation entirely — stay idle.',
};

export const VAULTS = [
  {
    address:      '0x9c8512238532b37C0d01CA2d82dbB180eB11C346',
    name:         'Ephor USDC Vault',
    symbol:       'ephUSDC',
    asset:        'USDC',
    assetAddr:    '0x78BC5Dac41b7fAd2A500bc449C2B7Db15aCaCb6D',
    assetDecimals: 6,
    sentinel:     '0xFd87296402b958ba822F529d9ffc9Fe7751574fD',
    strategist:   '0x00913D41650F9eFEC0FD916c956b83915049Af3c',
    markets: [
      { address: '0x8c1B1c79390531Fecc30BF73776AA6DC5237aEF6', name: 'Lending Pool A' },
      { address: '0x01fBDe048F572aFc23ba7Ae2939F573FC10c842f', name: 'Lending Pool B' },
    ],
    description: 'AI-powered USDC yield vault. The VaultSentinel monitors risk on-chain via Somnia\'s native LLM inference and reallocates capital automatically.',
    seed: { deposit: 50_000, allocA: 15_000, allocB: 10_000, utilA: 45, utilB: 72, rateA: 300, rateB: 520 },
  },
  {
    address:      '0x9A0d394822c5d569883d704724547c7fF7Fe7f70',
    name:         'Ephor WETH Vault',
    symbol:       'ephWETH',
    asset:        'WETH',
    assetAddr:    '0x3ef6979Ea0bEb70CFbb2B12706d4855C3E978f99',
    assetDecimals: 18,
    sentinel:     '0xFd87296402b958ba822F529d9ffc9Fe7751574fD',
    strategist:   '0x96237866CF8BD829C7f06ebDCf71625A969428e3',
    markets: [
      { address: '0xbC428f44D47AfF0a0E732516b5b5B9D6aa6a949f', name: 'Lending Pool A' },
      { address: '0x5d5A8e4F224452E26aE4c289794102661AC4Cbb5', name: 'Lending Pool B' },
    ],
    description: 'AI-powered WETH yield vault. VaultSentinel and AllocationStrategist manage risk and capital allocation autonomously on Somnia.',
    seed: { deposit: 50, allocA: 15, allocB: 10, utilA: 55, utilB: 68, rateA: 380, rateB: 510 },
  },
  {
    address:      '0xf7ECFFc39c9EA02CC60B6f990DDd1039e6cd498D',
    name:         'Ephor WBTC Vault',
    symbol:       'ephWBTC',
    asset:        'WBTC',
    assetAddr:    '0xf294dB6e4C62b0990B32a483Bf8B6449c42659aF',
    assetDecimals: 8,
    sentinel:     '0xFd87296402b958ba822F529d9ffc9Fe7751574fD',
    strategist:   '0x4d8De4926DE963836D597680aA3c910D16a5B55D',
    markets: [
      { address: '0x5D2c3bCaDB1a106e94e23df898C4A78e46013A48', name: 'Lending Pool A' },
      { address: '0x4309309E3cb2A2bE483DF450Dcb9B283d50a1FAb', name: 'Lending Pool B' },
    ],
    description: 'AI-powered WBTC yield vault. VaultSentinel and AllocationStrategist manage risk and capital allocation autonomously on Somnia.',
    seed: { deposit: 5, allocA: 1.5, allocB: 1, utilA: 40, utilB: 62, rateA: 280, rateB: 450 },
  },
];

// ── Formatters ────────────────────────────────────────────────────────────────

export function formatTime(ts) {
  if (!ts) return 'Never';
  const diff = Math.floor(Date.now() / 1000) - ts;
  if (diff < 5)    return 'just now';
  if (diff < 60)   return `${diff}s ago`;
  if (diff < 3600) return `${Math.floor(diff / 60)}m ago`;
  if (diff < 86400) return `${Math.floor(diff / 3600)}h ago`;
  return `${Math.floor(diff / 86400)}d ago`;
}

export function formatCountdown(seconds) {
  if (seconds <= 0) return 'Ready';
  if (seconds < 60) return `${seconds}s`;
  return `${Math.floor(seconds / 60)}m ${seconds % 60}s`;
}

export function formatUSDC(amount) {
  if (amount === undefined || amount === null) return '—';
  return amount.toLocaleString('en-US', { minimumFractionDigits: 0, maximumFractionDigits: 0 });
}

export function formatBps(bps) {
  if (bps === undefined || bps === null) return '—';
  return (bps / 100).toFixed(1) + '%';
}

export function truncateAddress(addr) {
  if (!addr) return '';
  return `${addr.slice(0, 6)}…${addr.slice(-4)}`;
}
