#!/usr/bin/env bash
set -euo pipefail
managed=packages/managed-agent-server
test_source="$managed/verification/src/test/java/com/alibaba/qwen/code/managedagent/HostedShellLifecycleRecoveryIT.java"
results="$RUNNER_TEMP/qwen-reports/current-hosted"
mkdir -p "$results"
test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
test "$(git rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE"
test "$(git hash-object "$test_source")" = "$(git rev-parse "$SOURCE_SHA:$test_source")"
git diff HEAD --exit-code

restore() {
    local code=$?
    trap - EXIT
    git restore --source="$SOURCE_SHA" --staged --worktree -- $(cut -f2 "$FIXTURE_ROOT/candidate-files.txt")
    if [[ "$(git rev-parse HEAD)" == "$CANDIDATE_SHA" ]]; then
        git update-ref --no-deref HEAD "$SOURCE_SHA" "$CANDIDATE_SHA"
    fi
    git diff HEAD --exit-code
    test "$(git hash-object "$test_source")" = "$(git rev-parse "$SOURCE_SHA:$test_source")"
    printf '0\n' > "$results/source-restore.exit"
    exit "$code"
}
trap restore EXIT
git apply --index --check "$FIXTURE_ROOT/candidate.patch"
git apply --index "$FIXTURE_ROOT/candidate.patch"
test "$(git write-tree)" = "$CANDIDATE_TREE"
test "$(git hash-object -t commit -w "$FIXTURE_ROOT/candidate.commit-object")" = "$CANDIDATE_SHA"
test "$(git rev-parse "$CANDIDATE_SHA^")" = "$SOURCE_SHA"
git update-ref --no-deref HEAD "$CANDIDATE_SHA" "$SOURCE_SHA"
test "$(git rev-parse 'HEAD^{tree}')" = "$CANDIDATE_TREE"
git diff HEAD --exit-code
printf '%s\n' "$SOURCE_REPO $SOURCE_SHA $SOURCE_TREE $CANDIDATE_SHA $CANDIDATE_TREE $GITHUB_SHA" > "$results/identity.txt"

code=0
mvn --settings "$RUNNER_TEMP/m2-settings/settings.xml" --toolchains "$RUNNER_TEMP/m2-settings/toolchains.xml" \
    "-Dmaven.repo.local=$RUNNER_TEMP/qwen-m2" --batch-mode --no-transfer-progress -f "$managed/pom.xml" \
    -Phosted-harness-mysql -Dit.test=HostedShellLifecycleRecoveryIT \
    "-Dnode.executable=$(command -v node)" "-Dqwen.cli.entry=$GITHUB_WORKSPACE/source/dist/cli.js" \
    "-Dmysql.url=jdbc:mysql://127.0.0.1:$MYSQL_PORT/qwen_current_hosted?allowPublicKeyRetrieval=true&useSSL=false" \
    -Dmysql.user=root "-Dmysql.password=$MYSQL_PASSWORD" verify checkstyle:check || code=$?
printf '%s\n' "$code" > "$results/maven.exit"
git diff HEAD --exit-code
test "$(git hash-object "$test_source")" = "$(git rev-parse "$SOURCE_SHA:$test_source")"
python3 - "$managed/verification/target/failsafe-reports" "$results" <<'PY'
from pathlib import Path
from xml.etree import ElementTree
import json
import sys
reports, output = map(Path, sys.argv[1:])
report, = reports.glob('TEST-*.HostedShellLifecycleRecoveryIT.xml')
suite = ElementTree.parse(report).getroot()
cases = [
    {'name': case.attrib['name'],
     'outcome': next((node.tag for node in case if node.tag in {'failure', 'error', 'skipped'}), 'passed')}
    for case in suite.findall('testcase')
]
summary = {'counts': {key: int(suite.attrib[key]) for key in ('tests', 'errors', 'failures', 'skipped')}, 'cases': cases}
(output / 'hosted-case-outcomes.json').write_text(json.dumps(summary, indent=2) + '\n')
assert summary['counts'] == {'tests': 4, 'errors': 0, 'failures': 0, 'skipped': 0}
assert len(cases) == 4 and all(case['outcome'] == 'passed' for case in cases)
PY
exit "$code"
