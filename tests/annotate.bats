#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

setup() {
  command -v jq >/dev/null || skip "jq not installed"
  export TESTINGBOT_KEY="test-key"
  export TESTINGBOT_SECRET="test-secret"
  export BUILDKITE_LABEL="e2e-chrome"
  export BUILDKITE_JOB_ID="job-123"

  # shellcheck source=lib/shared.bash
  source "$PWD/lib/shared.bash"
  # shellcheck source=lib/api.bash
  source "$PWD/lib/api.bash"
  # shellcheck source=lib/annotate.bash
  source "$PWD/lib/annotate.bash"

  JSONL="$BATS_TEST_TMPDIR/tests.jsonl"
  cat "$PWD/tests/fixtures/test-details.json" "$PWD/tests/fixtures/test-details-failed.json" >"$JSONL"
}

@test "renders summary counts, table rows and failure details" {
  run render_annotation "$JSONL" "true" "my-pipeline-42" ""

  assert_success
  assert_output --partial "TestingBot results — 1 passed, 1 failed"
  assert_output --partial "| :white_check_mark: | [checkout flow]("
  assert_output --partial "| :x: | [login spec]("
  assert_output --partial "chrome 126 · WIN11"
  assert_output --partial "<details>"
  assert_output --partial "<summary><code>login spec — failure detail</code></summary>"
}

@test "share links use auth-hash URLs" {
  run render_annotation "$JSONL" "true" "my-pipeline-42" ""

  assert_success
  assert_output --partial "https://testingbot.com/tests/aaa111bbb222ccc333?auth="
  assert_output --partial "https://testingbot.com/tests/aaa111bbb222ccc333.mp4?auth="
  refute_output --partial "/members/tests/"
}

@test "without share links, URLs require login and carry no auth hashes" {
  run render_annotation "$JSONL" "false" "my-pipeline-42" ""

  assert_success
  assert_output --partial "https://testingbot.com/members/tests/aaa111bbb222ccc333"
  refute_output --partial "tests/aaa111bbb222ccc333?auth="
}

@test "embeds artifact thumbnails for failed tests when available" {
  mkdir -p "$BATS_TEST_TMPDIR/artifacts/testingbot"
  echo "png" >"$BATS_TEST_TMPDIR/artifacts/testingbot/ddd444eee555fff666.png"

  run render_annotation "$JSONL" "true" "my-pipeline-42" "$BATS_TEST_TMPDIR/artifacts"

  assert_success
  assert_output --partial '<img src="artifact://testingbot/ddd444eee555fff666.png"'
}

@test "never emits iframe or script tags" {
  run render_annotation "$JSONL" "true" "my-pipeline-42" ""

  assert_success
  refute_output --partial "<iframe"
  refute_output --partial "<script"
  refute_output --partial "<style"
}

@test "truncates long result tables with a view-all link" {
  : >"$JSONL"
  for i in $(seq 1 25); do
    jq --arg sid "session-$i" '.session_id = $sid' "$PWD/tests/fixtures/test-details.json" >>"$JSONL"
  done

  run render_annotation "$JSONL" "true" "my-pipeline-42" ""

  assert_success
  assert_output --partial "Showing 20 of 25 tests"
  refute_output --partial "session-21?auth"
}
