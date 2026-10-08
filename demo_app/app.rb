# frozen_string_literal: true

# Jev demo app for the workshop. One page per use case, the questions editable in the browser,
# the API key on the server. Participants paste their own text, change a word in a question, ask again.
#
#   cd demo_app && bundle install
#   export TYPESAFE_API_KEY=...
#   bundle exec ruby app.rb            -> http://localhost:4567
#
# Routes: /inbox and /trips (one record, every question), /inbox/batch and /trips/batch (20 records in one
# call, the triage table), POST /ask (JSON in, JSON out, the only route that calls Jev).

require "sinatra"
require "json"
require "csv"
require_relative "../lib/jev"
require_relative "../lib/datasets"
require_relative "../lib/metrics"

set :port, (ENV["PORT"] || 4567).to_i
set :bind, "0.0.0.0"
set :views, File.join(__dir__, "views")

BAND = { low: 0.35, high: 0.65 }.freeze

# The default questions, as in <dataset>/questions.txt. The page lets people edit them before asking.
QUESTIONS = {
  "inbox" => {
    "spam" => { "type" => "noul", "instructions" => "Is this message unsolicited?",
                "criteria" => { "true" => Datasets::INBOX_QUESTION[:criteria][:true], "false" => Datasets::INBOX_QUESTION[:criteria][:false] } },
    "category" => { "type" => "choice", "instructions" => "What is this message mainly about?",
                    "criteria" => { "membership" => "joining the space, prices, trial day, desk availability, leaving",
                                    "event" => "hosting or proposing an event, meetup, workshop, AV or room setup for an event",
                                    "room_booking" => "booking, changing or cancelling a meeting room or a desk for a day",
                                    "partnership" => "sponsoring, co-branding, press, a collaboration proposal from an organisation",
                                    "complaint" => "something is wrong: noise, wifi, access card, heating, cleaning, a bad experience",
                                    "billing" => "invoices, payments, receipts, VAT numbers, failed card",
                                    "newsletter" => "a subscribed newsletter or an automatic notification from a service in use",
                                    "spam" => "unsolicited commercial, fraudulent or irrelevant message",
                                    "other" => "anything else: thanks, lost and found, a question that fits no option" } },
    "urgency" => { "type" => "score", "instructions" => "How soon does this message need action?",
                   "criteria" => ["no action needed: a newsletter, a notification, a thank-you note, spam",
                                  "answer within the week: a general question, a proposal for next month, a request with no date",
                                  "answer within 24 hours: a request for this week, a booking change, a payment question",
                                  "answer today: something happening today or tomorrow, a person locked out, a safety issue, a payment failing right now"] },
    "needs_human" => { "type" => "noul", "instructions" => "Does this message need a reply written by a person?",
                       "criteria" => { "true" => "the sender asks something, requests something, or reports a problem, and expects a reply",
                                       "false" => "nothing to reply to: newsletters, notifications, automatic replies, spam, pure FYI" } }
  },
  "trips" => {
    "business" => { "type" => "noul", "instructions" => "Is this a business trip?",
                    "criteria" => { "true" => Datasets::TRIPS_QUESTION[:criteria][:true], "false" => Datasets::TRIPS_QUESTION[:criteria][:false] } }
  }
}.freeze

CONTEXT = { "inbox" => Datasets::INBOX_QUESTION[:context], "trips" => Datasets::TRIPS_QUESTION[:context] }.freeze

# Samples from the audited datasets: ok items only, a fixed random pick so the page is stable during the workshop.
def samples(kind, n)
  ds = Datasets.load(kind == "inbox" ? :inbox : :trips)
  ds.items.select { |i| i[:status] == "ok" }.shuffle(random: Random.new(42)).first(n)
end

def ask_jev(kind, records, questions)
  qs = {}
  records.each_with_index do |record, i|
    questions.each do |name, spec|
      qs["#{i}_#{name}"] = { type: spec["type"], instructions: { context: CONTEXT[kind], record: record, question: spec["instructions"] },
                             criteria: spec["criteria"] }
    end
  end
  answers, usage, ms = Jev.evaluate(state: {}, questions: qs)
  results = records.each_index.map do |i|
    questions.keys.to_h { |name| [name, answers[:"#{i}_#{name}"] || {}] }
  end
  { results: results, ms: ms, input_tokens: usage[:input_tokens].to_i, cost_usd: Jev.cost_usd(usage[:input_tokens].to_i).round(6) }
end

get "/" do
  redirect "/inbox"
end

# The benchmark page: dataset quality and the scorers side by side, read from benchmark/results on every load.
# Each load also rewrites benchmark/results/report.md and the SVG diagrams, so the files match the page.
get "/benchmark" do
  @kind = "benchmark"
  @quality = %w[inbox trips].to_h { |ds| [ds, Metrics.dataset_quality(ds)] }
  full_sizes = %w[inbox trips].to_h { |ds| [ds, Datasets.load(ds).items.size] }
  @summary = full_sizes.to_h { |ds, full| [ds, Metrics.dataset_summary(ds, full)] }
  Metrics.write_report(@summary, full_sizes)
  erb :benchmark
end

get "/:kind" do
  kind = params[:kind]
  halt 404 unless QUESTIONS.key?(kind)
  @kind = kind
  @questions = QUESTIONS[kind]
  @samples = samples(kind, 12)
  @band = BAND
  erb :single
end

get "/:kind/batch" do
  kind = params[:kind]
  halt 404 unless QUESTIONS.key?(kind)
  @kind = kind
  @questions = QUESTIONS[kind]
  @samples = samples(kind, 20)
  @band = BAND
  @result = nil
  @error = nil
  if params[:run]
    begin
      @result = ask_jev(kind, @samples.map { |s| s[:text] }, @questions)
    rescue Jev::Error => e
      @error = e.message
    end
  end
  erb :batch
end

post "/ask" do
  content_type :json
  body = JSON.parse(request.body.read)
  kind = body["kind"]
  halt 400, { error: "unknown kind" }.to_json unless QUESTIONS.key?(kind)
  questions = body["questions"].to_h.select { |_, q| %w[noul choice score].include?(q["type"]) }
  halt 400, { error: "no question" }.to_json if questions.empty?
  ask_jev(kind, [body["record"].to_s], questions).merge(band: BAND).to_json
rescue Jev::Error => e
  halt 502, { error: e.message }.to_json
rescue JSON::ParserError => e
  halt 400, { error: e.message }.to_json
end
