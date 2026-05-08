#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  scripts/run_end_to_end.sh [options]

Runs the full benchmark flow:
  1) collect
  2) grade (primary judge from config.grade.judge_model)
  3) optionally grade-panel for additional judges
  4) publish latest viewer dataset (only when additional judges are run)

Options:
  --config <path>       Config file (default: config.json)
  --output-dir <dir>    Output base dir (default: runs)
  --viewer-output-dir <dir>
                        Viewer dataset output dir (default: data/latest)
  --run-id <id>         Explicit run id (default: auto timestamp)
  --panel-id <id>       Explicit panel id (default: <run-id>_panel)
  --model <name>        Single model under evaluation (forwarded to collect)
  --api-base <url>      OpenAI-compatible base URL for generation (forwarded to collect)
  --api-key-env <name>  Env var holding the API key for --api-base
  --primary-judge <model>
                        litellm model string for the primary judge (overrides config.grade.judge_model)
  --primary-judge-api-base <url>
                        API base URL for the primary judge (required when not --dry-run)
  --judges <csv>        Comma-separated litellm model strings for the panel
                        (overrides config.grade_panel.judge_models)
  --judges-api-bases <csv>
                        Comma-separated API base URLs, one per --judges entry
                        (required when not --dry-run; length must match --judges)
  --with-additional-judges
                        After primary judge, run grade-panel for remaining judges
  --skip-collect        Skip collect stage (requires existing responses file)
  --skip-primary-judge  Skip primary judge stage
  --skip-publish        Skip the viewer publish step
  --no-run-subdir       Write outputs directly into --output-dir instead of
                        nesting under <output-dir>/<run-id>/
  --timeout-seconds <n> Per-request timeout (forwarded to collect/grade/grade-panel)
  --dry-run             Pass --dry-run to collect/grade/grade-panel
  --serve               Start local HTTP server after publish
  --port <port>         HTTP server port for --serve (default: 8877)
  -h, --help            Show this help
EOF
}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

CONFIG_PATH="config.json"
OUTPUT_DIR="runs"
VIEWER_OUTPUT_DIR="data/latest"
RUN_ID=""
PANEL_ID=""
MODEL=""
API_BASE=""
API_KEY_ENV=""
PRIMARY_JUDGE=""
PRIMARY_JUDGE_API_BASE=""
JUDGES=""
JUDGES_API_BASES=""
TIMEOUT_SECONDS=""
DRY_RUN=0
SERVE=0
PORT=8877
WITH_ADDITIONAL_JUDGES=0
SKIP_COLLECT=0
SKIP_PRIMARY_JUDGE=0
SKIP_PUBLISH=0
NO_RUN_SUBDIR=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_PATH="${2:-}"
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --viewer-output-dir)
      VIEWER_OUTPUT_DIR="${2:-}"
      shift 2
      ;;
    --run-id)
      RUN_ID="${2:-}"
      shift 2
      ;;
    --panel-id)
      PANEL_ID="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --api-base)
      API_BASE="${2:-}"
      shift 2
      ;;
    --api-key-env)
      API_KEY_ENV="${2:-}"
      shift 2
      ;;
    --primary-judge)
      PRIMARY_JUDGE="${2:-}"
      shift 2
      ;;
    --primary-judge-api-base)
      PRIMARY_JUDGE_API_BASE="${2:-}"
      shift 2
      ;;
    --judges)
      JUDGES="${2:-}"
      shift 2
      ;;
    --judges-api-bases)
      JUDGES_API_BASES="${2:-}"
      shift 2
      ;;
    --timeout-seconds)
      TIMEOUT_SECONDS="${2:-}"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --with-additional-judges)
      WITH_ADDITIONAL_JUDGES=1
      shift
      ;;
    --skip-collect)
      SKIP_COLLECT=1
      shift
      ;;
    --skip-primary-judge)
      SKIP_PRIMARY_JUDGE=1
      shift
      ;;
    --skip-publish)
      SKIP_PUBLISH=1
      shift
      ;;
    --no-run-subdir)
      NO_RUN_SUBDIR=1
      shift
      ;;
    --serve)
      SERVE=1
      shift
      ;;
    --port)
      PORT="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 2
      ;;
  esac
done

if [[ ! -f "${CONFIG_PATH}" ]]; then
  echo "Config file not found: ${CONFIG_PATH}" >&2
  exit 1
fi

# OPENROUTER_API_KEY is only required when a judge that's actually going to
# run hasn't been overridden — the repo defaults route every judge through
# openrouter, but a user with Vertex / Anthropic / OpenAI credentials can
# bypass that via --primary-judge / --judges.
NEEDS_OPENROUTER=0
if [[ "${SKIP_PRIMARY_JUDGE}" -ne 1 ]] && [[ -z "${PRIMARY_JUDGE}" ]]; then
  NEEDS_OPENROUTER=1
fi
if [[ "${WITH_ADDITIONAL_JUDGES}" -eq 1 ]] && [[ -z "${JUDGES}" ]]; then
  NEEDS_OPENROUTER=1
