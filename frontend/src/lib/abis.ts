export const marketComponents = [
  { name: "underwriter", type: "address" },
  { name: "asset", type: "address" },
  { name: "oracle", type: "address" },
  { name: "pegPrice", type: "uint256" },
  { name: "depegBps", type: "uint16" },
  { name: "maxUtilBps", type: "uint16" },
  { name: "oracleTimeout", type: "uint32" },
  { name: "startRateWad", type: "uint256" },
  { name: "endRateWad", type: "uint256" },
  { name: "convexityWad", type: "uint256" },
  { name: "trigger", type: "address" },
  { name: "salt", type: "bytes32" },
] as const;

export const coverAppAbi = [
  { type: "function", name: "registerMarket", stateMutability: "nonpayable", inputs: [{ name: "market", type: "tuple", components: marketComponents }], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "markets", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: marketComponents },
  { type: "function", name: "solvency", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ name: "backing", type: "uint256" }, { name: "covered", type: "uint256" }, { name: "utilizationBps", type: "uint256" }] },
  { type: "function", name: "capacityOf", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "quotePremium", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "quotePremiumFor", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "uint256" }, { type: "uint64" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "buyPolicy", stateMutability: "nonpayable", inputs: [{ type: "bytes32" }, { type: "uint256" }, { type: "uint64" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "claim", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "expire", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
  { type: "function", name: "policies", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ name: "marketHash", type: "bytes32" }, { name: "coverNotional", type: "uint256" }, { name: "expiry", type: "uint64" }, { name: "claimed", type: "bool" }, { name: "buyer", type: "address" }, { name: "boughtAt", type: "uint64" }, { name: "premium", type: "uint256" }, { name: "paidOut", type: "uint256" }] },
  { type: "function", name: "nextPolicyId", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "marketCount", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "marketList", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "bytes32" }] },
  { type: "event", name: "MarketRegistered", inputs: [{ name: "strategyHash", type: "bytes32", indexed: true }, { name: "underwriter", type: "address", indexed: true }, { name: "asset", type: "address", indexed: true }] },
  { type: "event", name: "PolicyBought", inputs: [{ name: "policyId", type: "uint256", indexed: true }, { name: "strategyHash", type: "bytes32", indexed: true }, { name: "buyer", type: "address", indexed: true }, { name: "coverNotional", type: "uint256", indexed: false }, { name: "premium", type: "uint256", indexed: false }] },
  { type: "event", name: "PolicyClaimed", inputs: [{ name: "policyId", type: "uint256", indexed: true }, { name: "to", type: "address", indexed: true }, { name: "payout", type: "uint256", indexed: false }, { name: "price", type: "uint256", indexed: false }] },
  { type: "event", name: "PolicyExpiredReleased", inputs: [{ name: "policyId", type: "uint256", indexed: true }, { name: "strategyHash", type: "bytes32", indexed: true }, { name: "coverNotional", type: "uint256", indexed: false }] },
  { type: "error", name: "SolvencyFloorBreached", inputs: [{ name: "requested", type: "uint256" }, { name: "available", type: "uint256" }] },
  { type: "error", name: "AggregateFloorBreached", inputs: [] },
  { type: "error", name: "PolicyExpired", inputs: [] },
  { type: "error", name: "PolicyNotExpired", inputs: [] },
  { type: "error", name: "PolicyAlreadyClaimed", inputs: [] },
  { type: "error", name: "NotNoteHolder", inputs: [] },
  { type: "error", name: "StaleOracle", inputs: [] },
  { type: "error", name: "NotDepegged", inputs: [{ name: "price", type: "uint256" }, { name: "triggerPrice", type: "uint256" }] },
  { type: "error", name: "NotTriggered", inputs: [] },
  { type: "error", name: "ZeroAmount", inputs: [] },
  { type: "error", name: "UnknownMarket", inputs: [] },
  { type: "error", name: "NotUnderwriter", inputs: [] },
  { type: "error", name: "AlreadyRegistered", inputs: [] },
] as const;

export const aquaAbi = [
  { type: "function", name: "ship", stateMutability: "nonpayable", inputs: [{ name: "app", type: "address" }, { name: "strategy", type: "bytes" }, { name: "tokens", type: "address[]" }, { name: "amounts", type: "uint256[]" }], outputs: [{ type: "bytes32" }] },
  { type: "function", name: "dock", stateMutability: "nonpayable", inputs: [{ name: "app", type: "address" }, { name: "strategyHash", type: "bytes32" }, { name: "tokens", type: "address[]" }], outputs: [] },
] as const;

export const erc20Abi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "allowance", stateMutability: "view", inputs: [{ type: "address" }, { type: "address" }], outputs: [{ type: "uint256" }] },
  { type: "function", name: "approve", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
  { type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [] },
] as const;

