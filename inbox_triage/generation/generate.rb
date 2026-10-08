#!/usr/bin/env ruby
# frozen_string_literal: true

# Label-first generation of the inbox triage dataset. See SPEC.txt.
#
# Usage:
#   ANTHROPIC_API_KEY=... ruby generate.rb            # fills every cell to quota
#   ANTHROPIC_API_KEY=... ruby generate.rb --dry-run  # prints the first prompt, no API call
#   ANTHROPIC_API_KEY=... ruby generate.rb --cell=spam:hard --calls=1
#
# Writes data/mails/<id>.txt and appends to data/labels.csv. Re-runnable: fills only what is missing.
# Dependencies: Ruby stdlib only.

require "net/http"
require "json"
require "csv"
require "uri"
require "fileutils"
require "digest"
require "securerandom"

HERE = __dir__
DATA = File.join(HERE, "..", "data")
MAILS = File.join(DATA, "mails")
LABELS = File.join(DATA, "labels.csv")
QUESTIONS = File.join(HERE, "..", "questions.txt")

MODEL = "claude-sonnet-5-5"
ENDPOINT = URI("https://api.anthropic.com/v1/messages")
PER_CALL = 10
CALLS_PER_CELL = 5
QUOTA = PER_CALL * CALLS_PER_CELL # 50 per cell, 300 in all

DIFFICULTIES = {
  "easy" => "A human decides in under a second. Obvious signals.",
  "medium" => "A human has to read it. Natural vocabulary, no caricature.",
  "hard" => <<~TXT.strip
    A human hesitates, then decides. The email carries misleading signals of the opposite class,
    but an attentive reader can justify the label in one sentence. It must NOT be truly ambiguous.
    Hard ham: a subscribed newsletter that reads like marketing; a follow-up from someone met at an event;
    a supplier invoice from an unfamiliar sender; a service notification with a login link.
    Hard spam: "we met at your event" with no real detail; a fake invoice from a plausible supplier;
    a phishing mail imitating the event platform or the bank; a partnership offer that is a disguised
    sales pitch; a "member" who never was one.
  TXT
}.freeze

LENGTHS = (%w[short] * 3 + %w[medium] * 4 + %w[long] * 3).freeze # per call of 10
ALSO_MENTIONS_PER_CALL = 2 # ham emails that carry a secondary topic in passing

HARD_RULE = <<~TXT
  - Hard batch: the misleading signal must sit in the body (sender identity, wording, what is asked, a link,
    an amount), never in the subject line alone. A shouting subject on a normal body is not a hard email.
TXT

VARIETIES = [
  "institutional sender, formal tone",
  "casual tone, first names, emojis allowed",
  "plain and neutral, no particular style",
  "with an amount in DKK or EUR",
  "sent on a weekend or late at night",
  "a reply in a thread (Re:), quoting one earlier line",
  "forwarded by a colleague with a one-line comment",
  "written from a phone, signature and a couple of typos"
].freeze

# category | urgency | needs_human | situation
HAM_SCENARIOS = [
  ["membership", 2, true, "someone asks about joining, prices, a trial day, desk availability"],
  ["membership", 2, true, "a member gives notice or asks how to pause their membership"],
  ["event", 2, true, "a person or company proposes to host a meetup or workshop next month"],
  ["event", 3, true, "an organiser asks for AV, chairs or a room change for an event this week"],
  ["room_booking", 3, true, "a member books, moves or cancels a meeting room for this week"],
  ["room_booking", 2, true, "a visitor asks whether a room can be rented for a day, no date yet"],
  ["partnership", 2, true, "an organisation proposes sponsoring, co-branding or a press piece"],
  ["complaint", 3, true, "wifi, heating, noise, cleaning, a bad experience, a request to fix it"],
  ["complaint", 4, true, "access card not working, a person locked out, a security issue right now"],
  ["billing", 3, true, "an invoice question, a receipt request, a VAT number to add, a failed card"],
  ["newsletter", 1, false, "a newsletter the recipient subscribed to (coworking, tech, city, a tool)"],
  ["newsletter", 1, false, "an automatic notification from a service in use (event platform, bank, parcel, booking tool)"],
  ["other", 1, false, "a thank-you note or a pure FYI, nothing to answer"],
  ["other", 2, true, "lost and found, a question that fits no category"]
].freeze

