#!/usr/bin/env bash
set -euo pipefail

phase=${1:?phase required}
managed=packages/managed-agent-server
verification="$managed/verification/target"
reports="$RUNNER_TEMP/qwen-reports"
methods=asyncSegmentReceiptNamesTheOriginalCaptureStreamAndOrdinal+seededLegacySucceededReceiptSurvivesReplacementAndOriginalReplay+durableContentKeepsResourceReceiptAndExactReplay+sealAndPageKeepTheirOwnReceiptShapes+historicalReplayDoesNotReadAndAnotherIdForTheSameSlotCompletesDirectly
control=historicalReplayDoesNotReadAndAnotherIdForTheSameSlotCompletesDirectly
maven=(mvn --settings "$RUNNER_TEMP/m2-settings/settings.xml" --toolchains "$RUNNER_TEMP/m2-settings/toolchains.xml"
       "-Dmaven.repo.local=$RUNNER_TEMP/qwen-m2" --batch-mode --no-transfer-progress)
test "$(git rev-parse HEAD)" = "$SOURCE_SHA"
test "$(git rev-parse 'HEAD^{tree}')" = "$SOURCE_TREE"
test "$(git remote get-url origin)" = "https://github.com/$SOURCE_REPO"
git diff HEAD --exit-code

for arm in base variant; do
    destination="$reports/$phase/$arm"
    mkdir -p "$destination"
    patches=()
    case "$phase" in
        h2|mysql) patches+=("$FIXTURE_ROOT/receipt-probes.patch") ;;
        hosted) patches+=("$FIXTURE_ROOT/hosted-observer.patch") ;;
        checkstyle) [[ "$arm" = variant ]] || continue ;;
        *) exit 2 ;;
    esac
    if [[ "$arm" = variant ]]; then
        patches+=("$FIXTURE_ROOT/serializer.patch")
    fi

    for patch in "${patches[@]}"; do
        git apply --check "$patch"
        git apply "$patch"
    done
    git diff --check
    git diff --binary HEAD > "$RUNNER_TEMP/qwen-expected.diff"
    diff_hash=$(sha256sum "$RUNNER_TEMP/qwen-expected.diff" | cut -d ' ' -f1)
    printf '%s\n' "$diff_hash" > "$destination/tracked-diff.sha256"
    printf '%s\n' "$SOURCE_SHA $SOURCE_TREE $GITHUB_SHA" > "$destination/identity.txt"

    sql_args=("-Dmysql.url=jdbc:mysql://127.0.0.1:$MYSQL_PORT/qwen_${phase}_${arm}?allowPublicKeyRetrieval=true&useSSL=false"
              "-Dmysql.user=root" "-Dmysql.password=$MYSQL_PASSWORD")
    set +e
    case "$phase" in
        h2)
            rm -f "$verification"/surefire-reports/TEST-*.ToolPublicationAsyncVerificationTest.xml
            "${maven[@]}" -f "$managed/pom.xml" \
                "-Dtest=ToolPublicationAsyncVerificationTest#$methods" test
            command_status=$?
            ;;
        mysql)
            rm -f "$verification"/failsafe-reports/TEST-*.ToolPublicationAsyncVerificationMySqlIT.xml
            "${maven[@]}" -f "$managed/pom.xml" -Pmysql-integration \
                "-Dtest=ToolPublicationAsyncVerificationTest#$control" \
                "-Dit.test=ToolPublicationAsyncVerificationMySqlIT#$methods" "${sql_args[@]}" verify
            command_status=$?
            ;;
        hosted)
            rm -f "$verification"/failsafe-reports/TEST-*.HostedShellLifecycleRecoveryIT.xml \
                "$verification"/l4-shell-lifecycle/resident-expiry/receipt-diagnostics.json
            "${maven[@]}" -f "$managed/pom.xml" -Phosted-harness-mysql \
                -Dit.test=HostedShellLifecycleRecoveryIT "-Dnode.executable=$(command -v node)" \
                "-Dqwen.cli.entry=$GITHUB_WORKSPACE/source/dist/cli.js" "${sql_args[@]}" verify
            command_status=$?
            ;;
        checkstyle)
            "${maven[@]}" -f "$managed/pom.xml" \
                checkstyle:check checkstyle:check@runtime-broker-checkstyle
            command_status=$?
            ;;
    esac
    set -e
    printf '%s\n' "$command_status" > "$destination/maven.exit"
    case "$phase" in
        h2)
            find "$verification/surefire-reports" -maxdepth 1 -name 'TEST-*.ToolPublicationAsyncVerificationTest.xml' \
                -exec cp -t "$destination" -- {} + 2>/dev/null || true
            ;;
        mysql)
            find "$verification/failsafe-reports" -maxdepth 1 -name 'TEST-*.ToolPublicationAsyncVerificationMySqlIT.xml' \
                -exec cp -t "$destination" -- {} + 2>/dev/null || true
            ;;
        hosted)
            python3 "$FIXTURE_ROOT/report.py" --hosted-source "$verification" --destination "$destination"
            ;;
    esac
    git diff --binary HEAD > "$RUNNER_TEMP/qwen-observed.diff"
    cmp "$RUNNER_TEMP/qwen-expected.diff" "$RUNNER_TEMP/qwen-observed.diff"
    for ((i=${#patches[@]}-1; i>=0; i--)); do
        git apply --check --reverse "${patches[i]}"
        git apply --reverse "${patches[i]}"
    done
    git diff HEAD --exit-code
    printf '0\n' > "$destination/source-restore.exit"
done
