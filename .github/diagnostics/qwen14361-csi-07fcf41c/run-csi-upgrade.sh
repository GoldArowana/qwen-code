#!/usr/bin/env bash
set -euo pipefail

phase=${1:?phase required}
managed=packages/managed-agent-server
verification="$managed/verification"
fixture="$verification/src/test/java/com/alibaba/qwen/code/managedagent/ToolPublicationCsiUpgradeTest.java"
reports="$RUNNER_TEMP/qwen-reports"
state="$RUNNER_TEMP/qwen-csi-state"
maven=(mvn --settings "$RUNNER_TEMP/m2-settings/settings.xml" --toolchains "$RUNNER_TEMP/m2-settings/toolchains.xml"
       "-Dmaven.repo.local=$RUNNER_TEMP/qwen-m2" --batch-mode --no-transfer-progress)
test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
test "$(git rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE"
test "$(git remote get-url origin)" = "https://github.com/$SOURCE_REPO"
git diff HEAD --exit-code
mkdir -p "$reports" "$state"
base=$SOURCE_SHA

# Install the exact captured commit object only after the proposed patch produces its bound tree.
bind_candidate() {
    local tree
    git add --update
    tree=$(git write-tree)
    test "$tree" = "$CANDIDATE_TREE"
    test "$(git hash-object -t commit -w "$FIXTURE_ROOT/candidate.commit-object")" = "$CANDIDATE_SHA"
    test "$(git rev-parse "$CANDIDATE_SHA^{tree}")" = "$CANDIDATE_TREE"
    test "$(git rev-parse "$CANDIDATE_SHA^")" = "$SOURCE_SHA"
    git update-ref --no-deref HEAD "$CANDIDATE_SHA" "$SOURCE_SHA"
    git diff HEAD --exit-code
    printf '%s %s %s\n' "$CANDIDATE_SHA" "$CANDIDATE_TREE" "$GITHUB_SHA" > "$reports/candidate-identity.txt"
}

cleanup() {
    local rc=$?
    trap - EXIT
    if [[ -f "$fixture" ]]; then
        rm "$fixture"
    fi
    git restore --source="$base" --staged --worktree -- $(cut -f2 "$FIXTURE_ROOT/candidate-files.txt") \
        "$verification/src/test/java/com/alibaba/qwen/code/managedagent/PublicationJournalFixture.java"
    if [[ "$(git rev-parse HEAD)" == "$CANDIDATE_SHA" ]]; then
        git update-ref --no-deref HEAD "$SOURCE_SHA" "$CANDIDATE_SHA"
    fi
    git diff HEAD --exit-code
    test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
    test "$(git rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE"
    printf '0\n' > "$reports/$phase-source-restore.exit"
    exit "$rc"
}
test ! -e "$fixture"
trap cleanup EXIT

collect_test() {
    local label="$1" class="$2"
    local dir="$verification/target/surefire-reports"
    find "$dir" -maxdepth 1 -name "TEST-*.$class.xml" -exec cp -t "$reports/$label" -- {} +
    local matches
    matches=("$reports/$label"/TEST-*."$class".xml)
    test -s "${matches[0]}"
}

compare_reports() {
    python3 - "$reports" <<'PY'
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

reports = Path(sys.argv[1])
for phase in ("focused-base", "focused-head"):
    file, = (reports / phase).glob("TEST-*.ToolPublicationAsyncVerificationTest.xml")
    suite = ET.parse(file).getroot()
    cases = suite.findall("testcase")
    assert len(cases) == 3, [(case.get("name")) for case in cases]
    expected = 0
    for case in cases:
        name = case.get("name")
        fail = case.find("failure")
        assert case.find("error") is None and case.find("skipped") is None, name
        if phase == "focused-base" and name.startswith("asyncSegmentReceiptRetainsCaptureIdentityOnExactReplay"):
            expected += 1
            assert fail is not None, name
            text = fail.get("message", "") + (fail.text or "")
            assert "managed-tool-segment" in text and "captureId" in text, name
        else:
            assert fail is None, name
    assert expected == (2 if phase == "focused-base" else 0)
print("Base: two typed-receipt assertion failures and one control pass. Exact head: three passes.")
PY
}

