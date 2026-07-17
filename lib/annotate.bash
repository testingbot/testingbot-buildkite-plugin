#!/bin/bash

# Renders the build annotation from collected test details.
#
# $1 = jsonl file with one GET /v1/tests/:id response per line
# $2 = "true" to use no-login share URLs
# $3 = build identifier
# $4 = directory of downloaded thumbnails (empty = no thumbnails); files are
#      expected at <dir>/testingbot/<session_id>.png and uploaded as artifacts
#      by the caller, so the annotation references artifact:// paths
#
# Output is Markdown plus only sanitizer-allowed HTML (<details>, <summary>,
# <img>, <a>, <code>) — never <iframe>/<script>/<style>, which Buildkite strips.
TB_ANNOTATION_MAX_ROWS=20

render_annotation() {
  local jsonl="$1"
  local share="$2"
  local build_identifier="$3"
  local thumbs_dir="${4:-}"

  local total passed failed
  total="$(jq -s 'length' "${jsonl}")"
  passed="$(jq -s '[.[] | select(.success == true or .success == 1)] | length' "${jsonl}")"
  failed=$((total - passed))

  local summary="${passed} passed"
  if [[ "${failed}" -gt 0 ]]; then
    summary="${summary}, ${failed} failed"
  fi

  echo "#### TestingBot results — ${summary}"
  echo "_Build [\`${build_identifier}\`]($(tb_build_url "${build_identifier}" "${share}")) · step \`${BUILDKITE_LABEL:-${BUILDKITE_JOB_ID:-}}\`_"
  echo
  echo "| | Test | Platform | Duration | Detail |"
  echo "|---|------|----------|----------|--------|"

  local rows=0
  local failed_details=""
  while IFS=$'\t' read -r sid name browser os duration success; do
    [[ -n "${sid}" ]] || continue

    local icon=":white_check_mark:"
    [[ "${success}" == "true" ]] || icon=":x:"
    local url
    url="$(tb_test_url "${sid}" "${share}")"

    if [[ "${rows}" -lt "${TB_ANNOTATION_MAX_ROWS}" ]]; then
      echo "| ${icon} | [${name}](${url}) | ${browser} · ${os} | ${duration}s | [Video]($(tb_video_url "${sid}")) · [Report](${url}) |"
    fi
    rows=$((rows + 1))

    if [[ "${success}" != "true" ]]; then
      failed_details+="$(render_failure_detail "${sid}" "${name}" "${url}" "${thumbs_dir}")"$'\n'
    fi
  done < <(jq -r '[
      (.session_id // (.id | tostring)),
      (.name // "unnamed test"),
      # the API browser field may already include the version ("Chrome 150")
      (((.browser // .device_name // "unknown") | tostring) as $b
        | ((.browser_version // "") | tostring) as $v
        | if $v != "" and ($b | contains($v) | not) then "\($b) \($v)" else $b end),
      (.os // .platform_name // ""),
      ((.duration // 0) | tostring),
      (if (.success == true or .success == 1) then "true" else "false" end)
    ] | @tsv' "${jsonl}")

  if [[ "${rows}" -gt "${TB_ANNOTATION_MAX_ROWS}" ]]; then
    echo
    echo "_Showing ${TB_ANNOTATION_MAX_ROWS} of ${rows} tests — [view all on TestingBot]($(tb_build_url "${build_identifier}" "${share}"))_"
  fi

  if [[ -n "${failed_details}" ]]; then
    echo
    echo "${failed_details}"
  fi
}

render_failure_detail() {
  local sid="$1"
  local name="$2"
  local url="$3"
  local thumbs_dir="$4"

  echo "<details>"
  echo "<summary><code>${name} — failure detail</code></summary>"
  echo
  if [[ -n "${thumbs_dir}" && -f "${thumbs_dir}/testingbot/${sid}.png" ]]; then
    echo "<img src=\"artifact://testingbot/${sid}.png\" alt=\"failure screenshot for ${name}\" height=200 >"
    echo
  fi
  echo "Watch the <a href=\"$(tb_video_url "${sid}")\">video</a> or open the <a href=\"${url}\">full report</a> on TestingBot."
  echo "</details>"
}

# Fallback when jq is unavailable: links-only list from bare session IDs.
# $1 = file with one session id per line, $2 = share flag, $3 = build id
render_annotation_basic() {
  local sessions_file="$1"
  local share="$2"
  local build_identifier="$3"

  echo "#### TestingBot results"
  echo "_Build [\`${build_identifier}\`]($(tb_build_url "${build_identifier}" "${share}")) — install \`jq\` on the agent for rich annotations_"
  echo
  while read -r sid _; do
    [[ -n "${sid}" ]] || continue
    echo "- [${sid}]($(tb_test_url "${sid}" "${share}")) · [Video]($(tb_video_url "${sid}"))"
  done <"${sessions_file}"
}

# Rendered when no sessions were found, explaining the reporting contract
render_annotation_empty() {
  cat <<'EOF'
#### TestingBot: no test sessions found for this step

To link TestingBot tests to this build, either:

1. Append WebDriver session IDs to the sessions file (path in `$TESTINGBOT_SESSIONS_FILE`), one per line: `<session-id> [passed|failed] [test name]`, or
2. Set the `build` capability of your tests to `$TESTINGBOT_BUILD` so the plugin can find them via the TestingBot API.

See the plugin README for framework examples.
EOF
}
