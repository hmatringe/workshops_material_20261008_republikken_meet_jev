# /// script
# requires-python = ">=3.10,<3.13"
# dependencies = ["laya", "torch"]
# ///
"""Laya (github.com/NandhaKishorM/laya), a local open-weights decision engine with Jev's request shape.

Loads the multilingual checkpoint (mmBERT, 322M parameters, about 650 MB, Apache-2.0) on Apple Silicon
and answers one noul question per item, same words as the Jev scorer. No API, no key.

Usage:
  uv run laya_scorer.py --warmup                  installs, downloads the checkpoint, answers one test item
  uv run laya_scorer.py < items.jsonl > out.jsonl
    stdin:  {"id": "...", "state": {...}, "question": {"type": "noul", "instructions": "...", "criteria": {...}}}
    stdout: {"id": "...", "p": 0.83, "ms": 31}
"""
import json
import sys
import time

import laya

MODEL = "convaiinnovations/laya-multilingual"
MAX_LEN = 4096        # the state budget: our longest email plus the criteria fits well within it
HEAD_MAX_LEN = 1024   # the question and criteria budget

t0 = time.time()
agent = laya.load(MODEL)
print(f"model {MODEL} loaded in {time.time() - t0:.1f}s", file=sys.stderr, flush=True)


def ask(state, question):
    questions = {"q": question}
    try:
        result = agent.predict(state, questions, max_len=MAX_LEN, head_max_len=HEAD_MAX_LEN)
    except TypeError:
        result = agent.predict(state, questions)
    answer = result["answers"]["q"]
    if "noul" in answer:
        return float(answer["noul"])
    probs = answer.get("probabilities") or {}
    return float(probs.get("true", probs.get(True, 0.5)))


if "--warmup" in sys.argv:
    p = ask({"record": "Buy 10,000 backlinks today, limited offer, click here."},
            {"type": "noul", "instructions": "Is this message unsolicited?",
             "criteria": {"true": "cold sales, mass marketing, phishing, scams", "false": "an existing relationship or a subscription"}})
    print(f"warmup ok, p(unsolicited) = {p:.2f}")
    sys.exit(0)

n = 0
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    item = json.loads(line)
    t1 = time.time()
    p = ask(item["state"], item["question"])
    print(json.dumps({"id": item["id"], "p": round(p, 4), "ms": int((time.time() - t1) * 1000)}), flush=True)
    n += 1
    if n % 50 == 0:
        print(f"{n} scored", file=sys.stderr, flush=True)
