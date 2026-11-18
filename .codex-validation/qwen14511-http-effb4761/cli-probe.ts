import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { mkdir, writeFile } from 'node:fs/promises';
import { createServer, type Server } from 'node:http';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const source = process.env['QWEN_PROBE_SOURCE']!;
const scratch = process.env['QWEN_PROBE_SCRATCH']!;
await mkdir(scratch, { recursive: true });
const load = (name: string) => import(pathToFileURL(path.join(source, name)).href);
const { HostedHarnessProcess, HOSTED_TOKEN } = await load('integration-tests/helpers/hosted-harness-process.ts');
const { startHostedSessionStore } = await load('integration-tests/helpers/hosted-session-store.ts');
const { WORKSPACE_CAPABILITY_DIGEST } = await load('packages/cli/src/serve/managed-workspace-activation.ts');
const requests: Array<{ kind: string; method?: string; path?: string; status?: number; body?: unknown }> = [];
const brokerFailures: string[] = [];
let providerCalls = 0;
let cliOutput = '';
let cliOutputAttached = false;
let result: Record<string, unknown> = { status: 'NOT_EXECUTED' };
let activeStore: Awaited<ReturnType<typeof startHostedSessionStore>> | undefined;
const harness = new HostedHarnessProcess();

function redacted(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(redacted);
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value).map(([key, item]) =>
      [key, /token|secret|clientId/i.test(key) ? '<test-identity-redacted>' : redacted(item)]));
  }
  return value;
}

async function listen(server: Server) {
  await new Promise<void>((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  assert(address && typeof address !== 'string');
  return `http://127.0.0.1:${address.port}`;
}

const provider = createServer((_req, res) => {
  providerCalls += 1;
  res.writeHead(500, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify({ error: 'No model call is expected in this test.' }));
});
const broker = createServer((req, res) => {
  void (async () => {
    const url = new URL(req.url!, 'http://127.0.0.1');
    const chunks: Buffer[] = [];
    for await (const chunk of req) chunks.push(Buffer.from(chunk));
    const fields = chunks.length
      ? JSON.parse(Buffer.concat(chunks).toString())
      : Object.fromEntries(url.searchParams);
    requests.push({ kind: 'broker', method: req.method, path: url.pathname });
    const answer: Record<string, unknown> = {
      protocolVersion: 1,
      harnessSessionId: fields.harnessSessionId,
      ...(fields.runtimeSessionId ? { runtimeSessionId: fields.runtimeSessionId } : {}),
    };
    if (url.pathname.endsWith('/runtimes:warm') || url.pathname.endsWith('/runtimes:capabilities')) {
      answer.scope = {
        tenantId: 'tenant', workspaceId: 'workspace',
        workspaceGeneration: '1', capabilityDigest: WORKSPACE_CAPABILITY_DIGEST,
      };
      answer.runtime = { bindingId: 'qwen14511-test-binding', generation: '1' };
    } else if (url.pathname.endsWith('/tool-sessions:active-holds')) {
      answer.heldRuntimeSessionIds = [];
    } else if (url.pathname.endsWith(':release')) {
      answer.released = true;
    } else if (url.pathname.endsWith(':release-mount')) {
      answer.mountReleased = true;
    } else {
      throw new Error(`Unexpected broker request: ${req.method} ${url.pathname}`);
    }
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(answer));
  })().catch((error: unknown) => {
    brokerFailures.push(String(error));
    res.writeHead(501, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ error: String(error) }));
  });
});

