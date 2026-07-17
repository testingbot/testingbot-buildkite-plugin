#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

setup() {
  export BUILDKITE_JOB_ID="job-123"
  export BUILDKITE_PIPELINE_SLUG="my-pipeline"
  export BUILDKITE_BUILD_NUMBER="42"
  export BUILDKITE_BUILD_URL="https://buildkite.com/acme/my-pipeline/builds/42"
  export BUILDKITE_COMMAND_EXIT_STATUS="0"
  export TESTINGBOT_KEY="test-key"
  export TESTINGBOT_SECRET="test-secret"
  export TESTINGBOT_BUILD="my-pipeline-42"
  export TESTINGBOT_PLUGIN_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export TESTINGBOT_PLUGIN_POLL_INTERVAL="0"
  export BUILDKITE_BUILD_CHECKOUT_PATH="$BATS_TEST_TMPDIR/checkout"
  mkdir -p "$TESTINGBOT_PLUGIN_STATE_DIR" "$BUILDKITE_BUILD_CHECKOUT_PATH"

  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"

  export CURL_LOG="$BATS_TEST_TMPDIR/curl.log"
  export AGENT_LOG="$BATS_TEST_TMPDIR/agent.log"
  export ANNOTATION_FILE="$BATS_TEST_TMPDIR/annotation.md"
  export FIXTURES="$PWD/tests/fixtures"

  # Fake curl dispatching on URL; credentials config on stdin is drained
  cat >"$FAKE_BIN/curl" <<'FAKE'
#!/bin/bash
cat >/dev/null 2>&1 || true
echo "curl $*" >>"$CURL_LOG"
args="$*"
out=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-o" ]]; then out="$a"; fi
  prev="$a"
done
if [[ "$args" == *"-X PUT"* ]]; then
  echo '{"success": true}'
elif [[ "$args" == *"/builds/"* ]]; then
  cat "${BUILD_TESTS_RESPONSE:-$FIXTURES/build-tests.json}"
elif [[ "$args" == *"/tests/ddd444"* ]]; then
  cat "$FIXTURES/test-details-failed.json"
elif [[ "$args" == *"/tests/"* ]]; then
  cat "$FIXTURES/test-details.json"
elif [[ -n "$out" ]]; then
  echo "fake-binary" >"$out"
fi
FAKE
  chmod +x "$FAKE_BIN/curl"

  cat >"$FAKE_BIN/buildkite-agent" <<'FAKE'
#!/bin/bash
echo "buildkite-agent $*" >>"$AGENT_LOG"
if [[ "$1" == "annotate" ]]; then
  cat >"$ANNOTATION_FILE"
fi
FAKE
  chmod +x "$FAKE_BIN/buildkite-agent"
}

@test "does nothing when update-status and annotate are disabled" {
  export BUILDKITE_PLUGIN_TESTINGBOT_UPDATE_STATUS="false"
  export BUILDKITE_PLUGIN_TESTINGBOT_ANNOTATE="false"

  run "$PWD/hooks/post-command"

  assert_success
  refute [ -f "$CURL_LOG" ]
}

@test "updates status for sessions from the sessions file" {
  export BUILDKITE_PLUGIN_TESTINGBOT_ANNOTATE="false"
  printf 'aaa111bbb222ccc333\nddd444eee555fff666 failed login-spec\n' \
    >"$BUILDKITE_BUILD_CHECKOUT_PATH/testingbot-sessions.txt"

  run "$PWD/hooks/post-command"

  assert_success
  run cat "$CURL_LOG"
  assert_output --partial "tests/aaa111bbb222ccc333"
  assert_output --partial "tests/ddd444eee555fff666"
  # step passed, so the first session is marked passed…
  assert_output --partial "test[success]=1"
  # …but the explicit per-line status wins for the second
  assert_output --partial "test[success]=0"
}

@test "marks all sessions failed when the command failed" {
  export BUILDKITE_PLUGIN_TESTINGBOT_ANNOTATE="false"
  export BUILDKITE_COMMAND_EXIT_STATUS="1"
  printf 'aaa111bbb222ccc333\n' >"$BUILDKITE_BUILD_CHECKOUT_PATH/testingbot-sessions.txt"

  run "$PWD/hooks/post-command"

  assert_success
  run cat "$CURL_LOG"
  assert_output --partial "test[success]=0"
}

