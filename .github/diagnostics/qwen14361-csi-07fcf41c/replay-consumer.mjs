import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const evidenceDir = process.argv[2];
const loadEvidence = async (name) => JSON.parse(await readFile(resolve(evidenceDir, name), 'utf8'));
const legacy = await loadEvidence('legacy.json');
const replay = await loadEvidence('replay.json');
const fresh = await loadEvidence('fresh.json');
const source = resolve('packages/cli/dist/src/serve/remote-shell-result-publication.js');
const { RemoteShellResultPublisher } = await import(pathToFileURL(source));
const digest = (bytes) => createHash('sha256').update(bytes).digest('hex');
const payloads = {
  stdout: Buffer.from('legacy-csi-upgrade-stdout'),
  stderr: Buffer.from('fresh-csi-upgrade-stderr'),
};

async function exercise(mode, binding, segmentStatuses) {
  const isFresh = mode === 'fresh';
  const requests = [];
  const segmentOperations = new Map();
  let failure;
  const server = createServer(async (request, response) => {
    try {
      const operation = request.headers['x-qwen-tool-publication-operation'];
      const path = new URL(request.url, 'http://127.0.0.1');
      assert.equal(path.searchParams.get('workspaceId'), binding.sessionKey.workspaceId);
      assert.equal(request.headers['x-qwen-tenant-id'], binding.sessionKey.tenantId);
      assert.equal(request.headers['x-qwen-tool-publication-token'], 'A'.repeat(43));
      assert(path.pathname.startsWith(
        '/internal/managed-tool-publications/v1/sessions/session-1/publications/pub-1/',
      ));
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const body = Buffer.concat(chunks);
      let result;
      if (request.method === 'GET') {
        assert(isFresh);
        assert(path.pathname.endsWith('/operations/' + operation));
        result = segmentOperations.get(operation);
        assert(result);
      } else if (path.pathname.includes('/segments/')) {
        const stream = path.pathname.split('/').at(-2);
        assert(path.pathname.endsWith('/segments/' + stream + '/0'));
        assert.equal(operation, 'seg-' + stream + '-0');
        assert.deepEqual(body, payloads[stream]);
        assert.equal(request.headers['x-qwen-tool-segment-digest'], digest(body));
        assert.equal(segmentStatuses[stream].state, 'SUCCEEDED');
        assert.equal(segmentStatuses[stream].receipt.byteLength, body.length);
        assert.equal(segmentStatuses[stream].receipt.digest, digest(body));
        assert(!segmentOperations.has(operation));
        segmentOperations.set(operation, segmentStatuses[stream]);
        result = isFresh ? { state: 'PENDING' } : segmentStatuses[stream];
      } else if (path.pathname.endsWith('/seal')) {
        assert(isFresh, 'legacy receipt must fail before a seal');
        const stream = path.pathname.split('/').at(-2);
        const receipt = JSON.parse(body);
        assert.deepEqual(receipt, {
          segmentCount: 1,
          byteLength: payloads[stream].length,
          digest: digest(payloads[stream]),
        });
        result = { state: 'SUCCEEDED', receipt };
      } else if (path.pathname.includes('/resources/')) {
        const kind = path.pathname.split('/').at(-2);
        assert(['managed-tool-result-page', 'managed-tool-result-manifest'].includes(kind));
        if (!isFresh) assert.equal(kind, 'managed-tool-result-manifest');
        result = {
          state: 'SUCCEEDED',
          receipt: {
            resourceId: 'result-' + operation,
            kind,
            schemaVersion: 1,
            byteLength: body.length,
            digest: digest(body),
          },
        };
      } else {
        throw new Error('Unexpected diagnostic route');
      }
      requests.push({ method: request.method, operation, state: result.state });
      response.writeHead(200, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify(result));
    } catch (error) {
      failure = error;
      response.writeHead(400, { 'Content-Type': 'application/json' });
      response.end(JSON.stringify({ error: { code: 'fixture_error' } }));
    }
  });
  await new Promise((ready) => server.listen(0, '127.0.0.1', ready));
  try {
    const client = new RemoteShellResultPublisher();
    client.install({
      protocolVersion: 3,
      publication: binding.publication,
      publicationId: binding.publicationId,
      publicationToken: 'A'.repeat(43),
      serviceBaseUrl: 'http://127.0.0.1:' + server.address().port,
      binding,
    }, binding.sessionKey);
    const { sink } = await client.prepare({
      reference: binding.reference,
      capture: {
        ...binding.sessionKey,
        turnId: binding.turnId,
        executionCallId: binding.executionCallId,
        bindingGeneration: binding.bindingGeneration,
        capturePolicy: binding.capturePolicy,
      },
    });
    sink.setStarted(1);
    for (const stream of isFresh ? ['stdout', 'stderr'] : ['stdout']) {
      await sink.write(stream, payloads[stream]);
      await sink.finish(stream, true);
    }
    if (!isFresh) await sink.finish('stderr', true);
    sink.setProcessResult({ exitCode: 0, signal: null, rawOutput: payloads.stdout });
    const output = await sink.finalize('success', []);
    assert.ifError(failure);
    assert.equal(output.capture.captureStatus, isFresh ? 'complete' : 'unavailable');
    assert.equal(output.capture.captureReason, isFresh ? null : 'storage_failed');
    assert.deepEqual([...segmentOperations.keys()], isFresh ? ['seg-stdout-0', 'seg-stderr-0'] : ['seg-stdout-0']);
    assert.equal(requests.filter(({ method }) => method === 'GET').length, isFresh ? 2 : 0);
    assert.equal(requests.filter(({ operation }) => operation.startsWith('seal-')).length, isFresh ? 2 : 0);
    return { mode, capture: output.capture.captureStatus, reason: output.capture.captureReason, requests };
  } finally {
    await new Promise((closed) => server.close(closed));
  }
}

assert.deepEqual(replay.exactPost, legacy.status);
assert.deepEqual(replay.exactPost, replay.recover);
console.log(JSON.stringify({
  node: process.version,
  boundary: 'Built upstream CLI publisher and capture via loopback response relay. Segment receipt values are from Java; seal, page and manifest responses are fixture controls.',
  cases: [
    await exercise('legacy', legacy.binding, { stdout: replay.exactPost }),
    await exercise('fresh', fresh.binding, { stdout: fresh.stdout, stderr: fresh.stderr }),
  ],
}, null, 2));
