#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes data/README.md: the numbers behind the dataset, for the slide. No API call.
# Usage: ruby report.rb
# Works for both datasets: the label field and the item word come from the labels header.

require "csv"

HERE = __dir__
DATA = File.join(HERE, "..", "data")
LABELS = File.join(DATA, "labels.csv")
AUDITS = File.join(DATA, "audits")
README = File.join(DATA, "README.md")

table = CSV.read(LABELS, headers: true)
label_field = table.headers.include?("spam") ? "spam" : "business"
item = label_field == "spam" ? "emails" : "trips"
positive = label_field == "spam" ? "spam" : "business"
negative = label_field == "spam" ? "not spam" : "personal"

audits = Dir.glob(File.join(AUDITS, "*.csv")).sort.each_with_object({}) do |path, h|
  name = File.basename(path, ".csv").sub(/\A\d{8}-\d{6}-/, "")
  h[name] ||= { runs: [], verdicts: {} }
  h[name][:runs] << File.basename(path)
  CSV.read(path, headers: true).each { |r| h[name][:verdicts][r["id"]] = r }
end

def pct(n, d)
  d.zero? ? "n/a" : format("%d/%d (%.0f%%)", n, d, 100.0 * n / d)
end

lines = []
lines << "# #{item.capitalize} dataset: the numbers"
lines << ""
lines << "Generated #{Time.now.strftime('%Y-%m-%d %H:%M')}. Method: label-first synthetic generation, blind audit by several models, human decision on disputes. See generation/SPEC.txt."
lines << ""
lines << "## Counts"
lines << ""
lines << "| Cell | easy | medium | hard | total |"
lines << "| --- | --- | --- | --- | --- |"
[true, false].each do |pos|
  cells = %w[easy medium hard].map { |d| table.count { |r| r[label_field] == pos.to_s && r["difficulty"] == d && r["status"] != "reject" && r["status"] != "dropped" } }
  lines << "| #{pos ? positive : negative} | #{cells.join(' | ')} | #{cells.sum} |"
end
lines << ""
by_status = table.group_by { |r| r["status"] }.transform_values(&:size).sort.map { |k, v| "#{k}: #{v}" }.join(", ")
lines << "Status: #{by_status}. Total rows: #{table.size}."
lines << ""
lines << "- ok: every auditor agreed with the label."
lines << "- reject: an auditor disagreed on an easy or medium item, the item missed its instruction. Regenerated."
lines << "- review: an auditor disagreed on a hard item, or agreed with low confidence. A human decides."
lines << "- kept / dropped: decided by a human."
lines << ""
lines << "Generator: #{table.map { |r| r['generator_model'] }.uniq.compact.join(', ')}. Languages: #{table.group_by { |r| r['language'] }.transform_values(&:size).sort.map { |k, v| "#{k} #{v}" }.join(', ')}."
lines << ""
lines << "## Auditors"
lines << ""
lines << "| Auditor | items | easy | medium | hard | mean confidence | runs |"
lines << "| --- | --- | --- | --- | --- | --- | --- |"
audits.each do |name, a|
  rows = table.select { |r| a[:verdicts][r["id"]] }
  per = %w[easy medium hard].map do |d|
    sub = rows.select { |r| r["difficulty"] == d }
    pct(sub.count { |r| a[:verdicts][r["id"]]["audit_label"].to_s != r[label_field].to_s }, sub.size)
  end
  confs = rows.map { |r| a[:verdicts][r["id"]]["confidence"].to_f }
  mean = confs.empty? ? "n/a" : format("%.2f", confs.sum / confs.size)
  lines << "| #{name} | #{rows.size} | #{per.join(' | ')} | #{mean} | #{a[:runs].size} |"
end
lines << ""
lines << "Disagreement = the auditor's blind answer differs from the label, per difficulty. Every auditor ran through audit.rb, which never sends the label to the model."
lines << ""
lines << "## Where the auditors disagree with the labels"
lines << ""
disputed = table.select { |r| audits.values.any? { |a| v = a[:verdicts][r["id"]]; v && v["audit_label"].to_s != r[label_field].to_s } }
scenario_field = label_field == "spam" ? "category" : "purpose"
by_scenario = disputed.group_by { |r| [r[label_field], r[scenario_field]] }.sort_by { |_, v| -v.size }
by_scenario.each { |(lab, sc), rows| lines << "- #{lab == 'true' ? positive : negative}, #{sc}: #{rows.size} (#{rows.map { |r| r['difficulty'] }.tally.sort.map { |k, v| "#{k} #{v}" }.join(', ')})" }
lines << ""
lines << "Decisions pending: #{table.count { |r| %w[review reject].include?(r['status']) }} rows in data/review.csv."

File.write(README, lines.join("\n") + "\n")
puts lines.join("\n")
