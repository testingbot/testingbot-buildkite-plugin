#!/bin/bash

PLUGIN_PREFIX="TESTINGBOT"

tb_log() {
  echo "[testingbot] $*"
}

tb_warn() {
  echo "[testingbot] WARNING: $*" >&2
}

tb_die() {
  echo "[testingbot] ERROR: $*" >&2
  exit 1
}

# Reads a single plugin config value with an optional default
plugin_read_config() {
  local var="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
  local default="${2:-}"
  echo "${!var:-$default}"
}

# Returns 0 when a boolean plugin config value (with default) is truthy
plugin_read_bool() {
  local value
  value="$(plugin_read_config "$1" "$2")"
  [[ "${value}" =~ ^(true|on|1)$ ]]
}

# Reads a list plugin config value into the global `result` array.
# Handles both indexed (_0, _1, ...) and bare single-value forms.
plugin_read_list_into_result() {
  local prefix="BUILDKITE_PLUGIN_${PLUGIN_PREFIX}_${1}"
  local parameter="${prefix}_0"
  result=()

  if [[ -n "${!parameter:-}" ]]; then
    local i=0
    while [[ -n "${!parameter:-}" ]]; do
      result+=("${!parameter}")
      i=$((i + 1))
      parameter="${prefix}_${i}"
    done
  elif [[ -n "${!prefix:-}" ]]; then
    result+=("${!prefix}")
  fi

  [[ ${#result[@]} -gt 0 ]] || return 1
}

# Per-job state directory shared between hooks. Exported by the environment
# hook and recomputed deterministically everywhere else as a fallback.
tb_state_dir() {
  echo "${TESTINGBOT_PLUGIN_STATE_DIR:-${TMPDIR:-/tmp}/testingbot-buildkite-plugin/${BUILDKITE_JOB_ID:-no-job}}"
}
