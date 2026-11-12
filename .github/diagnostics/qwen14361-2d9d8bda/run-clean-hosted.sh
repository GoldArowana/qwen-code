#!/usr/bin/env bash
set -euo pipefail

managed=packages/managed-agent-server
test_source="$managed/verification/src/test/java/com/alibaba/qwen/code/managedagent/HostedShellLifecycleRecoveryIT.java"
production="$managed/persistence/src/main/java/com/alibaba/qwen/code/managedagent/persistence/ToolPublicationDataStore.java"
patch="$FIXTURE_ROOT/serializer.patch"
results="$RUNNER_TEMP/qwen-reports"
mkdir -p "$results"

test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
test "$(git rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE"
test "$(git hash-object "$test_source")" = a24647501db25455cc88df5726d5d18d8f80e455
git diff HEAD --exit-code
git apply --check "$patch"
git apply "$patch"
test "$(git diff HEAD --name-only)" = "$production"
git diff --check
git diff --binary HEAD > "$results/serializer-only.diff"
sha256sum "$results/serializer-only.diff" | cut -d ' ' -f1 > "$results/tracked-diff.sha256"
printf '%s\n' "$SOURCE_SHA $SOURCE_TREE $GITHUB_SHA" > "$results/identity.txt"

mvn_status=0
mvn --settings "$RUNNER_TEMP/m2-settings/settings.xml" --toolchains "$RUNNER_TEMP/m2-settings/toolchains.xml" \
    "-Dmaven.repo.local=$RUNNER_TEMP/qwen-m2" --batch-mode --no-transfer-progress -f "$managed/pom.xml" \
    -Phosted-harness-mysql -Dit.test=HostedShellLifecycleRecoveryIT \
    "-Dnode.executable=$(command -v node)" "-Dqwen.cli.entry=$GITHUB_WORKSPACE/source/dist/cli.js" \
    "-Dmysql.url=jdbc:mysql://127.0.0.1:$MYSQL_PORT/qwen_hosted_clean?allowPublicKeyRetrieval=true&useSSL=false" \
    -Dmysql.user=root "-Dmysql.password=$MYSQL_PASSWORD" verify checkstyle:check || mvn_status=$?
printf '%s\n' "$mvn_status" > "$results/maven.exit"

git diff --binary HEAD > "$RUNNER_TEMP/clean-hosted-observed.diff"
cmp "$results/serializer-only.diff" "$RUNNER_TEMP/clean-hosted-observed.diff"
git apply --check --reverse "$patch"
git apply --reverse "$patch"
git diff HEAD --exit-code
test "$(git hash-object "$test_source")" = a24647501db25455cc88df5726d5d18d8f80e455
printf '0\n' > "$results/source-restore.exit"

python3 - "$managed/verification/target/failsafe-reports" "$results" <<'PY'
from pathlib import Path
from xml.etree import ElementTree
import json,sys
reports=Path(sys.argv[1])
out=Path(sys.argv[2])
paths=list(reports.glob('TEST-*.HostedShellLifecycleRecoveryIT.xml'))
assert len(paths)==1, f'Expected one current Hosted lifecycle report, observed {len(paths)}'
tree=ElementTree.parse(paths[0]).getroot()
cases=[{'name':case.attrib['name'],'outcome':next((node.tag for node in case if node.tag in {'failure','error','skipped'}),'passed')}
       for case in tree.findall('testcase')]
summary={'counts':{field:int(tree.attrib[field]) for field in ('tests','errors','failures','skipped')},
         'cases':cases}
(out/'hosted-case-outcomes.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary))
assert summary['counts']==dict(tests=4,errors=0,failures=0,skipped=0)
assert len(cases)==4 and all(case['outcome']=='passed' for case in cases)
PY
exit "$mvn_status"
