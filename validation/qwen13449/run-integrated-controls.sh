#!/usr/bin/env bash
set -euo pipefail

expected_head=$1
expected_tree=$2
expected_fixture=$3
fixture=$(realpath "$4")
scratch=$(mktemp -d "${RUNNER_TEMP:-/tmp}/qwen13449-controls.XXXXXXXX")
repo=$(pwd)

assert_source() {
  test "$(git -C "$repo" rev-parse HEAD)" = "$expected_head" || return
  test "$(git -C "$repo" rev-parse 'HEAD^{tree}')" = "$expected_tree" || return
  git -C "$repo" diff HEAD --exit-code || return
  test -z "$(git -C "$repo" status --porcelain --untracked-files=normal)"
}

finish() {
  local prior_result="$?"
  local source_result=0
  assert_source || source_result=$?
  rm -rf -- "$scratch"
  if (( prior_result != 0 )); then
    exit "$prior_result"
  fi
  exit "$source_result"
}

trap finish EXIT
assert_source
echo "$expected_fixture  $fixture" | sha256sum --check
test "$(node --version)" = v22.23.4
test "$(corepack pnpm --version)" = 11.24.0
git --version
printf 'EXACT_SOURCE head=%s tree=%s runner=%s\n' "$expected_head" "$expected_tree" "${RUNNER_ENVIRONMENT:-local}"

export CI=true QWEN_SANDBOX=false QWEN_CODE_MODELS_DEV_REFRESH=off
test -s dist/cli.js
test -x node_modules/.bin/tsx
mkdir -p "$scratch/direct" "$scratch/global"
export QWEN_HOME="$scratch/global"
env QWEN_E2E_RENDERER=ink QWEN_E2E_RUNTIME=node \
  timeout 150s ./node_modules/.bin/tsx "$fixture" "$repo" "$scratch/direct"
env QWEN_E2E_RENDERER=ink QWEN_E2E_RUNTIME=node \
  npm run test:integration:sandbox:none -- \
    interactive/tui-foreground-shell.test.ts -t 'cancels a focused shell'
npm run test:integration:sandbox:none -- \
  cli/acp-agent-loop-parity.test.ts -t 'a background shell whose result starts a notification turn|cancels a tool-result request whose UserPromptSubmit hook is still running'
npm run test:integration:sandbox:none -- cli/acp-workflow-mode.test.ts
npm run test:integration:sandbox:none -- cli/qwen-serve-scheduled-task-delete.test.ts
