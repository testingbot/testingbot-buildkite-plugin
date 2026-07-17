#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

setup() {
  export BUILDKITE_JOB_ID="job-123"
  export TESTINGBOT_KEY="test-key"
  export TESTINGBOT_SECRET="test-secret"
  export TESTINGBOT_PLUGIN_STATE_DIR="$BATS_TEST_TMPDIR/state"
  export TESTINGBOT_PLUGIN_CACHE_DIR="$BATS_TEST_TMPDIR/cache"
  export TESTINGBOT_PLUGIN_POLL_INTERVAL="0"

  export FAKE_BIN="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$FAKE_BIN" "$TESTINGBOT_PLUGIN_STATE_DIR" "$TESTINGBOT_PLUGIN_CACHE_DIR"
  export PATH="$FAKE_BIN:$PATH"

  cat >"$FAKE_BIN/buildkite-agent" <<'FAKE'
#!/bin/bash
echo "buildkite-agent $*" >>"${AGENT_LOG:-/dev/null}"
FAKE
  chmod +x "$FAKE_BIN/buildkite-agent"
  export AGENT_LOG="$BATS_TEST_TMPDIR/agent.log"
}

make_cached_jar() {
  echo "fake jar" >"$TESTINGBOT_PLUGIN_CACHE_DIR/testingbot-tunnel.jar"
}

# Fake java that touches the readyfile it was given and lingers briefly
make_ready_java() {
  cat >"$FAKE_BIN/java" <<'FAKE'
#!/bin/bash
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "--readyfile" ]]; then touch "$2"; fi
  echo "arg: $1" >>"${JAVA_LOG:-/dev/null}"
  shift
done
sleep 2
FAKE
  chmod +x "$FAKE_BIN/java"
  export JAVA_LOG="$BATS_TEST_TMPDIR/java.log"
  # real 1s poll so the backgrounded fake java wins the race to the readyfile
  export TESTINGBOT_PLUGIN_POLL_INTERVAL="1"
}

@test "skips when tunnel is disabled" {
  export BUILDKITE_PLUGIN_TESTINGBOT_TUNNEL="false"

  run "$PWD/hooks/pre-command"

  assert_success
  assert_output --partial "Tunnel disabled"
}

@test "starts the tunnel and waits for the readyfile" {
  make_cached_jar
  make_ready_java

  run "$PWD/hooks/pre-command"

  assert_success
  assert_output --partial "tunnel is ready"
  assert [ -f "$TESTINGBOT_PLUGIN_STATE_DIR/tunnel.pid" ]
}

@test "passes tunnel identifier and extra args to the tunnel" {
  make_cached_jar
  make_ready_java
  export TESTINGBOT_TUNNEL_IDENTIFIER="tb-job-123"
  export BUILDKITE_PLUGIN_TESTINGBOT_TUNNEL_ARGS_0="--nocache"
  export BUILDKITE_PLUGIN_TESTINGBOT_TUNNEL_ARGS_1="--se-port"
  export BUILDKITE_PLUGIN_TESTINGBOT_TUNNEL_ARGS_2="4446"

  run "$PWD/hooks/pre-command"

  assert_success
  run cat "$JAVA_LOG"
  assert_output --partial "arg: --tunnel-identifier"
  assert_output --partial "arg: tb-job-123"
  assert_output --partial "arg: --nocache"
  assert_output --partial "arg: 4446"
}

@test "downloads the tunnel archive when the jar is not cached" {
  make_ready_java
  cat >"$FAKE_BIN/curl" <<'FAKE'
#!/bin/bash
out=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-o" ]]; then out="$2"; shift; fi
  shift
done
echo "fake zip" >"$out"
FAKE
  chmod +x "$FAKE_BIN/curl"
  cat >"$FAKE_BIN/unzip" <<'FAKE'
#!/bin/bash
dest=""
while [[ $# -gt 0 ]]; do
  if [[ "$1" == "-d" ]]; then dest="$2"; shift; fi
  shift
done
echo "fake jar" >"$dest/testingbot-tunnel.jar"
FAKE
  chmod +x "$FAKE_BIN/unzip"

  run "$PWD/hooks/pre-command"

  assert_success
  assert_output --partial "Downloading TestingBot tunnel"
  assert [ -f "$TESTINGBOT_PLUGIN_CACHE_DIR/testingbot-tunnel.jar" ]
}

@test "fails fast when the tunnel process dies before becoming ready" {
  make_cached_jar
  cat >"$FAKE_BIN/java" <<'FAKE'
#!/bin/bash
echo "401 Unauthorized"
exit 1
FAKE
  chmod +x "$FAKE_BIN/java"

  run "$PWD/hooks/pre-command"

  assert_failure
  assert_output --partial "died before becoming ready"
  assert_output --partial "401 Unauthorized"
}

@test "fails when the tunnel does not become ready within the timeout" {
  make_cached_jar
  cat >"$FAKE_BIN/java" <<'FAKE'
#!/bin/bash
exec sleep 10
FAKE
  chmod +x "$FAKE_BIN/java"
  export BUILDKITE_PLUGIN_TESTINGBOT_TUNNEL_READY_TIMEOUT="2"
  export TESTINGBOT_PLUGIN_POLL_INTERVAL="1"

  run "$PWD/hooks/pre-command"

  assert_failure
  assert_output --partial "did not become ready within 2s"
}
