#!/usr/bin/env ruby
# frozen_string_literal: true

# Writes data/mails/*.txt and data/labels.csv from a batch JSON produced by a Claude Code subagent
# (same prompt as generate.rb, same output format). Lets the dataset be generated without an API key.
#
# Usage: ruby ingest.rb data/batches/ham_hard_1.json [more.json ...]
#
# Batch JSON:
# { "spam": false, "difficulty": "hard", "variety": "...", "generator_model": "claude-sonnet-5-5",
#   "scenarios": [{"spam": false, "category": "...", "urgency": 2, "needs_human": true, "language": "en", "situation": "..."}, ...],
#   "mails": [{"from": "...", "subject": "...", "date": "...", "body": "...", "justification": "..."}, ...] }
# mails[i] follows scenarios[i].

require "json"
require "csv"
require "fileutils"
require "digest"
require "securerandom"

HERE = __dir__
DATA = File.join(HERE, "..", "data")
MAILS = File.join(DATA, "mails")
LABELS = File.join(DATA, "labels.csv")
CSV_HEADER = %w[id spam category urgency needs_human difficulty language variety generator_model
                justification audit_label audit_confidence audit_model status].freeze

def normalized(text)
  text.downcase.gsub(/\s+/, " ").strip
end

# Opaque id: the file name must not leak the label or the cell to whoever reads the folder.
def next_id(_spam, _difficulty)
  loop do
    id = "m#{SecureRandom.hex(3)}"
    return id unless File.exist?(File.join(MAILS, "#{id}.txt"))
  end
end

def write_mail(id, mail)
  File.write(File.join(MAILS, "#{id}.txt"), <<~MAIL)
    From: #{mail['from']}
    Subject: #{mail['subject']}
    Date: #{mail['date']}

    #{mail['body'].to_s.strip}
  MAIL
end

FileUtils.mkdir_p(MAILS)
seen = Dir.glob(File.join(MAILS, "*.txt")).map { |f| Digest::SHA1.hexdigest(normalized(File.read(f).split("\n\n", 2).last.to_s)) }
new_file = !File.exist?(LABELS)

CSV.open(LABELS, "a") do |csv|
  csv << CSV_HEADER if new_file
  ARGV.each do |path|
    batch = JSON.parse(File.read(path))
    spam = batch.fetch("spam")
    difficulty = batch.fetch("difficulty")
    added = 0
    batch.fetch("mails").each_with_index do |mail, i|
      sc = batch.fetch("scenarios")[i] or abort "#{path}: mail #{i} has no scenario"
      digest = Digest::SHA1.hexdigest(normalized(mail["body"].to_s))
      next if seen.include?(digest)

      seen << digest
      id = next_id(spam, difficulty)
      write_mail(id, mail)
      csv << [id, spam, sc["category"], sc["urgency"], sc["needs_human"], difficulty, sc["language"],
              sc["style"] ? "#{sc['length']}, #{sc['style']}" : batch["variety"], batch["generator_model"],
              mail["justification"], nil, nil, nil, "generated"]
      added += 1
    end
    puts "#{File.basename(path)}: +#{added} (#{batch['mails'].size - added} duplicates dropped)"
  end
end
