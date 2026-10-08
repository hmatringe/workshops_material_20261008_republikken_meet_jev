#!/usr/bin/env ruby
# frozen_string_literal: true

# Blind audit of the generated trips. See SPEC.txt.
# Each auditor writes its own file, data/audits/<model>.csv. The status in data/labels.csv is computed
# from every auditor file present: a mail is "ok" only when every auditor agrees with its label.
#
# Usage:
#   ruby audit.rb                                   # Gemma 4 via Ollama, local (default)
#   ruby audit.rb --engine=ollama --model=gemma4:26b
#   ANTHROPIC_API_KEY=sk-... ruby audit.rb --engine=claude          # Claude Sonnet 5.5 via the Anthropic API
#   (an organisation-scoped key also needs ANTHROPIC_WORKSPACE_ID=wrkspc_...)
#   ruby audit.rb --engine=claude --model=claude-opus-5-5
#   ruby audit.rb --limit=5                         # first 5 pending mails, to check the setup
#   ruby audit.rb --status                          # no API call: recompute statuses and review.csv only
#
# Audits only the mails this auditor has not seen yet. Re-runnable. Saves after every mail.
# Dependencies: Ruby stdlib only.

require "net/http"
require "json"
require "csv"
require "uri"
require "fileutils"
require "date"

HERE = __dir__
DATA = File.join(HERE, "..", "data")
TRIPS = File.join(DATA, "trips.csv")
LABELS = File.join(DATA, "labels.csv")
AUDITS = File.join(DATA, "audits")
REVIEW = File.join(DATA, "review.csv")
QUESTIONS = File.join(HERE, "..", "questions.txt")

OLLAMA = URI("http://localhost:11434/api/chat")
ANTHROPIC = URI("https://api.anthropic.com/v1/messages")
LOW_CONFIDENCE = 0.6
TIMEOUT = 120 # a verdict is about 60 tokens: anything past this is a failure, not a wait
AUDIT_HEADER = %w[id business audit_label confidence reason seconds].freeze

# The record as the models under test see it: fields in words, plus weekday computed in code.
def trip_text(id)
  @trips ||= CSV.read(TRIPS, headers: true).to_h { |r| [r["id"], r] }
  t = @trips.fetch(id)
  weekday = Date.parse(t["date"]).strftime("%A")
  <<~TXT.strip
    date: #{t['date']} (#{weekday})
    start time: #{t['start_time']}
    duration: #{t['duration_min']} min
    distance: #{t['distance_km']} km
    from: #{t['start_address']}
    to: #{t['end_address']}
    note: #{t['note'].to_s.empty? ? '(none)' : t['note']}
  TXT
end

def prompt_for(trip_text)
  File.read(File.join(HERE, "prompt_audit.txt"))
    .sub("{definitions}", File.read(QUESTIONS).split(/^-+\nHow the demo uses/).first.strip)
    .sub("{trip}", trip_text)
end

# Tolerates a verdict cut in the middle of its "reason" string: closes the string and the object.
def extract_json(content)
  raise "empty answer" if content.strip.empty? || content.index("{").nil?

  fragment = content[content.index("{")..(content.rindex("}") || -1)]
  JSON.parse(fragment)
rescue JSON::ParserError
  JSON.parse(fragment.sub(/,?\s*"reason"\s*:\s*"[^"]*\z/, "") + "}")
end

# think: false. Gemma 4 otherwise reasons at length, burns the token budget in "thinking" and returns
# an empty content. num_predict caps the verdict. keep_alive keeps the model in memory between mails.
def ask_ollama(model, prompt)
  req = Net::HTTP::Post.new(OLLAMA)
  req["content-type"] = "application/json"
  req.body = { model:, stream: false, format: "json", keep_alive: "30m", think: false,
               options: { temperature: 0, num_predict: 300 },
               messages: [{ role: "user", content: prompt }] }.to_json
  res = Net::HTTP.start(OLLAMA.host, OLLAMA.port, read_timeout: TIMEOUT) { |http| http.request(req) }
  raise "Ollama #{res.code}: #{res.body[0, 300]}" unless res.is_a?(Net::HTTPSuccess)

  body = JSON.parse(res.body)
  content = body.dig("message", "content").to_s
  raise "empty answer (done_reason=#{body['done_reason']})" if content.strip.empty?

  extract_json(content)
