#!/usr/bin/env bats

load "$BATS_PLUGIN_PATH/load.bash"

setup() {
  export BUILDKITE_PIPELINE_SLUG="my-pipeline"
  export BUILDKITE_BUILD_NUMBER="42"
  export BUILDKITE_JOB_ID="job-123"
  export TMPDIR="$BATS_TEST_TMPDIR"
  export TESTINGBOT_KEY="test-key"
  export TESTINGBOT_SECRET="test-secret"
}

@test "fails when credentials are missing" {
  unset TESTINGBOT_KEY TESTINGBOT_SECRET

  run "$PWD/hooks/environment"

  assert_failure
  assert_output --partial "credentials missing"
  assert_output --partial "TESTINGBOT_KEY"
}

@test "succeeds without credentials when all features are disabled" {
  unset TESTINGBOT_KEY TESTINGBOT_SECRET
  export BUILDKITE_PLUGIN_TESTINGBOT_TUNNEL="false"
  export BUILDKITE_PLUGIN_TESTINGBOT_UPDATE_STATUS="false"
  export BUILDKITE_PLUGIN_TESTINGBOT_ANNOTATE="false"

  run "$PWD/hooks/environment"

  assert_success
}

@test "exports default build identifier from pipeline slug and build number" {
  run "$PWD/hooks/environment"

  assert_success
  assert_output --partial "TESTINGBOT_BUILD=my-pipeline-42"
}

@test "build-identifier config overrides the default" {
  export BUILDKITE_PLUGIN_TESTINGBOT_BUILD_IDENTIFIER="custom-build"

  run "$PWD/hooks/environment"

  assert_success
  assert_output --partial "TESTINGBOT_BUILD=custom-build"
}

@test "resolves credentials from custom env var names" {
  unset TESTINGBOT_KEY TESTINGBOT_SECRET
  export MY_TB_KEY="other-key"
  export MY_TB_SECRET="other-secret"
  export BUILDKITE_PLUGIN_TESTINGBOT_API_KEY_ENV="MY_TB_KEY"
  export BUILDKITE_PLUGIN_TESTINGBOT_API_SECRET_ENV="MY_TB_SECRET"

  run "$PWD/hooks/environment"

  assert_success
}

@test "substitutes %job-id% in the tunnel identifier" {
  export BUILDKITE_PLUGIN_TESTINGBOT_TUNNEL_IDENTIFIER="tb-%job-id%"

  run "$PWD/hooks/environment"

  assert_success
  assert_output --partial "TESTINGBOT_TUNNEL_IDENTIFIER=tb-job-123"
}

@test "exports the configured sessions file path" {
  export BUILDKITE_PLUGIN_TESTINGBOT_SESSIONS_FILE="out/sessions.txt"

  run "$PWD/hooks/environment"

  assert_success
  assert_output --partial "TESTINGBOT_SESSIONS_FILE=out/sessions.txt"
}
