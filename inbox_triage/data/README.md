# Emails dataset: the numbers

Generated 2026-10-08 07:06. Method: label-first synthetic generation, blind audit by several models, human decision on disputes. See generation/SPEC.txt.

## Counts

| Cell | easy | medium | hard | total |
| --- | --- | --- | --- | --- |
| spam | 58 | 50 | 50 | 158 |
| not spam | 57 | 60 | 50 | 167 |

Status: ok: 311, reject: 15, review: 14. Total rows: 340.

- ok: every auditor agreed with the label.
- reject: an auditor disagreed on an easy or medium item, the item missed its instruction. Regenerated.
- review: an auditor disagreed on a hard item, or agreed with low confidence. A human decides.
- kept / dropped: decided by a human.

Generator: claude-sonnet-5-5. Languages: da 68, en 204, fr 68.

## Auditors

| Auditor | items | easy | medium | hard | mean confidence | runs |
| --- | --- | --- | --- | --- | --- | --- |
| claude_sonnet_5_5 | 340 | 3/120 (2%) | 4/120 (3%) | 4/100 (4%) | 0.92 | 2 |
| gemma4_26b | 340 | 3/120 (2%) | 10/120 (8%) | 14/100 (14%) | 1.00 | 1 |
| claude_opus_5_5 | 340 | 1/120 (1%) | 8/120 (7%) | 6/100 (6%) | 0.91 | 1 |

Disagreement = the auditor's blind answer differs from the label, per difficulty. Every auditor ran through audit.rb, which never sends the label to the model.

## Where the auditors disagree with the labels

- spam, spam: 26 (easy 2, hard 14, medium 10)
- not spam, partnership: 3 (easy 3)

Decisions pending: 29 rows in data/review.csv.