end

# Low effort: a classification, no long reasoning needed. The key never leaves the environment variable.
def ask_claude(model, prompt)
  key = ENV["ANTHROPIC_API_KEY"]
  abort "ANTHROPIC_API_KEY is not set. Run: ANTHROPIC_API_KEY=sk-... ruby audit.rb --engine=claude" if key.nil? || key.empty?

  req = Net::HTTP::Post.new(ANTHROPIC)
  req["x-api-key"] = key
  req["anthropic-version"] = "2023-06-01"
  req["anthropic-beta"] = "server-side-fallback-2026-07-01"
  req["content-type"] = "application/json"
  # An organisation-scoped key (console: scope "Organization") must name the workspace to bill.
  workspace = ENV["ANTHROPIC_WORKSPACE_ID"]
  req["anthropic-workspace-id"] = workspace if workspace && !workspace.empty?
  req.body = { model:, max_tokens: 1000, fallbacks: "default", output_config: { effort: "low" },
               messages: [{ role: "user", content: prompt }] }.to_json
  res = Net::HTTP.start(ANTHROPIC.host, ANTHROPIC.port, use_ssl: true, read_timeout: TIMEOUT) { |http| http.request(req) }
  abort "Anthropic 401: the key is refused. Check it with: curl -s https://api.anthropic.com/v1/models -H \"x-api-key: $ANTHROPIC_API_KEY\" -H \"anthropic-version: 2023-06-01\"" if res.code == "401"
  abort "Anthropic 400: #{res.body[0, 300]}\nSet ANTHROPIC_WORKSPACE_ID (console > Settings > Workspaces, id starts with wrkspc_) and run again." if res.code == "400" && res.body.include?("workspace")
  raise "Anthropic #{res.code}: #{res.body[0, 300]}" unless res.is_a?(Net::HTTPSuccess)

  body = JSON.parse(res.body)
  raise "refused (#{body.dig('stop_details', 'category')})" if body["stop_reason"] == "refusal"

  extract_json(body["content"].select { |b| b["type"] == "text" }.map { |b| b["text"] }.join)
end

def slug(model)
  model.gsub(/[^a-z0-9]+/i, "_")
end

# One file per run: data/audits/<YYYYMMDD-HHMMSS>-<model>.csv
def new_audit_path(model)
  File.join(AUDITS, "#{Time.now.strftime('%Y%m%d-%H%M%S')}-#{slug(model)}.csv")
end

def audited_ids(model)
  Dir.glob(File.join(AUDITS, "*-#{slug(model)}.csv")).flat_map { |p| CSV.read(p, headers: true).map { |r| r["id"] } }.uniq
end

# Verdicts per model, the latest run winning for a given mail (files sort by their timestamp prefix).
def load_audits
  Dir.glob(File.join(AUDITS, "*.csv")).sort.each_with_object({}) do |path, audits|
    name = File.basename(path, ".csv").sub(/\A\d{8}-\d{6}-/, "")
    audits[name] ||= {}
    CSV.read(path, headers: true).each { |r| audits[name][r["id"]] = r }
  end
end

# ok: every auditor agrees with the label, with confidence. Disagreement on easy or medium: the mail
# missed its instruction, reject. Disagreement on hard: expected, a human decides. Hesitant agreement: review.
def status_for(row, verdicts)
  return "generated" if verdicts.empty?

  statuses = verdicts.map do |v|
    agree = v["audit_label"].to_s == row["business"].to_s
    if agree
      v["confidence"].to_f < LOW_CONFIDENCE ? "review" : "ok"
    else
      row["difficulty"] == "hard" ? "review" : "reject"
    end
  end
  %w[reject review ok].find { |s| statuses.include?(s) }
end

