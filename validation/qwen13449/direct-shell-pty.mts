import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { setTimeout as wait } from 'node:timers/promises';

const [source, fixtureRoot] = process.argv.slice(2).map((arg) => resolve(arg));
const interactive = (file: string) => pathToFileURL(join(source, 'integration-tests', file)).href;
const { InteractiveSession } = await import(interactive('interactive/interactive-session.ts'));
const { startFakeOpenAIServer } = await import(interactive('fake-openai-server.ts'));
const { pickE2eRenderer, resolveE2eCliCommand } = await import(interactive('renderer-matrix.ts'));
const { E2E_MEMORY_SETTINGS_DEFAULTS } = await import(interactive('e2e-memory-defaults.ts'));

const renderer = pickE2eRenderer();
assert.equal(renderer, 'ink');
const runtime = resolveE2eCliCommand(renderer);
assert.equal(runtime, 'node');
const root = mkdtempSync(join(fixtureRoot, 'direct-pty-'));
const workspace = join(root, 'workspace');
const configHome = join(root, 'qwen');
const userHome = join(root, 'home');
const tempDir = join(root, 'temp');
const runtimeDir = join(root, 'runtime');
for (const dir of [workspace, configHome, userHome, tempDir, runtimeDir]) mkdirSync(dir);
const writeJson = (name, data) => writeFileSync(name, JSON.stringify(data));
const system = join(root, 'system-settings.json');
const defaults = join(root, 'defaults.json');
writeJson(system, { $version: 4 });
writeJson(defaults, { $version: 4 });
writeJson(join(configHome, 'settings.json'), {
  security: { auth: { selectedType: 'openai' }, folderTrust: { enabled: false } },
  general: { enableAutoUpdate: false, showSessionRecap: false },
  ui: { enableFollowupSuggestions: false },
  tools: { shell: { enableInteractiveShell: true } },
  memory: E2E_MEMORY_SETTINGS_DEFAULTS,
});
const server = await startFakeOpenAIServer(() => ({ content: 'Unexpected model request' }));
const ready = join(workspace, 'child-ready');
const normal = join(workspace, 'normal-control');
const jsFixture = join(workspace, 'bounded-child.mjs');
writeFileSync(jsFixture, "import { writeFileSync } from 'node:fs';\nwriteFileSync(process.argv[2], String(process.pid));\nsetTimeout(() => {}, 15000);\n");
let session;
let childPid: number | null = null;
const bundle = join(source, 'dist', 'cli.js');
function isAlive(pid: number) {
  try {
    process.kill(pid, 0);
    return true;
  } catch (error) {
    assert.equal(error.code, 'ESRCH');
    return false;
  }
}
async function until(check, label, milliseconds) {
  const end = Date.now() + milliseconds;
  while (Date.now() < end) {
    if (await check()) return;
    await wait(40);
  }
  assert.fail(label);
}
const quote = (value: string) => "'" + value.replaceAll("'", "'\\''") + "'";
try {
  session = await InteractiveSession.start({
    cwd: workspace, cols: 119, rows: 40, inheritEnv: false,
    command: { bin: runtime, args: [
      bundle, '--auth-type', 'openai', '--openai-api-key', 'fixture',
      '--openai-base-url', server.baseUrl, '--model', 'qwen-vl-baseline',
      '--approval-mode', 'yolo',
    ] },
    env: {
      PATH: process.env.PATH, HOME: userHome, QWEN_HOME: configHome, QWEN_RUNTIME_DIR: runtimeDir,
      QWEN_CODE_SYSTEM_SETTINGS_PATH: system, QWEN_CODE_SYSTEM_DEFAULTS_PATH: defaults,
      TMPDIR: tempDir, TMP: tempDir, TEMP: tempDir, TERM: 'xterm-256color',
      LANG: 'en_US.UTF-8', QWEN_CODE_LANG: 'en', QWEN_SANDBOX: 'false',
      QWEN_CODE_DISABLE_CRON: '1', QWEN_CODE_SKIP_UPDATE_CHECK_ONCE: 'true',
      QWEN_CODE_MODELS_DEV_REFRESH: 'off', NO_PROXY: 'localhost,127.0.0.1',
    },
  });
  await session.idle(300, 1800);
  session.pressKey('!');
  await session.waitFor('Shell mode', 5000);
  await session.send(`exec ${quote(process.execPath)} bounded-child.mjs child-ready`);
  await until(() => existsSync(ready), 'The directly submitted shell child did not start', 5000);
  childPid = Number(readFileSync(ready, 'utf8'));
  assert.ok(Number.isInteger(childPid) && childPid > 1 && isAlive(childPid));
  assert.equal(server.requests.length, 0);
  await session.idle(180, 1000);
  session.pressKey('\x03');
  await until(() => childPid !== null && !isAlive(childPid), 'The first Ctrl+C did not reap the shell child', 5000);
  await session.waitFor('Command was cancelled.', 5000);
  assert.equal(session.exitResult(), undefined, 'The CLI survives the first Ctrl+C');
  await session.idle(300, 1600);
  await session.send('printf normal > normal-control');
  await until(() => existsSync(normal) && readFileSync(normal, 'utf8') === 'normal', 'A successor direct command did not complete', 5000);
  assert.equal(server.requests.length, 0);
  assert.equal(session.exitResult(), undefined);
  console.log(JSON.stringify({ renderer, runtime, node: process.version, head: execFileSync('git', ['rev-parse','HEAD'], {cwd:source,encoding:'utf8'}).trim(), bundle: createHash('sha256').update(readFileSync(bundle)).digest('hex'), childPid, explicitShellMode: true, launched: true, reapedByFirstCtrlC: true, CLIStillRunning: true, successorDirectShellCompleted: true, loopbackModelRequests: 0 }));
} catch (error) {
  if (session) console.error((await session.screen()).slice(-2300));
  throw error;
} finally {
  try { await session?.close(); } finally {
    if (childPid !== null && isAlive(childPid)) process.kill(childPid, 'SIGKILL');
    await server.close();
    rmSync(root, { recursive: true });
  }
}
