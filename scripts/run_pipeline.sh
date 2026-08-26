#!/bin/bash
# Run the targets pipeline in a detached terminal multiplexer session, so it survives an SSH or
# IDE disconnect from the compute node.
#
# This has to wrap the WHOLE pipeline, not just the Omniscape runs: `processx` kills its children
# when the R session exits, and if the session dies `targets` loses the run regardless of where the
# Julia subprocess happens to live.
#
#   scripts/run_pipeline.sh                 # detached; reattach with `tmux attach -t bc-conn`
#   scripts/run_pipeline.sh --attach        # run in the foreground instead
#
# Environment variables (see README):
#   BC_CONN_WORKERS          crew workers                     (default: min(cores - 2, 64))
#   BC_CONN_OMNISCAPE        none | nn | alldist | all        (default: none)
#   BC_CONN_OMNISCAPE_BENCH  e.g. "2x3" to also write tiled benchmarking configs
#   BC_CONN_JULIA_THREADS    Julia threads per Omniscape run  (default: 64)

set -euo pipefail

SESSION="${BC_CONN_SESSION:-bc-conn}"
PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG="${PROJECT}/Outputs/pipeline-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "$(dirname "$LOG")"

# `--vanilla` is deliberately NOT used: the project .Rprofile activates renv.
CMD="cd '${PROJECT}' && Rscript -e 'targets::tar_make(reporter = \"verbose\")' 2>&1 | tee '${LOG}'"

if [[ "${1:-}" == "--attach" ]]; then
  echo "Running in the foreground; log: ${LOG}"
  eval "${CMD}"
  exit $?
fi

if command -v tmux >/dev/null 2>&1; then
  if tmux has-session -t "${SESSION}" 2>/dev/null; then
    echo "A session named '${SESSION}' already exists. Attach with:  tmux attach -t ${SESSION}"
    exit 1
  fi
  tmux new-session -d -s "${SESSION}" "${CMD}"
  echo "Started in tmux session '${SESSION}'."
  echo "  attach:  tmux attach -t ${SESSION}      (detach again with Ctrl-b d)"
elif command -v screen >/dev/null 2>&1; then
  if screen -list | grep -q "\.${SESSION}[[:space:]]"; then
    echo "A session named '${SESSION}' already exists. Attach with:  screen -r ${SESSION}"
    exit 1
  fi
  screen -dmS "${SESSION}" bash -c "${CMD}"
  echo "Started in screen session '${SESSION}'."
  echo "  attach:  screen -r ${SESSION}           (detach again with Ctrl-a d)"
else
  echo "Neither tmux nor screen found; falling back to nohup (not reattachable)."
  nohup bash -c "${CMD}" >/dev/null 2>&1 &
  echo "Started with nohup (pid $!)."
fi

echo "  log:     ${LOG}"
echo "  status:  Rscript -e 'targets::tar_progress_summary()'"
