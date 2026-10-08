Workshop material: Meet Jev, the AI that decides (2026-10-08, Republikken)

Two synthetic, audited datasets for the hands-on and the benchmark, plus the NobodyWho folder.
Everything is Ruby stdlib, no gem. Written 2026-10-07.

inbox_triage/                     emails of a coworking space's shared inbox: spam or not, category, urgency, needs a human
  questions.txt                   the questions sent to Jev (English), also the ground truth definitions
  data/mails/<id>.txt             one email per file, opaque id, what the models under test see
  data/labels.csv                 the truth and the bookkeeping (label, difficulty, language, status, audits)
  data/audits/<ts>-<model>.csv    one file per audit run; _cc suffix = Claude Code subagent, blind by instruction
  data/review.csv                 the disputed rows, for the human
  data/README.md                  the numbers (ruby generation/report.rb)
  generation/SPEC.txt             how the data is made, quotas, scenarios, audit rules, notes

trips_business_or_personal/       mileage records: business or personal
  questions.txt                   the question sent to Jev (English), also the ground truth definition
  data/trips.csv                  one trip per row, opaque id, what the models under test see
  data/labels.csv, audits/, review.csv, README.md   same as above
  generation/SPEC.txt

nobodywho_25_lines/               notes on the "Jev in 25 lines" post

lib/jev.rb                        the Jev client (stdlib), ported from an earlier production client
lib/datasets.rb                   the two datasets as the scorers see them, one binary question each, same words everywhere
benchmark/                        benchmark.rb (jev | sonnet | local scorers), metrics.rb (report + reliability SVGs), README.txt
jev_folder.rb                     the take-home: your folder of emails or your CSV of trips -> a CSV with decisions and probabilities
demo_app/                         Sinatra app for the room: editable questions, key on the server, batch view. See its README.txt

How to run (from a dataset folder)
  ruby generation/generate.rb --cell=spam:hard --call=2 --dry-run      print a generation prompt
  ruby generation/generate.rb --cell=spam:hard --call=2 --scenarios    print its scenario JSON
  ruby generation/ingest.rb data/batches/spam_hard_3.json              ingest a batch written by a subagent
  ruby generation/audit.rb                                              blind audit with Gemma 4 (Ollama, local)
  ANTHROPIC_API_KEY=... ANTHROPIC_WORKSPACE_ID=... ruby generation/audit.rb --engine=claude [--model=claude-opus-5-5]
  ruby generation/audit.rb --status                                     recompute statuses from the audit files
  ruby generation/report.rb                                             write data/README.md

Status rules: ok = every auditor agrees with the label. reject = disagreement on easy or medium (regenerated).
review = disagreement on hard, or hesitant agreement. kept / dropped = decided by a human, never overwritten.
To decide: edit the status column in data/labels.csv (kept or dropped), then ruby generation/audit.rb --status.
