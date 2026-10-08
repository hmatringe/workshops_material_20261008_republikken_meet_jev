# frozen_string_literal: true

# The two datasets as the scorers see them, plus the one binary question each scorer answers.
# The wording here is the single source for every scorer, so the prompt is identical across models.
#
#   ds = Datasets.load(:inbox)   # or :trips
#   ds.items  -> [{ id:, text:, label: true/false, difficulty:, status: }]   (status reject excluded)
#   ds.question -> { field:, instructions:, criteria: { true: "...", false: "..." }, options: ["spam", "not spam"] }

require "csv"
require "date"

module Datasets
  ROOT = File.expand_path("..", __dir__)

  Dataset = Struct.new(:name, :items, :question, keyword_init: true)

  INBOX_QUESTION = {
    field: "spam",
    instructions: "Is this message unsolicited?",
    criteria: {
      true: "The recipient never asked for this message and has no relationship with the sender: cold sales outreach, mass marketing without a subscription, phishing, scams, fake invoices, SEO or link-building offers, recruitment blasts.",
      false: "The message comes from an existing relationship or from something the recipient signed up for: members, visitors asking about the space, partners, suppliers, newsletters the recipient subscribed to, notifications from services in use, automatic replies. A newsletter the recipient subscribed to is not unsolicited, even when it is pure marketing."
    },
    options: ["unsolicited", "not unsolicited"],
    context: "The recipient is the shared inbox of a coworking and community space in Copenhagen."
  }.freeze

  TRIPS_QUESTION = {
    field: "business",
    instructions: "Is this a business trip?",
    criteria: {
      true: "The main purpose of the trip is work: meeting a client, a prospect, a supplier or a partner; moving between two work sites; a conference, trade fair or training attended for work; a site or store visit; driving to or from the airport or station for a work trip; picking up a visiting client; a business meal; an errand done for the company; a rental car between a hotel and a client abroad. Evenings and weekends do not matter: a client dinner on a Saturday is business.",
      false: "The main purpose is private: home, family, school, groceries, doctor, sport, friends, holidays, restaurants, shopping, a partner's workplace. Commuting between home and the usual workplace is personal. A trip whose main purpose is private stays personal even if it passes by the office."
    },
    options: ["business", "personal"],
    context: "The driver works in Copenhagen for a small company. The record comes from a mileage-tracking app. Weekday and working hours are given."
  }.freeze

  def self.load(name)
    case name.to_sym
    when :inbox then load_inbox
    when :trips then load_trips
    else raise ArgumentError, "unknown dataset #{name}"
    end
  end

  def self.load_inbox
    dir = File.join(ROOT, "inbox_triage", "data")
    items = CSV.read(File.join(dir, "labels.csv"), headers: true).reject { |r| %w[reject dropped].include?(r["status"]) }.map do |r|
      { id: r["id"], text: File.read(File.join(dir, "mails", "#{r['id']}.txt")).strip, label: r["spam"] == "true",
        difficulty: r["difficulty"], status: r["status"] }
    end
    Dataset.new(name: "inbox", items: items, question: INBOX_QUESTION)
  end

  def self.load_trips
    dir = File.join(ROOT, "trips_business_or_personal", "data")
    trips = CSV.read(File.join(dir, "trips.csv"), headers: true).to_h { |r| [r["id"], r] }
    items = CSV.read(File.join(dir, "labels.csv"), headers: true).reject { |r| %w[reject dropped].include?(r["status"]) }.map do |r|
      { id: r["id"], text: trip_text(trips.fetch(r["id"])), label: r["business"] == "true",
        difficulty: r["difficulty"], status: r["status"] }
    end
    Dataset.new(name: "trips", items: items, question: TRIPS_QUESTION)
  end

  # Weekday and working hours computed in code, as the demo does: dates and arithmetic stay out of the model.
  def self.trip_text(t)
    date = Date.parse(t["date"])
    hour = t["start_time"].to_s.split(":").first.to_i
    working = (1..5).cover?(date.wday) && (8..18).cover?(hour)
    <<~TXT.strip
      date: #{t['date']} (#{date.strftime('%A')})
      start time: #{t['start_time']} (#{working ? 'within' : 'outside'} working hours)
      duration: #{t['duration_min']} min
      distance: #{t['distance_km']} km
      from: #{t['start_address']}
      to: #{t['end_address']}
      note: #{t['note'].to_s.empty? ? '(none)' : t['note']}
    TXT
  end

  # The same words for every scorer: context, definitions, the item, the question.
  def self.prompt(dataset, item)
    q = dataset.question
    <<~TXT
      #{q[:context]}

      Question: #{q[:instructions]}
      "#{q[:options][0]}" means: #{q[:criteria][:true]}
      "#{q[:options][1]}" means: #{q[:criteria][:false]}

      Record:
      ---
      #{item[:text]}
      ---
    TXT
  end
end