export const noteAbi = [
  { type: "function", name: "balanceOf", stateMutability: "view", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "uint256" }] },
] as const;

export const oracleAbi = [
  { type: "function", name: "latestPrice", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }, { type: "uint256" }] },
  { type: "function", name: "set", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
] as const;

export const payoutAbi = [
  { type: "function", name: "payout", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [{ type: "uint256" }] },
] as const;

export const noteHolderAbi = [
  { type: "function", name: "holderOf", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ type: "address" }] },
] as const;

export const ilTriggerAbi = [
  { type: "function", name: "bind", stateMutability: "nonpayable", inputs: [{ type: "uint256" }], outputs: [] },
  { type: "function", name: "preview", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ name: "ilBps", type: "uint256" }, { name: "payoutBps", type: "uint256" }] },
  { type: "function", name: "bindings", stateMutability: "view", inputs: [{ type: "uint256" }], outputs: [{ name: "lp", type: "address" }, { name: "baseTick", type: "int24" }, { name: "enteredAt", type: "uint64" }, { name: "set", type: "bool" }] },
  { type: "function", name: "configs", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ name: "hook", type: "address" }, { name: "poolId", type: "bytes32" }, { name: "deductibleBps", type: "uint16" }, { name: "capBps", type: "uint16" }, { name: "set", type: "bool" }] },
] as const;

export const gapTriggerAbi = [
  { type: "function", name: "configs", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ name: "oracle", type: "address" }, { name: "strike", type: "uint256" }, { name: "timeout", type: "uint32" }, { name: "set", type: "bool" }] },
] as const;

export const hookAbi = [
  { type: "function", name: "settledTick", stateMutability: "view", inputs: [{ type: "bytes32" }], outputs: [{ type: "int24" }] },
  { type: "function", name: "entryOf", stateMutability: "view", inputs: [{ type: "bytes32" }, { type: "address" }], outputs: [{ name: "entryTick", type: "int24" }, { name: "exitTick", type: "int24" }, { name: "enteredAt", type: "uint64" }, { name: "exitedAt", type: "uint64" }, { name: "active", type: "bool" }] },
  { type: "function", name: "ilBps", stateMutability: "pure", inputs: [{ type: "int24" }, { type: "int24" }], outputs: [{ type: "uint256" }] },
] as const;

const poolKeyComponents = [
  { name: "currency0", type: "address" },
  { name: "currency1", type: "address" },
  { name: "fee", type: "uint24" },
  { name: "tickSpacing", type: "int24" },
  { name: "hooks", type: "address" },
] as const;

export const lpRouterAbi = [
  { type: "function", name: "modifyAs", stateMutability: "nonpayable", inputs: [{ name: "key", type: "tuple", components: poolKeyComponents }, { type: "int24" }, { type: "int24" }, { type: "int256" }], outputs: [] },
] as const;

export const swapperAbi = [
  {
    type: "function", name: "swap", stateMutability: "payable",
    inputs: [
      { name: "key", type: "tuple", components: poolKeyComponents },
      { name: "params", type: "tuple", components: [{ name: "zeroForOne", type: "bool" }, { name: "amountSpecified", type: "int256" }, { name: "sqrtPriceLimitX96", type: "uint160" }] },
      { name: "testSettings", type: "tuple", components: [{ name: "takeClaims", type: "bool" }, { name: "settleUsingBurn", type: "bool" }] },
      { name: "hookData", type: "bytes" },
    ],
    outputs: [{ type: "int256" }],
  },
] as const;

export const vaultAbi = [
  { type: "function", name: "aprBps", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "totalYield", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "pending", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

export const yieldReserveAbi = [
  { type: "function", name: "owner", stateMutability: "view", inputs: [], outputs: [{ type: "address" }] },
  { type: "function", name: "totalAssets", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

const legComponents = [
  { name: "strategyHash", type: "bytes32" },
  { name: "coverNotional", type: "uint256" },
] as const;

export const routerAbi = [
  { type: "function", name: "quoteRouteFor", stateMutability: "view", inputs: [{ name: "legs", type: "tuple[]", components: legComponents }, { name: "duration", type: "uint64" }], outputs: [{ name: "totalCover", type: "uint256" }, { name: "totalPremium", type: "uint256" }] },
  {
    type: "function", name: "buyRoute", stateMutability: "nonpayable",
    inputs: [
      { name: "legs", type: "tuple[]", components: legComponents },
      { name: "asset", type: "address" },
      { name: "maxTotalPremium", type: "uint256" },
      { name: "duration", type: "uint64" },
      { name: "to", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "policyIds", type: "uint256[]" }, { name: "totalPremium", type: "uint256" }],
  },
] as const;
