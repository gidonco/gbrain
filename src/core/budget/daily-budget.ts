/**
 * Cross-process daily AI budget governor.
 *
 * Uses the existing reserve/settle spend ledger so every GBrain process sees
 * the same daily cap. When enabled, missing pricing and ledger failures fail
 * closed before provider transport. Pending reservations remain charged at
 * their estimate if a process crashes.
 */

import type { BrainEngine } from '../engine.ts';
import {
  BudgetExhausted,
  costForUsage,
  estimateBudgetCostUsd,
  type BudgetActualUsage,
  type BudgetEstimate,
  type BudgetKind,
} from './budget-tracker.ts';
import {
  BudgetExceededError,
  DAILY_AI_BUDGET_CLIENT_ID,
  reserve,
  settle,
  type Reservation,
} from '../minions/budget-meter.ts';
import { splitProviderModelId } from '../model-id.ts';

type DailyBudgetState =
  | { mode: 'disabled'; engine: BrainEngine | null; refreshFromEngine: boolean }
  | { mode: 'armed'; engine: BrainEngine; capUsd: number; refreshFromEngine: boolean }
  | { mode: 'blocked'; engine: BrainEngine; reason: string; refreshFromEngine: boolean };

export interface DailyBudgetReservation {
  engine: BrainEngine;
  reservation: Reservation;
  estimate: BudgetEstimate;
  estimatedCents: number;
}

let state: DailyBudgetState = { mode: 'disabled', engine: null, refreshFromEngine: false };

export class DailyBudgetConfigurationError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = 'DailyBudgetConfigurationError';
  }
}

export function configureDailyBudget(
  engine: BrainEngine,
  rawCap: unknown,
  opts: { refreshFromEngine?: boolean } = {},
): void {
  const refreshFromEngine = opts.refreshFromEngine === true;
  if (rawCap === null || rawCap === undefined || String(rawCap).trim() === '' || Number(rawCap) === 0) {
    state = { mode: 'disabled', engine, refreshFromEngine };
    return;
  }
  const capUsd = Number(rawCap);
  if (!Number.isFinite(capUsd) || capUsd <= 0) {
    state = {
      mode: 'blocked',
      engine,
      refreshFromEngine,
      reason: `invalid ai.daily_budget_usd value ${JSON.stringify(rawCap)}; expected a positive decimal number or 0 to disable`,
    };
    return;
  }
  state = { mode: 'armed', engine, capUsd, refreshFromEngine };
}

async function readConfiguredCap(engine: BrainEngine): Promise<unknown> {
  const dbCap = await engine.getConfig('ai.daily_budget_usd');
  return dbCap ?? process.env.GBRAIN_DAILY_BUDGET_USD;
}

/** Arm production policy and retain a blocked state if config cannot be read. */
export async function armDailyBudgetFromEngine(engine: BrainEngine): Promise<void> {
  try {
    configureDailyBudget(engine, await readConfiguredCap(engine), { refreshFromEngine: true });
  } catch (error) {
    const reason = `could not read ai.daily_budget_usd: ${error instanceof Error ? error.message : String(error)}`;
    state = { mode: 'blocked', engine, refreshFromEngine: true, reason };
    throw new DailyBudgetConfigurationError(reason, { cause: error });
  }
  if (state.mode === 'blocked') {
    throw new DailyBudgetConfigurationError(state.reason);
  }
}

async function refreshProductionState(): Promise<void> {
  if (!state.refreshFromEngine || !state.engine) return;
  const engine = state.engine;
  try {
    configureDailyBudget(engine, await readConfiguredCap(engine), { refreshFromEngine: true });
  } catch (error) {
    state = {
      mode: 'blocked',
      engine,
      refreshFromEngine: true,
      reason: `could not refresh ai.daily_budget_usd: ${error instanceof Error ? error.message : String(error)}`,
    };
  }
}

export function resetDailyBudget(): void {
  state = { mode: 'disabled', engine: null, refreshFromEngine: false };
}

export function getDailyBudgetCapUsd(): number | null {
  return state.mode === 'armed' ? state.capUsd : null;
}

export async function reserveDailyBudget(
  estimate: BudgetEstimate,
): Promise<DailyBudgetReservation | null> {
  await refreshProductionState();
  if (state.mode === 'disabled') return null;
  if (state.mode === 'blocked') {
    throw new BudgetExhausted(
      `daily AI budget is not safely configured; refusing provider call: ${state.reason}`,
      { reason: 'cost', spent: 0, cap: 0, modelId: estimate.modelId },
    );
  }
  const armed = state;
  const estimatedUsd = estimateBudgetCostUsd(estimate);
  if (estimatedUsd === null) {
    throw new BudgetExhausted(
      `daily AI budget: no pricing entry for model "${estimate.modelId}" (${estimate.kind}); refusing provider call`,
      { reason: 'no_pricing', spent: 0, cap: armed.capUsd, modelId: estimate.modelId },
    );
  }
  const estimatedCents = Math.max(estimatedUsd * 100, 0.000001);
  const { provider } = splitProviderModelId(estimate.modelId);
  try {
    const reservation = await reserve(armed.engine, {
      clientId: DAILY_AI_BUDGET_CLIENT_ID,
      estimatedCents,
      capCents: armed.capUsd * 100,
      model: estimate.modelId,
      provider: provider || 'unknown',
    });
    return { engine: armed.engine, reservation, estimate, estimatedCents };
  } catch (error) {
    if (error instanceof BudgetExceededError) {
      throw new BudgetExhausted(
        `daily AI budget of $${armed.capUsd.toFixed(2)} exhausted; refusing provider call`,
        { reason: 'cost', spent: error.spentCents / 100, cap: armed.capUsd, modelId: estimate.modelId },
      );
    }
    throw new BudgetExhausted(
      `daily AI budget ledger unavailable; refusing provider call: ${error instanceof Error ? error.message : String(error)}`,
      { reason: 'cost', spent: 0, cap: armed.capUsd, modelId: estimate.modelId },
    );
  }
}

export async function settleDailyBudget(
  daily: DailyBudgetReservation | null,
  usage?: BudgetActualUsage & { kind?: BudgetKind },
): Promise<void> {
  if (!daily) return;
  const actualUsd = usage
    ? costForUsage(
        usage.modelId,
        usage.inputTokens,
        usage.outputTokens ?? 0,
        usage.kind ?? daily.estimate.kind,
      )
    : null;
  const actualCents = actualUsd === null
    ? daily.estimatedCents
    : Math.max(actualUsd * 100, 0);
  await settle(daily.engine, daily.reservation.reservationId, actualCents, `ai_gateway_${daily.estimate.kind}`);
}