@test "skips status updates when the job was cancelled" {
  export BUILDKITE_PLUGIN_TESTINGBOT_ANNOTATE="false"
  export BUILDKITE_COMMAND_EXIT_STATUS="-1"
  printf 'aaa111bbb222ccc333\n' >"$BUILDKITE_BUILD_CHECKOUT_PATH/testingbot-sessions.txt"

  run "$PWD/hooks/post-command"

  assert_success
  refute [ -f "$CURL_LOG" ]
}

@test "falls back to the builds API when no sessions file exists" {
  command -v jq >/dev/null || skip "jq not installed"
  export BUILDKITE_PLUGIN_TESTINGBOT_ANNOTATE="false"

  run "$PWD/hooks/post-command"

  assert_success
  run cat "$CURL_LOG"
  assert_output --partial "builds/my-pipeline-42"
  assert_output --partial "tests/aaa111bbb222ccc333"
  assert_output --partial "tests/ddd444eee555fff666"
}

@test "creates a rich annotation with results table and failure details" {
  command -v jq >/dev/null || skip "jq not installed"
  export BUILDKITE_PLUGIN_TESTINGBOT_UPDATE_STATUS="false"
  export BUILDKITE_PLUGIN_TESTINGBOT_THUMBNAILS="false"
  printf 'aaa111bbb222ccc333\nddd444eee555fff666\n' \
    >"$BUILDKITE_BUILD_CHECKOUT_PATH/testingbot-sessions.txt"

  run "$PWD/hooks/post-command"

  assert_success
  run cat "$AGENT_LOG"
  assert_output --partial "annotate --context testingbot-job-123 --style success"
  run cat "$ANNOTATION_FILE"
  assert_output --partial "TestingBot results — 1 passed, 1 failed"
  assert_output --partial "checkout flow"
  assert_output --partial "login spec"
  assert_output --partial "<details>"
  refute_output --partial "<iframe"
  refute_output --partial "<script"
}

@test "downloads failure thumbnails and uploads them as artifacts" {
  command -v jq >/dev/null || skip "jq not installed"
  export BUILDKITE_PLUGIN_TESTINGBOT_UPDATE_STATUS="false"
  printf 'ddd444eee555fff666\n' >"$BUILDKITE_BUILD_CHECKOUT_PATH/testingbot-sessions.txt"

  run "$PWD/hooks/post-command"

  assert_success
  run cat "$AGENT_LOG"
  assert_output --partial "artifact upload testingbot/*.png"
  run cat "$ANNOTATION_FILE"
  assert_output --partial "artifact://testingbot/ddd444eee555fff666.png"
}

@test "annotates a setup notice when no sessions are found" {
  command -v jq >/dev/null || skip "jq not installed"
  echo '{"data": [], "meta": {}}' >"$BATS_TEST_TMPDIR/empty.json"
  export BUILD_TESTS_RESPONSE="$BATS_TEST_TMPDIR/empty.json"

  run "$PWD/hooks/post-command"

  assert_success
  run cat "$ANNOTATION_FILE"
  assert_output --partial "no test sessions found"
}

@test "API failures warn but do not fail the step by default" {
  export BUILDKITE_PLUGIN_TESTINGBOT_ANNOTATE="false"
  printf 'aaa111bbb222ccc333\n' >"$BUILDKITE_BUILD_CHECKOUT_PATH/testingbot-sessions.txt"
  cat >"$FAKE_BIN/curl" <<'FAKE'
#!/bin/bash
cat >/dev/null 2>&1 || true
exit 22
FAKE
  chmod +x "$FAKE_BIN/curl"

  run "$PWD/hooks/post-command"

  assert_success
  assert_output --partial "Failed to update status"
}

@test "API failures fail the step when strict is enabled" {
  export BUILDKITE_PLUGIN_TESTINGBOT_ANNOTATE="false"
  export BUILDKITE_PLUGIN_TESTINGBOT_STRICT="true"
  printf 'aaa111bbb222ccc333\n' >"$BUILDKITE_BUILD_CHECKOUT_PATH/testingbot-sessions.txt"
  cat >"$FAKE_BIN/curl" <<'FAKE'
#!/bin/bash
cat >/dev/null 2>&1 || true
exit 22
FAKE
  chmod +x "$FAKE_BIN/curl"

  run "$PWD/hooks/post-command"

  assert_failure
}
