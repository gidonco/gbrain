import { afterAll, beforeAll, beforeEach, describe, expect, test } from 'bun:test';
import { PGLiteEngine } from '../../src/core/pglite-engine.ts';
import { resetPgliteState } from '../helpers/reset-pglite.ts';
import {
  __setChatTransportForTests,
  __setEmbedTransportForTests,
  chat,
  configureGateway,
  embed,
  resetGateway,
  withBudgetTracker,
  type ChatResult,
} from '../../src/core/ai/gateway.ts';
import {
  configureDailyBudget,
  armDailyBudgetFromEngine,
  resetDailyBudget,
} from '../../src/core/budget/daily-budget.ts';
import { BudgetExhausted, BudgetTracker } from '../../src/core/budget/budget-tracker.ts';

let engine: PGLiteEngine;

const RESULT: ChatResult = {
  text: 'ok',
  blocks: [{ type: 'text', text: 'ok' }],
  stopReason: 'end',
  usage: { input_tokens: 10, output_tokens: 10, cache_read_tokens: 0, cache_creation_tokens: 0 },
  model: 'anthropic:claude-sonnet-4-6',
  providerId: 'anthropic',
};

beforeAll(async () => {
  engine = new PGLiteEngine();
  await engine.connect({});
  await engine.initSchema();
});

afterAll(async () => {
  resetDailyBudget();
  resetGateway();
  await engine.disconnect();
});

beforeEach(async () => {
  await resetPgliteState(engine);
  resetDailyBudget();
  resetGateway();
  __setEmbedTransportForTests(null);
  configureGateway({ chat_model: 'anthropic:claude-sonnet-4-6', env: {} });
});

describe('database-backed gateway daily budget', () => {
  test('refuses before transport when projected spend exceeds the cap', async () => {
    let calls = 0;
    __setChatTransportForTests(async () => { calls++; return RESULT; });
    configureDailyBudget(engine, 0.000001);

    await expect(chat({
      messages: [{ role: 'user', content: 'hello' }],
      maxTokens: 4_096,
    })).rejects.toBeInstanceOf(BudgetExhausted);
    expect(calls).toBe(0);
  });

  test('separate calls share pending and settled spend', async () => {
    let calls = 0;
    __setChatTransportForTests(async () => { calls++; return RESULT; });
    configureDailyBudget(engine, 0.0002);

    await chat({ messages: [{ role: 'user', content: 'hello' }], maxTokens: 10 });
    await expect(chat({
      messages: [{ role: 'user', content: 'hello again' }],
      maxTokens: 10,
    })).rejects.toBeInstanceOf(BudgetExhausted);
    expect(calls).toBe(1);
  });

  test('invalid configured cap fails closed before transport', async () => {
    let calls = 0;
    __setChatTransportForTests(async () => { calls++; return RESULT; });
    configureDailyBudget(engine, '1,50');

    await expect(chat({ messages: [{ role: 'user', content: 'hello' }] }))
      .rejects.toBeInstanceOf(BudgetExhausted);
    expect(calls).toBe(0);
  });

  test('a config read failure leaves the governor blocked, not disabled', async () => {
    const broken = Object.create(engine) as PGLiteEngine;
    broken.getConfig = async () => { throw new Error('config plane unavailable'); };
    await expect(armDailyBudgetFromEngine(broken)).rejects.toThrow(/config plane unavailable/);

    let calls = 0;
    __setChatTransportForTests(async () => { calls++; return RESULT; });
    await expect(chat({ messages: [{ role: 'user', content: 'hello' }] }))
      .rejects.toBeInstanceOf(BudgetExhausted);
    expect(calls).toBe(0);
  });

  test('production arming refreshes a changed DB cap before each call', async () => {
    await engine.setConfig('ai.daily_budget_usd', '1.00');
    await armDailyBudgetFromEngine(engine);
    await engine.setConfig('ai.daily_budget_usd', '0.000001');

    let calls = 0;
    __setChatTransportForTests(async () => { calls++; return RESULT; });
    await expect(chat({ messages: [{ role: 'user', content: 'hello' }] }))
      .rejects.toBeInstanceOf(BudgetExhausted);
    expect(calls).toBe(0);
  });

  test('a phase-budget refusal does not leave a daily reservation pending', async () => {
    configureDailyBudget(engine, 1.00);
    const tracker = new BudgetTracker({
      maxCostUsd: 0.000001,
      label: 'refuse-before-transport',
      auditPath: '/tmp/gbrain-daily-budget-refusal.jsonl',
    });
    await expect(withBudgetTracker(tracker, () => chat({
      messages: [{ role: 'user', content: 'hello' }],
      maxTokens: 4_096,
    }))).rejects.toBeInstanceOf(BudgetExhausted);

    const rows = await engine.executeRaw<Record<string, unknown>>(
      `SELECT count(*)::int AS n FROM mcp_spend_reservations WHERE status = 'pending'`,
    );
    expect(Number(rows[0]?.n)).toBe(0);
  });

  test('tracker-less embeds settle immediately instead of expiring as crashes', async () => {
    resetGateway();
    configureGateway({
      embedding_model: 'openai:text-embedding-3-small',
      embedding_dimensions: 1536,
      env: { OPENAI_API_KEY: 'test-key' },
    });
    configureDailyBudget(engine, 1.00);
    __setEmbedTransportForTests((async ({ values }: { values: string[] }) => ({
      embeddings: values.map(() => Array.from({ length: 1536 }, () => 0.1)),
    })) as any);

    await embed(['hello']);
    const reservations = await engine.executeRaw<Record<string, unknown>>(
      `SELECT status FROM mcp_spend_reservations`,
    );
    const logs = await engine.executeRaw<Record<string, unknown>>(
      `SELECT count(*)::int AS n FROM mcp_spend_log WHERE operation = 'ai_gateway_embed'`,
    );
    expect(reservations.map(r => r.status)).toEqual(['settled']);
    expect(Number(logs[0]?.n)).toBe(1);
  });
});
