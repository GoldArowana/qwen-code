"""Build a test-only scratch probe; never rewrite a source checkout."""
import hashlib
import json
import os
import pathlib
import re

HERE = pathlib.Path(__file__).resolve().parent
SOURCE = pathlib.Path(os.environ['QWEN_PROBE_SOURCE']).resolve(strict=True)
SCRATCH = pathlib.Path(os.environ['QWEN_PROBE_SCRATCH']).resolve()
SCRATCH.mkdir(parents=True, exist_ok=True)
provenance = json.loads((HERE / 'PROVENANCE.json').read_text())
fixture = HERE / 'draft-command-operations.fixture.ts'
assert hashlib.sha256(fixture.read_bytes()).hexdigest() == provenance['fixture_sha256']
text = fixture.read_text()
origin = SOURCE / 'packages/cli/src/serve'
text = re.sub(
    r"(['\"])(\.\.?/[^'\"\n]+)\1",
    lambda match: json.dumps(str((origin / match[2]).resolve())),
    text,
)
old = """LocalJsonlManagedSessionJournalStore.read(
      path.join(state.root, 'transcript.jsonl'),
      key,
    )"""
assert text.count(old) == 2
text = text.replace(old, """LocalJsonlManagedSessionJournalStore.read({
      transcriptPath: path.join(state.root, 'transcript.jsonl'),
      runtimeBaseDir: state.root,
      sessionKey: key,
    })""")
text = text.replace(
    '  ManagedSessionRecordError,',
    '  ManagedSessionRecordError,\n  ManagedSessionAppendUnsettledError,\n  ManagedSessionJournalFencedError,',
    1,
)
marker = "describe('Hosted Harness answered command operations', () => {"
assert text.count(marker) == 1
text = text.replace(marker, marker + """
  it.each([
    new ManagedSessionAppendUnsettledError(new Error('ack lost')),
    new ManagedSessionJournalFencedError('journal fenced'),
  ])('preserves current $name retry mapping through HTTP', async (cause) => {
    await fixture();
    const settling = vi
      .spyOn(LocalManagedSessionAuthority.prototype, 'settlePendingAppend')
      .mockRejectedValueOnce(cause);
    const response = await expectOperation(
      answered(), 503, 'session_command_failed', 'store',
    );
    expect(response.body.message).toBe(cause.message);
    expect(settling).toHaveBeenCalled();
  });
""", 1)
probe = SCRATCH / 'command-operations.probe.test.ts'
probe.write_text(text)
modules = SCRATCH / 'node_modules'
if not modules.exists():
    modules.symlink_to(SOURCE / 'node_modules', target_is_directory=True)
config = """import packageConfig from __PACKAGE_CONFIG__;
const probePath = __PROBE__;
const config = {
  ...packageConfig,
  root: __PACKAGE_ROOT__,
  test: {
    ...packageConfig.test,
    include: [probePath],
    reporters: ['default', 'json', 'junit'],
    outputFile: { json: __JSON__, junit: __JUNIT__ },
    coverage: { ...packageConfig.test?.coverage, enabled: false },
  },
};
if (config.test.include.length !== 1 || config.test.include[0] !== probePath) {
  throw new Error('The independent HTTP probe must be the only included test file.');
}
console.log('QWEN_PROBE_INCLUDE ' + JSON.stringify(config.test.include));
console.log('QWEN_PROBE_SETUP ' + JSON.stringify(config.test.setupFiles));
export default config;
""".replace('\n+', '\n')
for key, value in {
    '__PACKAGE_CONFIG__': SOURCE / 'packages/cli/vitest.config.ts',
    '__PACKAGE_ROOT__': SOURCE / 'packages/cli',
    '__PROBE__': probe,
    '__JSON__': SCRATCH / 'results.json',
    '__JUNIT__': SCRATCH / 'junit.xml',
}.items():
    config = config.replace(key, json.dumps(str(value)))
(SCRATCH / 'probe.config.ts').write_text(config)
(SCRATCH / 'probe-provenance.json').write_text(json.dumps({
    **provenance,
    'source': str(SOURCE),
    'probe_sha256': hashlib.sha256(probe.read_bytes()).hexdigest(),
    'production_source_modified_by_preparation': False,
}, indent=2) + '\n')
print(json.dumps({'scratch': str(SCRATCH), 'probe_sha256': hashlib.sha256(probe.read_bytes()).hexdigest()}))
