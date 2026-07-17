#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

setup() {
  export BUILDKITE_JOB_ID="job-123"
  export TESTINGBOT_PLUGIN_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export TESTINGBOT_PLUGIN_POLL_INTERVAL="0"

  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN"
  export PATH="$FAKE_BIN:$PATH"

  cat >"$FAKE_BIN/buildkite-agent" <<'FAKE'
#!/bin/bash
echo "buildkite-agent $*" >>"${AGENT_LOG:-/dev/null}"
FAKE
  chmod +x "$FAKE_BIN/buildkite-agent"
  export AGENT_LOG="$BATS_TEST_TMPDIR/agent.log"
}

@test "exits 0 when no state directory exists" {
  run "$PWD/hooks/pre-exit"

  assert_success
}

@test "stops a running tunnel and removes the state directory" {
  mkdir -p "$TESTINGBOT_PLUGIN_STATE_DIR"
  sleep 60 &
  tunnel_pid=$!
  echo "$tunnel_pid" >"$TESTINGBOT_PLUGIN_STATE_DIR/tunnel.pid"
  echo "log content" >"$TESTINGBOT_PLUGIN_STATE_DIR/tunnel.log"

  run "$PWD/hooks/pre-exit"

  assert_success
  assert_output --partial "Stopping TestingBot tunnel"
  refute [ -d "$TESTINGBOT_PLUGIN_STATE_DIR" ]
  run kill -0 "$tunnel_pid"
  assert_failure
}

@test "uploads the tunnel log as an artifact" {
  mkdir -p "$TESTINGBOT_PLUGIN_STATE_DIR"
  echo "log content" >"$TESTINGBOT_PLUGIN_STATE_DIR/tunnel.log"

  run "$PWD/hooks/pre-exit"

  assert_success
  run cat "$AGENT_LOG"
  assert_output --partial "artifact upload tunnel.log"
}

@test "is idempotent with a stale pid file" {
  mkdir -p "$TESTINGBOT_PLUGIN_STATE_DIR"
  echo "99999999" >"$TESTINGBOT_PLUGIN_STATE_DIR/tunnel.pid"

  run "$PWD/hooks/pre-exit"

  assert_success
}

@test "keeps the state directory when TESTINGBOT_PLUGIN_KEEP_STATE is set" {
  mkdir -p "$TESTINGBOT_PLUGIN_STATE_DIR"
  export TESTINGBOT_PLUGIN_KEEP_STATE="true"

  run "$PWD/hooks/pre-exit"

  assert_success
  assert [ -d "$TESTINGBOT_PLUGIN_STATE_DIR" ]
}
