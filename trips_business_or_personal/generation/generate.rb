#!/usr/bin/env ruby
# frozen_string_literal: true

# Label-first generation of the trips dataset. See SPEC.txt.
#
# Usage:
#   ruby generate.rb --cell=business:hard --call=0 --dry-run    # prints the prompt of that call, no API call
#   ruby generate.rb --cell=business:hard --call=0 --scenarios  # prints the scenario JSON of that call
#   ANTHROPIC_API_KEY=... ruby generate.rb                      # fills every cell to quota through the API
#
# The Claude Code path: export prompt and scenarios into data/batches/, a subagent writes
# data/batches/<cell>_<k>.json, ingest.rb writes data/trips.csv and data/labels.csv.
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
TRIPS = File.join(DATA, "trips.csv")
LABELS = File.join(DATA, "labels.csv")
QUESTIONS = File.join(HERE, "..", "questions.txt")

MODEL = "claude-sonnet-5-5"
ENDPOINT = URI("https://api.anthropic.com/v1/messages")
PER_CALL = 10
CALLS_PER_CELL = 5
QUOTA = PER_CALL * CALLS_PER_CELL # 50 per cell, 300 in all

DIFFICULTIES = {
  "easy" => "Obvious in one glance: the note names a client, a meeting or a private purpose, and the addresses and time agree with it.",
  "medium" => "The note is short, abbreviated or absent; the addresses, the day and the time carry the signal, and a human reads them to decide.",
  "hard" => <<~TXT.strip
    Misleading signals of the opposite class, but an attentive reader justifies the label in one sentence. NOT truly ambiguous.
    Hard business: Saturday client dinner; Sunday airport pickup of a visiting client; café with a prospect; a colleague's home
    for a work session; home straight to a client at 8:30 (looks like a commute); a rental car abroad with a hotel as start.
    Hard personal: home to the usual office (commute); lunch alone near the office at 12:30; dropping a partner at their
    workplace; a trade fair visited on a day off; the gym next to the office; a weekend trip to Malmö with friends; an
    airport run for a holiday.
  TXT
}.freeze

HARD_RULE = <<~TXT
  - Hard batch: the misleading signal must sit in the record itself (the day, the hour, the kind of place, the wording
    of the note), and the deciding detail must still be there for an attentive reader.
TXT

# purpose | situation
BUSINESS_SCENARIOS = [
  ["client_meeting", "office or home to a client's office, weekday, working hours"],
  ["prospect_meeting", "a café or the prospect's office, first meeting, note may name a person"],
  ["supplier_visit", "to a supplier, a printer, a warehouse, a workshop"],
  ["between_sites", "between two sites of the same company (office, shop, storage, second office)"],
  ["conference", "to a conference venue, a trade fair attended for work, or a training, sometimes in another city"],
  ["airport_work", "home or office to the airport or the central station for a work trip, or the return"],
  ["site_visit", "a construction site, a store opening, a property, a customer installation"],
  ["business_meal", "a restaurant with a client or a partner, lunch or dinner, sometimes evening or weekend"],
  ["client_pickup", "picking up a visiting client or candidate at the airport, station or hotel"],
  ["rental_abroad", "a rental car between a hotel and a client or a venue in another city"],
  ["company_errand", "bank, post office, customs, a hardware store for the company, a delivery to a customer"]
].freeze

PERSONAL_SCENARIOS = [
  ["commute", "home to the usual workplace or back, weekday, rush hour"],
  ["school_run", "dropping or picking up children"],
  ["groceries", "supermarket, mall, hardware store for home"],
  ["doctor", "doctor, dentist, physiotherapist, hospital visit"],
  ["sport", "gym, swimming, football, running club"],
  ["family_friends", "visiting family or friends, a birthday, a dinner at someone's home"],
  ["leisure_trip", "a weekend away, a summerhouse, a museum, a concert, a beach"],
  ["airport_holiday", "airport or station for a holiday or a private visit, or the return"],
  ["restaurant_private", "a restaurant or café without any work purpose"],
  ["partner_dropoff", "dropping a partner or a friend at their workplace or station"],
  ["lunch_alone", "lunch alone during work hours"],
  ["shopping", "furniture, clothes, electronics, a gift"]
].freeze

# The hard cells lean on the scenarios a human hesitates on; the easy cells avoid them.
HARD_BUSINESS = %w[business_meal client_pickup prospect_meeting rental_abroad client_meeting airport_work].freeze
HARD_PERSONAL = %w[commute lunch_alone partner_dropoff airport_holiday leisure_trip sport restaurant_private].freeze
EASY_EXCLUDE = %w[commute lunch_alone partner_dropoff business_meal client_pickup rental_abroad].freeze

NOTE_STYLES = (%w[none] * 3 + %w[words] * 2 + %w[short] * 3 + %w[sentence] * 2).freeze
LANGUAGES = (["en"] * 6 + ["da"] * 2 + ["fr"] * 2).freeze

CSV_HEADER = %w[id business purpose difficulty language note_style generator_model justification
                audit_label audit_confidence audit_model status].freeze
TRIP_HEADER = %w[id date start_time duration_min distance_km start_address end_address note].freeze

def definitions
  File.read(QUESTIONS).split(/^-+\nHow the demo uses/).first.strip