fi
if [[ "${DRY_RUN}" -ne 1 ]] && [[ "${NEEDS_OPENROUTER}" -eq 1 ]] && [[ -z "${OPENROUTER_API_KEY:-}" ]]; then
  echo "OPENROUTER_API_KEY required when an active judge isn't overridden via --primary-judge / --judges." >&2
  exit 1
fi

if [[ -z "${RUN_ID}" ]]; then
  if [[ "${SKIP_COLLECT}" -eq 1 ]]; then
    echo "--skip-collect requires --run-id." >&2
    exit 2
  fi
  RUN_ID="run_$(date -u +%Y%m%d_%H%M%S)"
fi
if [[ -z "${PANEL_ID}" ]]; then
  PANEL_ID="${RUN_ID}_panel"
fi

if [[ "${NO_RUN_SUBDIR}" -eq 1 ]]; then
  RUN_DIR="${OUTPUT_DIR}"
else
  RUN_DIR="${OUTPUT_DIR}/${RUN_ID}"
fi
PANEL_DIR="${RUN_DIR}/grade_panels/${PANEL_ID}"
RESPONSES_FILE="${RUN_DIR}/responses.jsonl"
COLLECTION_STATS_FILE="${RUN_DIR}/collection_stats.json"
PANEL_SUMMARY_FILE="${PANEL_DIR}/panel_summary.json"
if [[ -n "${PRIMARY_JUDGE}" ]]; then
  PRIMARY_GRADE_MODEL="${PRIMARY_JUDGE}"
else
  PRIMARY_GRADE_MODEL="$(
    python3 - <<'PY' "${CONFIG_PATH}"
import json
import sys

config = json.load(open(sys.argv[1], "r", encoding="utf-8"))
judge = ""
grade_cfg = config.get("grade", {})
if isinstance(grade_cfg, dict):
    value = grade_cfg.get("judge_model")
    if isinstance(value, str) and value.strip():
        judge = value.strip()
if not judge:
    panel_cfg = config.get("grade_panel", {})
    if isinstance(panel_cfg, dict):
        judges = panel_cfg.get("judge_models")
        if isinstance(judges, list) and judges:
            candidate = str(judges[0]).strip()
            if candidate:
                judge = candidate
if not judge:
    raise SystemExit("Could not determine primary judge model from config.")
print(judge)
PY
  )"
fi
PRIMARY_GRADE_SLUG="$(
  python3 - <<'PY' "${PRIMARY_GRADE_MODEL}"
import re
import sys

print(re.sub(r"[^A-Za-z0-9._-]+", "_", sys.argv[1]).strip("_"))
PY
)"
PRIMARY_GRADE_ID="${PANEL_ID}__judge1_${PRIMARY_GRADE_SLUG}"
PRIMARY_GRADE_DIR="${PANEL_DIR}/grades/${PRIMARY_GRADE_ID}"

collect_cmd=(
  uv run python3 scripts/openrouter_benchmark.py collect
  --config "${CONFIG_PATH}"
)
if [[ "${NO_RUN_SUBDIR}" -eq 1 ]]; then
  # Trick: pass the parent of OUTPUT_DIR as --output-dir and the basename as
  # --run-id, so collect's resolve_artifact_dir creates exactly OUTPUT_DIR.
  collect_cmd+=(
    --output-dir "$(dirname "${OUTPUT_DIR}")"
    --run-id "$(basename "${OUTPUT_DIR}")"
  )
else
  collect_cmd+=(--output-dir "${OUTPUT_DIR}" --run-id "${RUN_ID}")
fi
if [[ -n "${MODEL}" ]]; then
  collect_cmd+=(--model "${MODEL}")
fi
if [[ -n "${API_BASE}" ]]; then
  collect_cmd+=(--api-base "${API_BASE}")
fi
if [[ -n "${API_KEY_ENV}" ]]; then
  collect_cmd+=(--api-key-env "${API_KEY_ENV}")
fi
if [[ -n "${TIMEOUT_SECONDS}" ]]; then
  collect_cmd+=(--timeout-seconds "${TIMEOUT_SECONDS}")
fi
if [[ "${DRY_RUN}" -eq 1 ]]; then
  collect_cmd+=(--dry-run)
fi

if [[ "${SKIP_COLLECT}" -eq 1 ]]; then
  echo "==> Skipping collect stage"
else
  echo "==> Collect: ${RUN_ID}"
  "${collect_cmd[@]}"
fi

if [[ ! -f "${RESPONSES_FILE}" ]]; then
  echo "Responses file not found: ${RESPONSES_FILE}" >&2
  exit 1
fi

primary_grade_cmd=(
  uv run python3 scripts/openrouter_benchmark.py grade
  --config "${CONFIG_PATH}"
  --responses-file "${RESPONSES_FILE}"
  --output-dir "${PANEL_DIR}"
  --grade-id "${PRIMARY_GRADE_ID}"
  --judge-model "${PRIMARY_GRADE_MODEL}"
)
if [[ -n "${PRIMARY_JUDGE_API_BASE}" ]]; then
  primary_grade_cmd+=(--judge-api-base "${PRIMARY_JUDGE_API_BASE}")
