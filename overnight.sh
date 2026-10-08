#!/bin/zsh
# The whole evening in one process. Export the three variables, then run it and go to bed.
# Works under zsh, bash and sh.
#
#   export TYPESAFE_API_KEY=...  ANTHROPIC_API_KEY=...  ANTHROPIC_WORKSPACE_ID=...
#   ./overnight.sh          (or: sh overnight.sh)
#   ./overnight.sh --resume   keeps the audits already on disk, continues where each one stopped, then benchmarks
#
# Do not press Ctrl-C in its window: that kills the whole run (it happened on 2026-10-08 at 00:05).
#
# Phase 1, audits (about 1 h): deletes every audit file, review.csv and audit log in both datasets, resets
#   every row of labels.csv to status "generated", then audits both datasets with Gemma 4 (local, in the
#   background), Claude Sonnet 5.5 and Claude Opus 5.5 (API). Items and labels are untouched.
# Phase 2, benchmarks (about 1 h): Jev, Sonnet, then the local models (Qwen3-4B asked for its confidence,
#   Qwen3-4B and Qwen3-0.6B through the logits), on both datasets, plus the two stability runs.
#   API scorers run in one chain, local scorers in another, in parallel. Each run leaves a CSV and a .log.
# Phase 3: statuses, data/README.md for both datasets, benchmark/results/report.md and the SVG diagrams.
#
# Everything is re-runnable. Progress: overnight.log next to this script, and the per-run logs.

set -e
cd "$(dirname "$0")"
ROOT="$(pwd)"
DATASETS=(inbox_triage trips_business_or_personal)
MAIN_LOG="$ROOT/overnight.log"

for v in TYPESAFE_API_KEY ANTHROPIC_API_KEY ANTHROPIC_WORKSPACE_ID; do
  if [[ -z "$(printenv "$v")" ]]; then echo "$v is not set"; exit 1; fi
done

log() { echo "$(date '+%H:%M:%S') $*" | tee -a "$MAIN_LOG"; }
RESUME=0
[[ "$1" == "--resume" ]] && RESUME=1
trap 'log "INTERRUPTED (Ctrl-C). Run again with --resume."; exit 130' INT
log "== overnight start $([[ $RESUME == 1 ]] && echo '(resume)') =="

if [[ $RESUME == 1 ]]; then
  log "== phase 1a skipped: keeping the audits on disk =="
else
log "== phase 1a: table rase =="
for d in "${DATASETS[@]}"; do
  ruby -rcsv -e '
    t = CSV.read("'$d'/data/labels.csv", headers: true)
    t.each { |r| r["status"] = "generated"; r["audit_label"] = nil; r["audit_confidence"] = nil; r["audit_model"] = nil }
    File.write("'$d'/data/labels.csv", t.to_csv)
    Dir["'$d'/data/audits/*", "'$d'/data/audits_cc/*", "'$d'/data/audit_*.log", "'$d'/data/review.csv"].each { |f| File.delete(f) }
    Dir.rmdir("'$d'/data/audits_cc") if Dir.exist?("'$d'/data/audits_cc")
    puts "'$d': #{t.size} rows reset, audits deleted"' | tee -a "$MAIN_LOG"
done
fi

log "== phase 1b: audits (Gemma in the background, Sonnet then Opus in front) =="
(
  for d in "${DATASETS[@]}"; do
    (cd "$ROOT/$d" && ruby generation/audit.rb --engine=ollama >> data/audit_gemma4.log 2>&1) || log "FAILED: gemma on $d"
    log "gemma done on $d"
  done
) &
GEMMA=$!
for d in "${DATASETS[@]}"; do
  (cd "$ROOT/$d" && ruby generation/audit.rb --engine=claude >> data/audit_sonnet.log 2>&1) || log "FAILED: sonnet on $d"
  log "sonnet done on $d"
  (cd "$ROOT/$d" && ruby generation/audit.rb --engine=claude --model=claude-opus-5-5 >> data/audit_opus.log 2>&1) || log "FAILED: opus on $d"
  log "opus done on $d"
done
wait $GEMMA
for d in "${DATASETS[@]}"; do
  (cd "$ROOT/$d" && ruby generation/audit.rb --status | tee -a "$MAIN_LOG" && ruby generation/report.rb > /dev/null)
  log "$d: statuses recomputed, data/README.md written"
done

log "== phase 2: benchmarks (API chain and local chain in parallel) =="
cd "$ROOT/benchmark"
bench() { log "run: $*"; ruby benchmark.rb "$@" > /dev/null 2>&1 || log "FAILED: $*"; }
(
  bench --dataset=inbox --scorer=ollama --model=qwen3:4b
  bench --dataset=trips --scorer=ollama --model=qwen3:4b
  bench --dataset=inbox --scorer=local --model=Qwen/Qwen3-4B
  bench --dataset=trips --scorer=local --model=Qwen/Qwen3-4B
  bench --dataset=inbox --scorer=local
  bench --dataset=trips --scorer=local
  log "local chain done"
) &
LOCAL=$!
bench --dataset=inbox --scorer=jev
bench --dataset=trips --scorer=jev
bench --dataset=inbox --scorer=jev --limit=30 --passes=5
bench --dataset=inbox --scorer=sonnet
bench --dataset=trips --scorer=sonnet
bench --dataset=inbox --scorer=sonnet --limit=30 --passes=5
log "api chain done"
wait $LOCAL

log "== phase 3: metrics =="
ruby metrics.rb > /dev/null && log "benchmark/results/report.md written"
log "== overnight done =="
