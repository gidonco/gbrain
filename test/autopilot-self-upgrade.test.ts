import { describe, expect, test } from 'bun:test';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { generateSystemdUnit } from '../src/commands/autopilot.ts';

const AUTOPILOT_SRC = readFileSync(join(import.meta.dir, '../src/commands/autopilot.ts'), 'utf8');

describe('generateSystemdUnit', () => {
  const unit = generateSystemdUnit('/home/u/.gbrain/autopilot-run.sh');

  test('uses bounded failure-only restarts so clean exits stay stopped', () => {
    expect(unit).toContain('Restart=on-failure');
    expect(unit).not.toContain('Restart=always');
  });
  test('caps a clean-exit respawn storm with StartLimit*', () => {
    expect(unit).toContain('StartLimitIntervalSec=');
    expect(unit).toContain('StartLimitBurst=');
  });
  test('runs the given wrapper path', () => {
    expect(unit).toContain('ExecStart=/home/u/.gbrain/autopilot-run.sh');
  });
});

describe('autopilot self-upgrade static-shape regressions', () => {
  test('supervisor-relaunch, NOT in-process re-exec (Bun has no execve) — no exec*-call', () => {
    // Match call-shape, not the word (the comments legitimately say "no execve").
    expect(AUTOPILOT_SRC).not.toMatch(/execve\s*\(/);
    expect(AUTOPILOT_SRC).not.toMatch(/execvp\s*\(/);
  });
  test('the silent channel is disabled under fail-stop supervisors', () => {
    expect(AUTOPILOT_SRC).not.toContain("execSync('gbrain upgrade --swap-only'");
    expect(AUTOPILOT_SRC).toContain('self-upgrade disabled under fail-stop supervisor policy');
  });
  test('boot reconciles the breadcrumb and the tick attempts the channel', () => {
    expect(AUTOPILOT_SRC).toContain('reconcileSelfUpgradeAtBoot()');
    expect(AUTOPILOT_SRC).toContain('attemptAutopilotSelfUpgrade(engine, engineType, lockPath)');
  });
  test('autopilot never exits cleanly expecting a supervisor relaunch', () => {
    expect(AUTOPILOT_SRC).not.toContain('exiting for supervisor relaunch');
  });
});