end

def prompt_template
  File.read(File.join(HERE, "prompt_generate.txt"))
end

def scenarios_for(business, difficulty)
  list = business ? BUSINESS_SCENARIOS : PERSONAL_SCENARIOS
  case difficulty
  when "easy" then list.reject { |p, _| EASY_EXCLUDE.include?(p) }
  when "hard" then list.select { |p, _| (business ? HARD_BUSINESS : HARD_PERSONAL).include?(p) }
  else list
  end
end

def scenario_lines(business, seed, difficulty)
  rng = Random.new(seed)
  langs = LANGUAGES.shuffle(random: rng)
  styles = NOTE_STYLES.shuffle(random: rng)
  pool = scenarios_for(business, difficulty)
  Array.new(PER_CALL) do |i|
    purpose, situation = pool[(seed + i) % pool.size]
    { business: business, purpose: purpose, situation: situation, language: langs[i], note_style: styles[i] }
  end
end

def render_prompt(difficulty, scenarios)
  lines = scenarios.each_with_index.map do |sc, i|
    "#{i + 1}. business=#{sc[:business]} purpose=#{sc[:purpose]} language=#{sc[:language]} note_style=#{sc[:note_style]} | #{sc[:situation]}"
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
  workspace = ENV["ANTHROPIC_WORKSPACE_ID"]
  req["anthropic-workspace-id"] = workspace if workspace && !workspace.empty?
  req.body = { model: MODEL, max_tokens: 16_000, fallbacks: "default",
               messages: [{ role: "user", content: prompt }] }.to_json
  res = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, read_timeout: 300) { |http| http.request(req) }
  raise "Anthropic #{res.code}: #{res.body[0, 400]}" unless res.is_a?(Net::HTTPSuccess)

  body = JSON.parse(res.body)
  raise "refused: #{body.dig('stop_details', 'category')}" if body["stop_reason"] == "refusal"

  text = body["content"].select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
  cleaned = text.strip.sub(/\A```(?:json)?\s*/, "").sub(/```\s*\z/, "")
  [JSON.parse(cleaned[cleaned.index("[")..cleaned.rindex("]")]), body["model"]]
end

def existing_rows
  return [] unless File.exist?(LABELS)

  CSV.read(LABELS, headers: true).map(&:to_h)
end

def count(rows, business, difficulty)
  rows.count { |r| r["business"] == business.to_s && r["difficulty"] == difficulty && r["status"] != "reject" }
end

def next_id
  loop do
    id = "t#{SecureRandom.hex(3)}"
    return id unless File.exist?(TRIPS) && File.read(TRIPS).include?("#{id},")
  end
end

def append(path, header, rows)
  new_file = !File.exist?(path)
  CSV.open(path, "a") do |csv|
    csv << header if new_file
    rows.each { |r| csv << header.map { |k| r[k] } }
  end
end

def run(cells, calls_limit, dry_run)
  FileUtils.mkdir_p(DATA)
  rows = existing_rows
  calls_done = 0

  cells.each do |business, difficulty|
    call_index = $first_call
    while count(rows, business, difficulty) < QUOTA && call_index < CALLS_PER_CELL + 2
      break if calls_limit && calls_done >= calls_limit

      seed = (business ? 1000 : 0) + DIFFICULTIES.keys.index(difficulty) * 100 + call_index
      scenarios = scenario_lines(business, seed, difficulty)
      prompt = render_prompt(difficulty, scenarios)

      if dry_run == :scenarios
        puts JSON.pretty_generate(scenarios)
        return
      elsif dry_run
        puts prompt
        return
      end

      puts "cell business=#{business} #{difficulty} call #{call_index + 1} (#{count(rows, business, difficulty)}/#{QUOTA})"
      trips, model = call_claude(prompt)
      calls_done += 1
      call_index += 1

      trip_rows = []
      label_rows = []
      trips.each_with_index do |trip, i|
        sc = scenarios[i] || scenarios.last
        id = next_id
        trip_rows << trip.merge("id" => id)
        label_rows << { "id" => id, "business" => sc[:business], "purpose" => sc[:purpose], "difficulty" => difficulty,
                        "language" => sc[:language], "note_style" => sc[:note_style], "generator_model" => model,
                        "justification" => trip["justification"], "status" => "generated" }
      end
      append(TRIPS, TRIP_HEADER, trip_rows)
      append(LABELS, CSV_HEADER, label_rows)
      rows.concat(label_rows)
      puts "  +#{trip_rows.size}"
    end
  end
  puts "done. calls: #{calls_done}"
end

cells = [true, false].product(DIFFICULTIES.keys)
calls_limit = nil
dry_run = false
$first_call = 0
ARGV.each do |arg|
  case arg
  when /\A--cell=(business|personal):(easy|medium|hard)\z/ then cells = [[Regexp.last_match(1) == "business", Regexp.last_match(2)]]
  when /\A--calls=(\d+)\z/ then calls_limit = Regexp.last_match(1).to_i
  when /\A--call=(\d+)\z/ then $first_call = Regexp.last_match(1).to_i
  when "--dry-run" then dry_run = true
  when "--scenarios" then dry_run = :scenarios
  else abort "unknown argument #{arg}"
  end
end
run(cells, calls_limit, dry_run)
