# /// script
# requires-python = ">=3.11,<3.14"
# dependencies = ["mlx-lm>=0.24", "numpy"]
# ///
"""The NobodyWho "Jev in 25 lines" idea, made to score a dataset.

Loads a small local model, builds a prompt with two lettered options, reads the logits of the
next token for "A" and "B", normalises them into probabilities. No API, no calibration training.
The post used llama.cpp with Qwen3-0.6B; this uses mlx-lm (Apple Silicon, no compiler needed)
with the same Qwen3-0.6B weights, so the logits are the same model's.

Usage: uv run local_25_lines.py < items.jsonl > scores.jsonl
  stdin:  one JSON per line {"id": "...", "prompt": "...", "options": ["unsolicited", "not unsolicited"]}
  stdout: one JSON per line {"id": "...", "p_a": 0.83, "ms": 41}
  stderr: progress
"""
import json
import os
import sys
import time

import mlx.core as mx
from mlx_lm import load

# LOCAL_MODEL=Qwen/Qwen3-4B uv run local_25_lines.py  (any Hugging Face Qwen3 repo; bigger = slower download, better logits)
MODEL = os.environ.get("LOCAL_MODEL", "Qwen/Qwen3-0.6B")
print(f"model: {MODEL}", file=sys.stderr, flush=True)

model, tokenizer = load(MODEL)
token_a = tokenizer.encode("A", add_special_tokens=False)[0]
token_b = tokenizer.encode("B", add_special_tokens=False)[0]


def render(prompt, options):
    body = f"{prompt}\nChoose one option.\nA. {options[0]}\nB. {options[1]}\nAnswer with the letter only."
    messages = [{"role": "system", "content": "You are a classifier. Answer with a single letter."},
                {"role": "user", "content": body}]
    # Qwen3 chat template; enable_thinking=False inserts the empty <think> block, as in the post.
    return tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True, enable_thinking=False)


n = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    item = json.loads(line)
    t0 = time.time()
    tokens = mx.array(tokenizer.encode(render(item["prompt"], item["options"])))[None]
    logits = model(tokens)[0, -1]
    two = mx.array([logits[token_a], logits[token_b]])
    probs = mx.softmax(two)
    mx.eval(probs)
    p_a = float(probs[0])
    ms = int((time.time() - t0) * 1000)
    print(json.dumps({"id": item["id"], "p_a": round(p_a, 4), "ms": ms}), flush=True)
    n += 1
    if n % 20 == 0:
        print(f"{n} scored", file=sys.stderr, flush=True)