SPAM_SITUATIONS = [
  "cold sales outreach (software, lead generation, outsourcing, design agency)",
  "SEO, backlink or guest-post offer",
  "phishing: fake invoice, fake login, fake parcel, fake payment failure",
  "scam: investment, prize, inheritance, crypto",
  "mass marketing with no subscription (a webinar, a conference, a product launch)",
  "recruitment or staffing blast",
  "fake partnership or \"we met at your event\" with no substance"
].freeze

LANGUAGES = (["en"] * 6 + ["da"] * 2 + ["fr"] * 2).freeze # 60 / 20 / 20 per call of 10

CSV_HEADER = %w[id spam category urgency needs_human difficulty language variety generator_model
                justification audit_label audit_confidence audit_model status].freeze

# Only the four question blocks, not the "how the demo uses the answers" section.
def definitions
  File.read(QUESTIONS).split(/^-+\nHow the demo uses/).first.strip
end

def prompt_template
  File.read(File.join(HERE, "prompt_generate.txt"))
end

# "We met at your event" is never easy: a blind auditor read it as a relationship (audit of 2026-10-07).
def spam_situations(difficulty)
  difficulty == "easy" ? SPAM_SITUATIONS.reject { |s| s.start_with?("fake partnership") } : SPAM_SITUATIONS
end

# One hash per email. Length, style and a secondary topic vary inside the batch.
def scenario_lines(spam, seed, difficulty = "medium")
  rng = Random.new(seed)
  langs = LANGUAGES.shuffle(random: rng)
  lengths = LENGTHS.shuffle(random: rng)
  styles = VARIETIES.shuffle(random: rng)
  also_at = spam ? [] : (0...PER_CALL).to_a.sample(ALSO_MENTIONS_PER_CALL, random: rng)
  Array.new(PER_CALL) do |i|
    base = if spam
             { spam: true, category: "spam", urgency: 1, needs_human: false,
               situation: spam_situations(difficulty)[(seed + i) % spam_situations(difficulty).size] }
           else
             cat, urg, human, situation = HAM_SCENARIOS[(seed + i) % HAM_SCENARIOS.size]
             { spam: false, category: cat, urgency: urg, needs_human: human, situation: situation }
           end
    # A secondary topic never outranks the main one in urgency, so the labels stay those of the main topic.
    also = nil
    if also_at.include?(i)
      other = HAM_SCENARIOS.reject { |c, u, *| c == base[:category] || u > base[:urgency] }.sample(random: rng)
      also = other&.last
    end
    # Newsletters and notifications are machine-sent: no phone typos, no casual chat.
    style = styles[i % styles.size]
    style = "plain and neutral, no particular style" if base[:category] == "newsletter" && style !~ /institutional|plain/
    # Spam forwarded by a colleague is a colleague's email, not spam.
    style = "plain and neutral, no particular style" if spam && style =~ /forwarded/
    base.merge(language: langs[i], length: lengths[i], style: style, also: also)
  end
end

def render_prompt(difficulty, scenarios)
  lines = scenarios.each_with_index.map do |sc, i|
    line = "#{i + 1}. spam=#{sc[:spam]} category=#{sc[:category]} urgency=#{sc[:urgency]} needs_human=#{sc[:needs_human]} " \
           "language=#{sc[:language]} length=#{sc[:length]} style=#{sc[:style]} | #{sc[:situation]}"
    line += " | also mentions: #{sc[:also]}" if sc[:also]
    line
  end
  prompt_template
    .sub("{n}", PER_CALL.to_s)
    .sub("{definitions}", definitions)
    .sub("{difficulty}", difficulty)
    .sub("{difficulty_definition}", DIFFICULTIES.fetch(difficulty))
    .sub("{hard_rule}", difficulty == "hard" ? HARD_RULE : "")
    .sub("{scenarios}", lines.join("\n"))
end

def api_key
  key = ENV["ANTHROPIC_API_KEY"]
  abort "ANTHROPIC_API_KEY is not set" if key.nil? || key.empty?
  key
end

def call_claude(prompt)
  req = Net::HTTP::Post.new(ENDPOINT)
  req["x-api-key"] = api_key
  req["anthropic-version"] = "2023-06-01"
  req["anthropic-beta"] = "server-side-fallback-2026-07-01"
  req["content-type"] = "application/json"
  req.body = {
    model: MODEL,
    max_tokens: 16_000,
    fallbacks: "default",
    messages: [{ role: "user", content: prompt }]
  }.to_json
  res = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, read_timeout: 300) { |http| http.request(req) }
  raise "Anthropic #{res.code}: #{res.body[0, 400]}" unless res.is_a?(Net::HTTPSuccess)

  body = JSON.parse(res.body)
  raise "refused: #{body.dig('stop_details', 'category')}" if body["stop_reason"] == "refusal"

  text = body["content"].select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
  [parse_json_array(text), body["model"], body["usage"]]
