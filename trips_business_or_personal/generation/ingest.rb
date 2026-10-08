#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes data/trips.csv and data/labels.csv from a batch JSON produced by a Claude Code subagent.
#
# Usage: ruby ingest.rb data/batches/business_hard_1.json [more.json ...]
#
# Batch JSON:
# { "business": true, "difficulty": "hard", "generator_model": "claude-sonnet-5-5",
#   "scenarios": [{"business": true, "purpose": "...", "situation": "...", "language": "en", "note_style": "short"}, ...],
#   "trips": [{"date": "2026-09-14", "start_time": "08:40", "duration_min": 25, "distance_km": 12.4,
#              "start_address": "...", "end_address": "...", "note": "...", "justification": "..."}, ...] }
# trips[i] follows scenarios[i].

require "json"
require "csv"
require "fileutils"
require "securerandom"

HERE = __dir__
DATA = File.join(HERE, "..", "data")
TRIPS = File.join(DATA, "trips.csv")
LABELS = File.join(DATA, "labels.csv")
CSV_HEADER = %w[id business purpose difficulty language note_style generator_model justification
                audit_label audit_confidence audit_model status].freeze
TRIP_HEADER = %w[id date start_time duration_min distance_km start_address end_address note].freeze

def next_id(used)
  loop do
    id = "t#{SecureRandom.hex(3)}"
    return id unless used.include?(id)
  end
end

def append(path, header, rows)
  new_file = !File.exist?(path)
  CSV.open(path, "a") do |csv|
    csv << header if new_file
    rows.each { |r| csv << header.map { |k| r[k] } }
  end
end

FileUtils.mkdir_p(DATA)
used = File.exist?(TRIPS) ? CSV.read(TRIPS, headers: true).map { |r| r["id"] } : []
seen = File.exist?(TRIPS) ? CSV.read(TRIPS, headers: true).map { |r| [r["date"], r["start_time"], r["start_address"], r["end_address"]].join("|") } : []

ARGV.each do |path|
  batch = JSON.parse(File.read(path))
  business = batch.fetch("business")
  difficulty = batch.fetch("difficulty")
  trip_rows = []
  label_rows = []
  batch.fetch("trips").each_with_index do |trip, i|
    sc = batch.fetch("scenarios")[i] or abort "#{path}: trip #{i} has no scenario"
    key = [trip["date"], trip["start_time"], trip["start_address"], trip["end_address"]].join("|")
    next if seen.include?(key)

    seen << key
    id = next_id(used)
    used << id
    trip_rows << trip.merge("id" => id)
    label_rows << { "id" => id, "business" => business, "purpose" => sc["purpose"], "difficulty" => difficulty,
                    "language" => sc["language"], "note_style" => sc["note_style"], "generator_model" => batch["generator_model"],
                    "justification" => trip["justification"], "status" => "generated" }
  end
  append(TRIPS, TRIP_HEADER, trip_rows)
  append(LABELS, CSV_HEADER, label_rows)
  puts "#{File.basename(path)}: +#{trip_rows.size} (#{batch['trips'].size - trip_rows.size} duplicates dropped)"
end
