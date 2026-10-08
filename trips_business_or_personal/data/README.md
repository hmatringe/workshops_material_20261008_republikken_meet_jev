# Trips dataset: the numbers

Generated 2026-10-08 07:06. Method: label-first synthetic generation, blind audit by several models, human decision on disputes. See generation/SPEC.txt.

## Counts

| Cell | easy | medium | hard | total |
| --- | --- | --- | --- | --- |
| business | 50 | 58 | 50 | 158 |
| personal | 59 | 56 | 50 | 165 |

Status: ok: 305, reject: 27, review: 18. Total rows: 350.

- ok: every auditor agreed with the label.
- reject: an auditor disagreed on an easy or medium item, the item missed its instruction. Regenerated.
- review: an auditor disagreed on a hard item, or agreed with low confidence. A human decides.
- kept / dropped: decided by a human.

Generator: claude-sonnet-5-5. Languages: da 70, en 210, fr 70.

## Auditors

| Auditor | items | easy | medium | hard | mean confidence | runs |
| --- | --- | --- | --- | --- | --- | --- |
| gemma4_26b | 350 | 9/120 (8%) | 14/130 (11%) | 8/100 (8%) | 0.96 | 1 |
| claude_sonnet_5_5 | 350 | 2/120 (2%) | 7/130 (5%) | 8/100 (8%) | 0.86 | 1 |
| claude_opus_5_5 | 350 | 2/120 (2%) | 4/130 (3%) | 6/100 (6%) | 0.85 | 1 |

Disagreement = the auditor's blind answer differs from the label, per difficulty. Every auditor ran through audit.rb, which never sends the label to the model.

## Where the auditors disagree with the labels

- business, client_meeting: 6 (easy 2, hard 2, medium 2)
- personal, commute: 6 (hard 3, medium 3)
- business, prospect_meeting: 5 (easy 2, hard 2, medium 1)
- business, business_meal: 5 (hard 3, medium 2)
- business, airport_work: 4 (easy 2, hard 1, medium 1)
- business, conference: 3 (easy 2, medium 1)
- business, company_errand: 2 (easy 1, medium 1)
- business, client_pickup: 2 (medium 2)
- business, supplier_visit: 2 (medium 2)
- business, between_sites: 1 (easy 1)
- personal, school_run: 1 (easy 1)
- personal, airport_holiday: 1 (medium 1)

Decisions pending: 45 rows in data/review.csv.