end

def parse_json_array(text)
  cleaned = text.strip.sub(/\A```(?:json)?\s*/, "").sub(/```\s*\z/, "")
  start = cleaned.index("[")
  finish = cleaned.rindex("]")
  raise "no JSON array in answer: #{text[0, 200]}" if start.nil? || finish.nil?

  JSON.parse(cleaned[start..finish])
end

def existing_rows
  return [] unless File.exist?(LABELS)

  CSV.read(LABELS, headers: true).map(&:to_h)
end

def count(rows, spam, difficulty)
  rows.count { |r| r["spam"] == spam.to_s && r["difficulty"] == difficulty && r["status"] != "reject" }
end

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

def append_rows(rows)
  new_file = !File.exist?(LABELS)
  CSV.open(LABELS, "a") do |csv|
    csv << CSV_HEADER if new_file
    rows.each { |r| csv << CSV_HEADER.map { |k| r[k] } }
  end
end

def run(cells, calls_limit, dry_run)
  FileUtils.mkdir_p(MAILS)
  rows = existing_rows
  seen = rows.map { |r| Digest::SHA1.hexdigest(normalized(File.read(File.join(MAILS, "#{r['id']}.txt")))) rescue nil }.compact.to_a
  usage_total = Hash.new(0)
  calls_done = 0

  cells.each do |spam, difficulty|
    have = count(rows, spam, difficulty)
    next if have >= QUOTA

    call_index = $first_call
    while count(rows, spam, difficulty) < QUOTA && call_index < CALLS_PER_CELL + 2
      break if calls_limit && calls_done >= calls_limit

      # Deterministic: Array#hash changes per Ruby process, so prompt and scenario exports would not match.
      seed = (spam ? 1000 : 0) + DIFFICULTIES.keys.index(difficulty) * 100 + call_index
      scenarios = scenario_lines(spam, seed, difficulty)
      prompt = render_prompt(difficulty, scenarios)

      if dry_run == :scenarios
        puts JSON.pretty_generate(scenarios)
        return
      elsif dry_run
        puts prompt
        return
      end

      puts "cell spam=#{spam} #{difficulty} call #{call_index + 1} (#{count(rows, spam, difficulty)}/#{QUOTA})"
      mails, model, usage = call_claude(prompt)
      usage.each { |k, v| usage_total[k] += v if v.is_a?(Integer) }
      calls_done += 1
      call_index += 1

      new_rows = []
      mails.each_with_index do |mail, i|
        sc = scenarios[i] || scenarios.last
        digest = Digest::SHA1.hexdigest(normalized(mail["body"].to_s))
        next if seen.include?(digest)

        seen << digest
        id = next_id(spam, difficulty)
        write_mail(id, mail)
        new_rows << {
          "id" => id, "spam" => sc[:spam], "category" => sc[:category], "urgency" => sc[:urgency], "needs_human" => sc[:needs_human],
          "difficulty" => difficulty, "language" => sc[:language], "variety" => "#{sc[:length]}, #{sc[:style]}", "generator_model" => model,
          "justification" => mail["justification"], "audit_label" => nil, "audit_confidence" => nil,
          "audit_model" => nil, "status" => "generated"
        }
      end
      append_rows(new_rows)
      rows.concat(new_rows)
      puts "  +#{new_rows.size} (dedup dropped #{mails.size - new_rows.size})"
    end
  end

  puts "done. calls: #{calls_done}. usage: #{usage_total}"
end

cells = [false, true].product(DIFFICULTIES.keys)
calls_limit = nil
$first_call = 0 # --call=k: export (dry run) the k-th call of the cell, 0-based
dry_run = false
ARGV.each do |arg|
  case arg
  when /\A--cell=(spam|ham):(easy|medium|hard)\z/ then cells = [[Regexp.last_match(1) == "spam", Regexp.last_match(2)]]
  when /\A--calls=(\d+)\z/ then calls_limit = Regexp.last_match(1).to_i
  when "--dry-run" then dry_run = true
  when "--scenarios" then dry_run = :scenarios # prints the scenario JSON of the next call, for ingest.rb batches
  when /\A--call=(\d+)\z/ then $first_call = Regexp.last_match(1).to_i
  else abort "unknown argument #{arg}"
  end
end
run(cells, calls_limit, dry_run)
