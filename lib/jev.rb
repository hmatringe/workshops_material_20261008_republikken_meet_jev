# frozen_string_literal: true

# Jev (TypeSafe AI) client. Ruby stdlib only. The only place that talks to the engine.
# Ported from an earlier production client: short timeouts, no retry, pinned model.
#
#   answers, usage, ms = Jev.evaluate(state: { ... }, questions: { key => question })
#
# Question shapes (docs.typesafe.ai, read 2026-10-07):
#   noul   { type: "noul",   instructions: "...", criteria: { true: "...", false: "..." } }   -> { noul: 0.91 }
#   choice { type: "choice", instructions: "...", criteria: { option => description } }       -> { choice:, confidence:, probabilities: }
#   score  { type: "score",  instructions: "...", criteria: ["level 1", "level 2", ...] }      -> { score:, confidence:, legend:, probabilities: }
# instructions may be a string, an object or an array; the item under judgment usually goes there.

require "net/http"
require "json"
require "uri"

module Jev
  ENDPOINT = URI("https://api.typesafe.ai/v1/systemone")
  MODEL = "jev-1.13.0"
  PRICE_PER_MILLION_INPUT_TOKENS_USD = 0.042
  OPEN_TIMEOUT = 2
  READ_TIMEOUT = 15

  class Error < StandardError; end

  def self.api_key
    key = ENV["TYPESAFE_API_KEY"]
    raise Error, "TYPESAFE_API_KEY is not set" if key.nil? || key.empty?

    key
  end

  # Returns [answers, usage, milliseconds]. Raises Jev::Error on any failure, never retries.
  def self.evaluate(state:, questions:, model: MODEL)
    req = Net::HTTP::Post.new(ENDPOINT, "Authorization" => "Bearer #{api_key}", "Content-Type" => "application/json")
    req.body = { model:, state:, questions: }.to_json
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    res = Net::HTTP.start(ENDPOINT.host, ENDPOINT.port, use_ssl: true, open_timeout: OPEN_TIMEOUT, read_timeout: READ_TIMEOUT) { |http| http.request(req) }
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    raise Error, "TypeSafe #{res.code}: #{res.body.to_s[0, 300]}" unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body, symbolize_names: true)
    raise Error, "unexpected body" unless body[:answers].is_a?(Hash)

    [body[:answers], body[:usage] || {}, ms]
  rescue Timeout::Error, SocketError, SystemCallError, OpenSSL::SSL::SSLError, Net::HTTPBadResponse, EOFError, JSON::ParserError => e
    raise Error, "#{e.class}: #{e.message}"
  end

  def self.cost_usd(input_tokens)
    input_tokens.to_f / 1_000_000 * PRICE_PER_MILLION_INPUT_TOKENS_USD
  end
end
