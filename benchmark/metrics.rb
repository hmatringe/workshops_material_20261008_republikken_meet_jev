#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes results/report.md and one SVG reliability diagram per run, named like its CSV and its log.
# The demo app's /benchmark page writes the same files on every load (Metrics.write_report); this is the
# terminal version, for when the app is not running.
#
#   ruby metrics.rb
#
# Metrics: accuracy, F1 (positive class), Brier, ECE (10 bins), share of items in the 0.40 to 0.60 zone and
# accuracy inside it, accuracy per difficulty, median and p95 latency, total cost, and for --passes runs the
# mean standard deviation of p per item and the share of decisions that flipped. Ruby stdlib only.

require_relative "../lib/metrics"
require_relative "../lib/datasets"

full_sizes = %w[inbox trips].to_h { |ds| [ds, Datasets.load(ds).items.size] }
summaries = full_sizes.to_h { |ds, full| [ds, Metrics.dataset_summary(ds, full)] }
puts Metrics.write_report(summaries, full_sizes)