async function post(route: string, body: unknown, clientId?: string) {
  const response = await harness.request(route, {
    method: 'POST',
    headers: { ...harness.headers(clientId), 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const text = await response.text();
  let parsed: unknown;
  try { parsed = JSON.parse(text); } catch { parsed = text; }
  requests.push({ kind: 'cli-http', path: route, status: response.status, body: redacted(parsed) });
  return { status: response.status, body: parsed as Record<string, unknown> };
}

// Attach before the process emits startup output; the helper also retains a bounded tail.
const attach = setInterval(() => {
  if (!harness.child || cliOutputAttached) return;
  cliOutput = harness.output;
  harness.child.stdout!.on('data', (data: Buffer) => { cliOutput += data.toString(); });
  harness.child.stderr!.on('data', (data: Buffer) => { cliOutput += data.toString(); });
  cliOutputAttached = true;
}, 5);
let failed = false;
try {
  const providerUrl = await listen(provider);
  const brokerUrl = await listen(broker);
  await harness.start(providerUrl, {
    startupTimeout: 45_000,
    extraArgs: ['--managed-runtime-broker-url', brokerUrl, '--managed-runtime-broker-token', 'local-test-broker-only'],
  });
  const sessionId = randomUUID();
  activeStore = await startHostedSessionStore(sessionId);
  const created = await post('/session', {
    sessionId, sessionScope: 'thread', toolProfile: 'hosted-workspace-shell/1',
    managedSessionStore: {
      baseUrl: activeStore.baseUrl, tenantId: 'tenant', workspaceId: 'workspace',
      writerId: harness.bootId, leaseDurationMs: 60_000, allowInsecureHttp: true,
    },
  });
  assert.equal(created.status, 200, JSON.stringify(created));
  const clientId = created.body.clientId as string;
  assert.equal(typeof clientId, 'string');
  const before = await activeStore.scan();
  const missing = await post(`/session/${sessionId}/messages/operations`, {
    operationId: randomUUID(), commandId: 'missing-command', kind: 'answered',
    reply: { outcome: 'answered', text: 'valid reply' },
  }, clientId);
  assert.deepEqual({ status: missing.status, code: missing.body.code }, { status: 409, code: 'session_command_record' });
  const malformed = await post(`/session/${sessionId}/messages/operations`, {
    operationId: randomUUID(), commandId: 'missing-command', kind: 'answered', reply: {},
  }, clientId);
  assert.deepEqual({ status: malformed.status, code: malformed.body.code }, { status: 400, code: 'invalid_command_operation' });
  const after = await activeStore.scan();
  assert.deepEqual(after.events, before.events);
  const detached = await post(`/session/${sessionId}/detach`, {}, clientId);
  assert.equal(detached.status, 204);
  assert.deepEqual(activeStore.failures, []);
  assert.deepEqual(brokerFailures, []);
  assert.equal(providerCalls, 0);
  result = {
    status: 'VERIFIED_FIXED', method: 'bundled-cli-http-local-transport-fixtures',
    binary: path.join(source, 'dist/cli.js'),
    cases: ['valid missing command409/session_command_record', 'malformed reply400/invalid_command_operation', 'both refusals leave journal unchanged', 'detach204'],
    scope: 'Real built CLI process and HTTP-store transport fixture with a narrow localhost broker protocol stub. No production broker/worker, Spring/MySQL, relay or provider/model coverage.',
  };
} catch (error: unknown) {
  failed = true;
  result = { status: 'NOT_VERIFIED', error: error instanceof Error ? error.stack : String(error) };
} finally {
  clearInterval(attach);
  await harness.close().catch((error: unknown) => { failed = true; result.cleanup_error = String(error); });
  await activeStore?.close().catch((error: unknown) => { failed = true; result.store_cleanup_error = String(error); });
  for (const server of [broker, provider]) {
    server.closeAllConnections();
    await new Promise<void>((resolve) => server.close(() => resolve()));
  }
  const finalStoreFailures = activeStore?.failures ?? [];
  if (failed || providerCalls !== 0 || brokerFailures.length !== 0 || finalStoreFailures.length !== 0) {
    failed = true;
    result.status = 'NOT_VERIFIED';
    result.final_invariants = {
      providerCalls, brokerFailures, storeFailures: finalStoreFailures,
      cleanupFailed: !!result.cleanup_error || !!result.store_cleanup_error,
    };
  }
  let output = cliOutput || harness.output;
  for (const token of [HOSTED_TOKEN, 'local-test-broker-only', 'local-fixture-key']) {
    output = output.split(token).join('<test-token-redacted>');
  }
  await writeFile(path.join(scratch, 'cli-probe-output.log'), output);
  await writeFile(path.join(scratch, 'cli-probe-result.json'), JSON.stringify({
    ...result, providerCalls, brokerFailures, requests, cliOutputAttached,
    sourceCommit: process.env['SOURCE_COMMIT'], sourceTree: process.env['SOURCE_TREE'],
    eventCommit: process.env['GITHUB_SHA'],
  }, null, 2) + '\n');
}
process.exitCode = failed ? 1 : 0;
