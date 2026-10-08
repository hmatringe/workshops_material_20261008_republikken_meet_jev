Benchmark: Jev vs a general LLM vs "Jev in 25 lines"

Three scorers answer the same binary question on the same items with the same words (lib/datasets.rb):
  inbox   "Is this message unsolicited?"      positive = unsolicited
  trips   "Is this a business trip?"          positive = business
Items: every audited row whose status is not reject or dropped (ok and review).

Scorers
  jev     one noul per item, 10 items per call, probability native. Needs TYPESAFE_API_KEY.
  sonnet  one call per item, JSON answer plus a self-reported confidence, p = confidence if positive else
          1 - confidence. Needs ANTHROPIC_API_KEY (and ANTHROPIC_WORKSPACE_ID for an organisation key).
          --model=claude-opus-5-5 for Opus.
  local   the NobodyWho idea: Qwen3-0.6B, logits of the next token for "A" and "B", softmax. No key.
          Runs through uv (local_25_lines.py, mlx-lm on Apple Silicon; the post used llama.cpp, same weights).
          First run downloads about 1.5 GB. --model=Qwen/Qwen3-4B for the 4B weights (8 GB).
  ollama  the same local model, used the usual way: it generates a JSON answer with a self-reported
          confidence, like the sonnet scorer. --model=qwen3:4b (ollama pull qwen3:4b first), or any model
          in `ollama list` (gemma4:26b, qwen3-coder:30b). No key.

The pair to compare: local --model=Qwen/Qwen3-4B against ollama --model=qwen3:4b. Same weights, two
probabilities: one read from the logits, one the model wrote about itself. If they are calibrated the same,
the size of the model is what matters. If not, the "25 lines" shortcut is what loses the calibration.

Run, from this folder
  ruby benchmark.rb --dataset=inbox --scorer=local
  ruby benchmark.rb --dataset=trips --scorer=local
  ruby benchmark.rb --dataset=inbox --scorer=jev
  ruby benchmark.rb --dataset=trips --scorer=jev
  ruby benchmark.rb --dataset=inbox --scorer=sonnet
  ruby benchmark.rb --dataset=trips --scorer=sonnet
  ruby benchmark.rb --dataset=inbox --scorer=local --model=Qwen/Qwen3-4B
  ruby benchmark.rb --dataset=inbox --scorer=ollama --model=qwen3:4b
  ruby benchmark.rb --dataset=inbox --scorer=jev --limit=30 --passes=5        stability: same 30 items, 5 times
  ruby benchmark.rb --dataset=inbox --scorer=sonnet --limit=30 --passes=5
  ruby metrics.rb                                                               -> results/report.md and SVG diagrams

Each run writes results/<dataset>-<scorer>-<timestamp>.csv: id, label, difficulty, p, decision, ms, input_tokens, cost_usd.
A --limit run is a check, not a result: metrics.rb takes the latest file per (dataset, scorer), so run the
full set last.

What the report shows
  accuracy, F1, Brier, ECE (10 bins), the share of items in the 0.40 to 0.60 zone and the accuracy inside it,
  accuracy per difficulty, median and p95 latency per item, total cost, and for --passes runs the mean
  standard deviation of p per item and the share of decisions that flipped between passes.
  Reliability diagrams: bars = observed frequency per bin, dots = mean stated probability. On the diagonal
  means calibrated.

Honest reading
  The ground truth is synthetic (Sonnet wrote the items, three models audited them, a human decides the
  disputes). A label error penalises every scorer the same way, so the differences hold better than the
  absolute numbers. Sonnet is also the generator: it may recognise its own style. Jev's per-item latency is
  a call latency divided by 10: it is the batch that is fast, not one item alone.