case "$phase" in
    focused)
        class=ToolPublicationAsyncVerificationTest
        methods=asyncSegmentReceiptRetainsCaptureIdentityOnExactReplay+historicalReplayDoesNotReadAndAnotherIdForTheSameSlotCompletesDirectly
        for arm in base head; do
            label=focused-"$arm"
            mkdir "$reports/$label"
            if [[ "$arm" == base ]]; then
                git apply --check "$FIXTURE_ROOT/regression.patch"
                git apply "$FIXTURE_ROOT/regression.patch"
            else
                git apply --check "$FIXTURE_ROOT/serializer.patch"
                git apply "$FIXTURE_ROOT/serializer.patch"
                bind_candidate
            fi
            git diff --check HEAD
            set +e
            "${maven[@]}" -f "$managed/pom.xml" "-Dtest=$class#$methods" test
            status=$?
            set -e
            printf '%s\n' "$status" > "$reports/$label/maven.exit"
            collect_test "$label" "$class"
            if [[ "$arm" == base ]]; then
                test "$status" -ne 0
                git diff --exit-code HEAD -- "$managed/persistence"
                git apply --check --reverse "$FIXTURE_ROOT/regression.patch"
            else
                test "$status" -eq 0
                git diff HEAD --exit-code
            fi
        done
        compare_reports | tee "$reports/focused-verified.txt"
        "${maven[@]}" -f "$managed/pom.xml" checkstyle:check checkstyle:check@runtime-broker-checkstyle
        git diff HEAD --exit-code
        printf '0\n' > "$reports/candidate-checkstyle.exit"
        ;;
    restart)
        class=ToolPublicationCsiUpgradeTest
        git apply --check "$FIXTURE_ROOT/reopen-fixture.patch"
        git apply "$FIXTURE_ROOT/reopen-fixture.patch"
        cp "$FIXTURE_ROOT/ToolPublicationCsiUpgradeTest.java" "$fixture"
        sql=()
        for catalog in legacy fresh; do
            sql+=("-Dqwen.csi.$catalog.url=jdbc:mysql://127.0.0.1:$MYSQL_PORT/qwen_csi_$catalog?allowPublicKeyRetrieval=true&useSSL=false")
        done
        for arm in legacy replay; do
            mkdir "$reports/$arm"
            if [[ "$arm" == legacy ]]; then
                method=createLegacySettledPublication
                git diff --exit-code HEAD -- "$managed/persistence"
            else
                method=replayLegacyAndVerifyFreshReceiptsAfterUpgrade
                git apply --check "$FIXTURE_ROOT/candidate.patch"
                git apply "$FIXTURE_ROOT/candidate.patch"
                # The verification-only test patch stays outside the candidate source tree.
                git add -- $(cut -f2 "$FIXTURE_ROOT/candidate-files.txt")
                test "$(git write-tree)" = "$CANDIDATE_TREE"
                test "$(git hash-object -t commit -w "$FIXTURE_ROOT/candidate.commit-object")" = "$CANDIDATE_SHA"
                git update-ref --no-deref HEAD "$CANDIDATE_SHA" "$SOURCE_SHA"
                git diff --exit-code HEAD -- "$managed/persistence"
            fi
            set +e
            "${maven[@]}" -f "$managed/pom.xml" "-Dtest=$class#$method" "-Dqwen.csi.root=$state" \
                "${sql[@]}" test
            status=$?
            set -e
            printf '%s\n' "$status" > "$reports/$arm/maven.exit"
            find "$state" -maxdepth 1 -name '*.json' -exec cp -t "$reports" -- {} +
            collect_test "$arm" "$class"
            test "$status" -eq 0
            test "$(git hash-object "$fixture")" = "$(git hash-object "$FIXTURE_ROOT/ToolPublicationCsiUpgradeTest.java")"
            git apply --check --reverse "$FIXTURE_ROOT/reopen-fixture.patch"
        done
        ;;
    *) exit 2 ;;
esac