def recompute_statuses(table)
  audits = load_audits
  table.each do |row|
    next if %w[kept dropped].include?(row["status"]) # decided by the human, never overwritten

    verdicts = audits.values.filter_map { |by_id| by_id[row["id"]] }
    row["audit_label"] = verdicts.map { |v| v["audit_label"] }.join(";")
    row["audit_confidence"] = verdicts.map { |v| v["confidence"] }.join(";")
    row["audit_model"] = audits.select { |_, by_id| by_id[row["id"]] }.keys.join(";")
    row["status"] = status_for(row, verdicts)
  end
  File.write(LABELS, table.to_csv)

  review = table.select { |r| %w[review reject].include?(r["status"]) }
  CSV.open(REVIEW, "w") do |csv|
    csv << %w[id status business audit_label audit_model difficulty justification]
    review.each { |r| csv << [r["id"], r["status"], r["business"], r["audit_label"], r["audit_model"], r["difficulty"], r["justification"]] }
  end

  puts "status: #{table.group_by { |r| r['status'] }.transform_values(&:size)}"
  audits.each do |name, by_id|
    per = table.select { |r| by_id[r["id"]] }.group_by { |r| r["difficulty"] }.transform_values do |rows|
      disagree = rows.count { |r| by_id[r["id"]]["audit_label"].to_s != r["business"].to_s }
      format("%d/%d (%.0f%%)", disagree, rows.size, 100.0 * disagree / rows.size)
    end
    puts "#{name} disagrees: #{per}"
  end
  puts "#{review.size} rows to review in #{REVIEW}. Stopping here: the human decides."
end

engine = "ollama"
model = nil
limit = nil
status_only = false
ARGV.each do |arg|
  case arg
  when /\A--engine=(ollama|claude)\z/ then engine = Regexp.last_match(1)
  when /\A--model=(.+)\z/ then model = Regexp.last_match(1)
  when /\A--limit=(\d+)\z/ then limit = Regexp.last_match(1).to_i
  when "--status" then status_only = true
  else abort "unknown argument #{arg}"
  end
end
model ||= engine == "claude" ? "claude-sonnet-5-5" : "gemma4:26b"

$stdout.sync = true
FileUtils.mkdir_p(AUDITS)
table = CSV.read(LABELS, headers: true)

unless status_only
  path = new_audit_path(model)
  done = audited_ids(model)
  pending = table.reject { |r| done.include?(r["id"]) || %w[kept dropped].include?(r["status"]) }
  pending = pending.first(limit) if limit
  total = pending.size
  puts "auditing #{total} trips with #{model} via #{engine} (#{done.size} already done)"
  puts "first call also loads the model, allow a few minutes" if engine == "ollama" && done.empty?

  started = Time.now
  pending.each_with_index do |row, i|
    print format("reviewing trip %d / %d (%s)... ", i + 1, total, row["id"])
    t0 = Time.now
    trip = trip_text(row["id"])
    verdict = begin
      engine == "claude" ? ask_claude(model, prompt_for(trip)) : ask_ollama(model, prompt_for(trip))
    rescue JSON::ParserError
      print "(retry) "
      engine == "claude" ? ask_claude(model, prompt_for(trip)) : ask_ollama(model, prompt_for(trip))
    end
    seconds = (Time.now - t0).round
    new_file = !File.exist?(path)
    CSV.open(path, "a") do |csv|
      csv << AUDIT_HEADER if new_file
      csv << [row["id"], row["business"], verdict["business"], verdict["confidence"], verdict["reason"], seconds]
    end
    elapsed = (Time.now - started).round
    puts format("%ds  label=%-5s audit=%-5s conf=%.2f  %s  elapsed %dm%02ds",
                seconds, row["business"], verdict["business"], verdict["confidence"].to_f,
                verdict["business"].to_s == row["business"].to_s ? "agree   " : "DISAGREE", elapsed / 60, elapsed % 60)
  rescue StandardError => e
    puts "FAILED: #{e.message}"
  end
end

# Reload: rows may have been ingested while this run was going, and must not be lost on write.
recompute_statuses(CSV.read(LABELS, headers: true))