fi
if [[ -n "${TIMEOUT_SECONDS}" ]]; then
  primary_grade_cmd+=(--timeout-seconds "${TIMEOUT_SECONDS}")
fi
if [[ "${DRY_RUN}" -eq 1 ]]; then
  primary_grade_cmd+=(--dry-run)
fi

if [[ "${SKIP_PRIMARY_JUDGE}" -eq 1 ]]; then
  echo "==> Skipping primary judge stage"
else
  if [[ -d "${PRIMARY_GRADE_DIR}" ]]; then
    primary_grade_cmd+=(--resume)
  fi
  echo "==> Grade primary judge: ${PRIMARY_GRADE_MODEL}"
  "${primary_grade_cmd[@]}"
fi

if [[ "${WITH_ADDITIONAL_JUDGES}" -eq 1 ]]; then
  panel_cmd=(
    uv run python3 scripts/openrouter_benchmark.py grade-panel
    --config "${CONFIG_PATH}"
    --responses-file "${RESPONSES_FILE}"
    --output-dir "${RUN_DIR}"
    --panel-id "${PANEL_ID}"
    --panel-mode full
    --consensus-method mean
  )
  if [[ -n "${JUDGES}" ]]; then
    panel_cmd+=(--judge-models "${JUDGES}")
  fi
  if [[ -n "${JUDGES_API_BASES}" ]]; then
    panel_cmd+=(--judge-api-bases "${JUDGES_API_BASES}")
  fi
  if [[ -n "${TIMEOUT_SECONDS}" ]]; then
    panel_cmd+=(--timeout-seconds "${TIMEOUT_SECONDS}")
  fi
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    panel_cmd+=(--dry-run)
  fi
  if [[ -d "${PANEL_DIR}" ]]; then
    panel_cmd+=(--resume)
  fi

  echo "==> Grade panel (additional judges): ${PANEL_ID}"
  "${panel_cmd[@]}"
fi

if [[ "${WITH_ADDITIONAL_JUDGES}" -eq 1 ]] && [[ "${SKIP_PUBLISH}" -ne 1 ]]; then
  if [[ ! -f "${PANEL_SUMMARY_FILE}" ]]; then
    echo "Panel summary not found: ${PANEL_SUMMARY_FILE}" >&2
    exit 1
  fi

  AGGREGATE_DIR="$(
    python3 - <<'PY' "${PANEL_SUMMARY_FILE}"
import json
import pathlib
import sys

panel_summary_path = pathlib.Path(sys.argv[1])
payload = json.loads(panel_summary_path.read_text(encoding="utf-8"))
aggregate_dir = str(payload.get("aggregate_dir", "")).strip()
print(aggregate_dir)
PY
  )"

  if [[ -z "${AGGREGATE_DIR}" ]]; then
    echo "aggregate_dir missing in ${PANEL_SUMMARY_FILE}" >&2
    exit 1
  fi

  AGGREGATE_SUMMARY_FILE="${AGGREGATE_DIR}/aggregate_summary.json"
  AGGREGATE_ROWS_FILE="${AGGREGATE_DIR}/aggregate.jsonl"

  echo "==> Publish viewer dataset"
  ./scripts/publish_latest_to_viewer.sh \
    --responses-file "${RESPONSES_FILE}" \
    --collection-stats "${COLLECTION_STATS_FILE}" \
    --panel-summary "${PANEL_SUMMARY_FILE}" \
    --aggregate-summary "${AGGREGATE_SUMMARY_FILE}" \
    --aggregate-rows "${AGGREGATE_ROWS_FILE}" \
    --output-dir "${VIEWER_OUTPUT_DIR}"
else
  echo "==> Additional judges skipped; publish step skipped."
fi

echo ""
echo "Complete."
echo "Run ID: ${RUN_ID}"
echo "Panel ID: ${PANEL_ID}"
echo "Primary judge model: ${PRIMARY_GRADE_MODEL}"
echo "Primary grade dir: ${PRIMARY_GRADE_DIR}"
if [[ "${WITH_ADDITIONAL_JUDGES}" -eq 1 ]]; then
  echo "Viewer data: ${ROOT_DIR}/${VIEWER_OUTPUT_DIR}"
  echo "Open UI after serving:"
  echo "  /viewer/index.v2.html"
else
  echo "To run additional judges later, reuse this run with:"
  echo "  ./scripts/run_end_to_end.sh --config ${CONFIG_PATH} --output-dir ${OUTPUT_DIR} --run-id ${RUN_ID} --panel-id ${PANEL_ID} --skip-collect --skip-primary-judge --with-additional-judges"
fi

if [[ "${SERVE}" -eq 1 ]]; then
  echo ""
  echo "Starting local server on port ${PORT}..."
  python3 -m http.server "${PORT}"
fi
