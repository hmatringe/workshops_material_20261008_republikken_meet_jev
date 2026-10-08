# Benchmark report

Generated 2026-10-09 10:22. Same prompt for every scorer (lib/datasets.rb). Decision threshold 0.5.

## inbox (325 items)

| Scorer | items | accuracy | F1 | Brier | ECE | in 0.40-0.60 | acc. in zone | easy | medium | hard | median ms | p95 ms | total time | cost USD |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Jev 1.13 (TypeSafe) | 325 | 91.7% | 0.914 | 0.062 | 0.061 | 5.5% | 55.6% | 95.7% | 94.5% | 84.0% | 29 | 50 | 0m11s | 0.0054 |
| Laya multilingual (local, 322M) | 325 | 70.5% | 0.713 | 0.228 | 0.172 | 8.0% | 42.3% | 76.5% | 70.0% | 64.0% | 47 | 72 | 0m28s | 0.0000 |
| Claude Sonnet 5.5 | 325 | 98.2% | 0.981 | 0.017 | 0.072 | 1.8% | 33.3% | 100.0% | 97.3% | 97.0% | 1334 | 3146 | 9m13s | 0.5505 |
| Claude Opus 5.5 | 325 | 98.5% | 0.984 | 0.021 | 0.073 | 0.9% | 66.7% | 100.0% | 98.2% | 97.0% | 2048 | 7483 | 15m07s | 1.0915 |
| Claude Fable 5.1 | 325 | 97.8% | 0.978 | 0.019 | 0.053 | 0.3% | 100.0% | 98.3% | 97.3% | 98.0% | 1573 | 1949 | 9m06s | 2.3072 |
| Qwen3-4B, asked for its confidence | 325 | 86.2% | 0.854 | 0.124 | 0.077 | 0.0% | n/a | 88.7% | 92.7% | 76.0% | 1292 | 1881 | 7m25s | 0.0000 |
| Qwen3-4B, 25 lines | 325 | 81.8% | 0.779 | 0.170 | 0.176 | 0.3% | 0.0% | 87.8% | 88.2% | 68.0% | 1146 | 5307 | 10m08s | 0.0000 |
| Qwen3-0.6B, 25 lines | 325 | 53.8% | 0.107 | 0.369 | 0.327 | 5.2% | 70.6% | 53.9% | 56.4% | 51.0% | 272 | 2090 | 3m24s | 0.0000 |

Stability, Claude Sonnet 5.5, 5 passes on 30 items: mean SD of p 0.0084, decision flipped on 1 items (3.3%).

## trips (323 items)

| Scorer | items | accuracy | F1 | Brier | ECE | in 0.40-0.60 | acc. in zone | easy | medium | hard | median ms | p95 ms | total time | cost USD |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| Jev 1.13 (TypeSafe) | 323 | 94.7% | 0.948 | 0.047 | 0.096 | 8.0% | 65.4% | 97.2% | 95.6% | 91.0% | 28 | 63 | 0m10s | 0.0050 |
| Laya multilingual (local, 322M) | 323 | 57.0% | 0.215 | 0.323 | 0.347 | 5.6% | 44.4% | 61.5% | 54.4% | 55.0% | 35 | 40 | 0m22s | 0.0000 |
| Claude Sonnet 5.5 | 323 | 96.6% | 0.966 | 0.029 | 0.102 | 3.7% | 33.3% | 98.2% | 97.4% | 94.0% | 1400 | 3152 | 9m52s | 0.5348 |
| Claude Opus 5.5 | 323 | 97.2% | 0.972 | 0.032 | 0.108 | 5.3% | 58.8% | 99.1% | 98.2% | 94.0% | 2006 | 8405 | 14m56s | 0.9509 |
| Claude Fable 5.1 | 323 | 97.2% | 0.972 | 0.031 | 0.092 | 4.6% | 60.0% | 98.2% | 97.4% | 96.0% | 1575 | 2505 | 9m18s | 1.9210 |
| Qwen3-4B, asked for its confidence | 323 | 65.9% | 0.742 | 0.288 | 0.296 | 0.0% | n/a | 66.1% | 65.8% | 66.0% | 1062 | 1136 | 5m54s | 0.0000 |
| Qwen3-4B, 25 lines | 323 | 81.1% | 0.838 | 0.186 | 0.190 | 0.3% | 100.0% | 83.5% | 81.6% | 78.0% | 856 | 863 | 4m42s | 0.0000 |
| Qwen3-0.6B, 25 lines | 323 | 49.2% | 0.658 | 0.278 | 0.185 | 13.9% | 35.6% | 45.9% | 51.8% | 50.0% | 149 | 153 | 0m51s | 0.0000 |


Reading: ECE is the gap between stated probability and observed frequency, averaged over 10 bins (0 is perfect). Brier is the mean squared error of the probability. The 0.40-0.60 zone is where a human-review band would sit: a calibrated scorer should be near 50% accurate there, an overconfident one is rarely there at all. A partial run covers fewer items than the dataset: a setup check, not a result.
