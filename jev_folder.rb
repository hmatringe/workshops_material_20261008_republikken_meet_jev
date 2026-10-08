#!/usr/bin/env ruby
# frozen_string_literal: true

# The take-home: point Jev at your own folder of emails or your own CSV of trips, get a CSV back with a
# decision and a probability per question, and a "check" column where it hesitates. Edit the questions
# in questions.txt, run again, watch the probabilities move.
#
#   export TYPESAFE_API_KEY=...
#   ruby jev_folder.rb inbox  path/to/folder_of_txt_emails   [--out=results.csv] [--limit=20]
#   ruby jev_folder.rb trips  path/to/trips.csv               [--out=results.csv] [--limit=20]
#
# Emails: one .txt per email, any content. Trips: a CSV with date, start_time, duration_min, distance_km,
# start_address, end_address, note (the id column is optional).
# Dependencies: Ruby stdlib only.

require "csv"
require "json"
require_relative "lib/jev"
require_relative "lib/datasets"

BATCH = 10
BAND = (0.35..0.65) # the "check" band: the app asks a person instead of deciding

# The questions, as in <dataset>/questions.txt. Edit there to change the demo; edit here to change the goodie.
INBOX_QUESTIONS = {
  spam: { type: "noul", instructions: "Is this message unsolicited?",
          criteria: { true: Datasets::INBOX_QUESTION[:criteria][:true], false: Datasets::INBOX_QUESTION[:criteria][:false] } },
  category: { type: "choice", instructions: "What is this message mainly about?",
              criteria: { membership: "joining the space, prices, trial day, desk availability, leaving",
                          event: "hosting or proposing an event, meetup, workshop, AV or room setup for an event",
                          room_booking: "booking, changing or cancelling a meeting room or a desk for a day",
                          partnership: "sponsoring, co-branding, press, a collaboration proposal from an organisation",
                          complaint: "something is wrong: noise, wifi, access card, heating, cleaning, a bad experience",
                          billing: "invoices, payments, receipts, VAT numbers, failed card",
                          newsletter: "a subscribed newsletter or an automatic notification from a service in use",
                          spam: "unsolicited commercial, fraudulent or irrelevant message",
                          other: "anything else: thanks, lost and found, a question that fits no option" } },
  urgency: { type: "score", instructions: "How soon does this message need action?",
             criteria: ["no action needed: a newsletter, a notification, a thank-you note, spam",
                        "answer within the week: a general question, a proposal for next month, a request with no date",
                        "answer within 24 hours: a request for this week, a booking change, a payment question",
                        "answer today: something happening today or tomorrow, a person locked out, a safety issue, a payment failing right now"] },
  needs_human: { type: "noul", instructions: "Does this message need a reply written by a person?",
                 criteria: { true: "the sender asks something, requests something, or reports a problem, and expects a reply",
                             false: "nothing to reply to: newsletters, notifications, automatic replies, spam, pure FYI" } }
}.freeze

TRIPS_QUESTIONS = {
  business: { type: "noul", instructions: "Is this a business trip?",
              criteria: { true: Datasets::TRIPS_QUESTION[:criteria][:true], false: Datasets::TRIPS_QUESTION[:criteria][:false] } }
}.freeze

def load_items(kind, path)
  case kind
  when "inbox"
    Dir[File.join(path, "*.txt")].sort.map { |f| { id: File.basename(f, ".txt"), text: File.read(f).strip } }
  when "trips"
    CSV.read(path, headers: true).each_with_index.map { |r, i| { id: r["id"] || "row#{i + 1}", text: Datasets.trip_text(r) } }
  end
end

def ask(questions, items, context)
  items.each_slice(BATCH).flat_map do |slice|
    qs = {}
    slice.each_with_index do |item, i|
      questions.each do |name, spec|
        qs["#{i}_#{name}"] = spec.merge(instructions: { context: context, record: item[:text], question: spec[:instructions] })
      end
    end
    answers, usage, ms = Jev.evaluate(state: {}, questions: qs)
    $stderr.puts "#{slice.size} records, #{questions.size * slice.size} questions, #{ms} ms, #{usage[:input_tokens]} tokens, $#{format('%.5f', Jev.cost_usd(usage[:input_tokens].to_i))}"
    slice.each_with_index.map do |item, i|
      row = { "id" => item[:id] }
      questions.each do |name, spec|
        a = answers[:"#{i}_#{name}"] || {}
        case spec[:type]
        when "noul"
          p = a[:noul].to_f
          row["#{name}"] = p >= 0.5
          row["#{name}_p"] = p.round(3)
          row["#{name}_check"] = BAND.cover?(p) ? "check" : ""
        when "choice"
          row["#{name}"] = a[:choice]
          row["#{name}_confidence"] = a[:confidence].to_f.round(3)
          row["#{name}_probabilities"] = (a[:probabilities] || {}).sort_by { |_, v| -v }.first(3).map { |k, v| "#{k} #{(v * 100).round}%" }.join("; ")
        when "score"
          row["#{name}"] = a[:score].to_f.round(2)
          row["#{name}_confidence"] = a[:confidence].to_f.round(3)
        end
      end
      row
    end
  end
end

kind = ARGV[0]
path = ARGV[1]
out = "results.csv"
limit = nil
ARGV[2..].to_a.each do |arg|
  case arg
  when /\A--out=(.+)\z/ then out = Regexp.last_match(1)
  when /\A--limit=(\d+)\z/ then limit = Regexp.last_match(1).to_i
  else abort "unknown argument #{arg}"
  end
end
abort "usage: ruby jev_folder.rb inbox|trips <folder or csv> [--out=results.csv] [--limit=N]" unless %w[inbox trips].include?(kind) && path

items = load_items(kind, path)
items = items.first(limit) if limit
abort "nothing to read in #{path}" if items.empty?
questions = kind == "inbox" ? INBOX_QUESTIONS : TRIPS_QUESTIONS
context = kind == "inbox" ? Datasets::INBOX_QUESTION[:context] : Datasets::TRIPS_QUESTION[:context]
rows = ask(questions, items, context)
CSV.open(out, "w") do |csv|
  csv << rows.first.keys
  rows.each { |r| csv << r.values }
end
puts "#{rows.size} records -> #{out}"
