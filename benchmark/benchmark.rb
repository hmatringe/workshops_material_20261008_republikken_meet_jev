#!/usr/bin/env ruby
# frozen_string_literal: true

# Scores a dataset with one scorer, same prompt for all. Writes results/<dataset>-<scorer>-<timestamp>.csv.
#
#   ruby benchmark.rb --dataset=inbox --scorer=jev               TYPESAFE_API_KEY in the environment
#   ruby benchmark.rb --dataset=trips --scorer=sonnet            ANTHROPIC_API_KEY (and ANTHROPIC_WORKSPACE_ID) in the environment
#   ruby benchmark.rb --dataset=inbox --scorer=local             no key: uv run local_25_lines.py (Qwen3-0.6B, downloads once)
#   ruby benchmark.rb --dataset=inbox --scorer=ollama --model=qwen3:4b   same local model, generated JSON answer + self-reported confidence
#   ruby benchmark.rb --dataset=inbox --scorer=laya              no key: Laya multilingual, local, Jev's request shape (uv run laya_scorer.py --warmup first)
#   --limit=30        first 30 items, to check the setup
#   --passes=5        score the same items 5 times (stability test): one results file per pass
#   --model=...       override the model (sonnet scorer: claude-opus-5-5 for instance)
#
# One row per item: id, label, p (probability of the positive class), decision at 0.5, ms, input_tokens, cost_usd.
# Then: ruby metrics.rb
# Dependencies: Ruby stdlib. The local scorer needs uv.

require "csv"
require "json"
require "net/http"
require "open3"
require "fileutils"
require_relative "../lib/jev"
require_relative "../lib/datasets"

RESULTS = File.join(__dir__, "results")
ANTHROPIC = URI("https://api.anthropic.com/v1/messages")
JEV_BATCH = 10

# ---------------------------------------------------------------------------------------------------
# Jev: one noul per item, JEV_BATCH items per call, the item in the question's instructions, as in production use.
# Latency per item = call latency / items in the call. Cost from input tokens.
# ---------------------------------------------------------------------------------------------------
def score_jev(dataset, items, model)
  q = dataset.question
  results = []
  items.each_slice(JEV_BATCH) do |slice|
    questions = slice.each_with_index.to_h do |item, i|
      ["i#{i}", { type: "noul", instructions: { context: q[:context], record: item[:text], question: q[:instructions] },
                  criteria: { true: q[:criteria][:true], false: q[:criteria][:false] } }]
    end
    answers, usage, ms = Jev.evaluate(state: {}, questions: questions, model: model || Jev::MODEL)
    tokens = usage[:input_tokens].to_i
    slice.each_with_index do |item, i|
      p = answers.dig(:"i#{i}", :noul)
      results << row(item, p, ms.to_f / slice.size, tokens.to_f / slice.size, Jev.cost_usd(tokens) / slice.size)
      yield results.last if block_given?
    end
  end
  results
end

# ---------------------------------------------------------------------------------------------------
# Claude: one call per item, JSON answer with a self-reported confidence. p = confidence if positive else 1 - confidence.
# Low effort, max 300 tokens: it is a classification. Prices per million tokens as of 2026-10 (input / output).
# ---------------------------------------------------------------------------------------------------
CLAUDE_PRICES = { "claude-sonnet-5-5" => [2.0, 10.0], "claude-opus-5-5" => [4.0, 20.0], "claude-haiku-4-5" => [1.0, 5.0], "claude-fable-5-1" => [10.0, 50.0] }.freeze

def score_claude(dataset, items, model)
  key = ENV["ANTHROPIC_API_KEY"]
  abort "ANTHROPIC_API_KEY is not set" if key.nil? || key.empty?
  model ||= "claude-sonnet-5-5"
  q = dataset.question
  items.map do |item|
    prompt = Datasets.prompt(dataset, item) +
             "\nAnswer with a JSON object only: {\"answer\": \"#{q[:options][0]}\" or \"#{q[:options][1]}\", \"confidence\": <0.5 to 1.0, how sure you are about your answer>}"
    req = Net::HTTP::Post.new(ANTHROPIC)
    req["x-api-key"] = key
    req["anthropic-version"] = "2023-06-01"
    req["anthropic-beta"] = "server-side-fallback-2026-07-01"
    req["content-type"] = "application/json"
    req["anthropic-workspace-id"] = ENV["ANTHROPIC_WORKSPACE_ID"] if ENV["ANTHROPIC_WORKSPACE_ID"].to_s != ""
    req.body = { model:, max_tokens: 300, fallbacks: "default", output_config: { effort: "low" },
                 messages: [{ role: "user", content: prompt }] }.to_json
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    res = Net::HTTP.start(ANTHROPIC.host, ANTHROPIC.port, use_ssl: true, read_timeout: 120) { |http| http.request(req) }
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    abort "Anthropic #{res.code}: #{res.body[0, 300]}" unless res.is_a?(Net::HTTPSuccess)

    body = JSON.parse(res.body)
    text = body["content"].select { |b| b["type"] == "text" }.map { |b| b["text"] }.join
    verdict = JSON.parse(text[text.index("{")..text.rindex("}")]) rescue { "answer" => nil, "confidence" => 0.5 }
    positive = verdict["answer"].to_s.strip.downcase == q[:options][0]
    conf = verdict["confidence"].to_f.clamp(0.5, 1.0)
    p = positive ? conf : 1 - conf
    inp = body.dig("usage", "input_tokens").to_i
    out = body.dig("usage", "output_tokens").to_i
    prices = CLAUDE_PRICES[model] || [0, 0]
    cost = inp / 1e6 * prices[0] + out / 1e6 * prices[1]
    r = row(item, p, ms, inp, cost)
    yield r if block_given?
    r
  end
end

# ---------------------------------------------------------------------------------------------------
# Ollama: the same question to a local model, but generated: a JSON answer with a self-reported confidence,
# exactly as the Sonnet scorer. Same weights as "25 lines" when the model matches (qwen3:4b vs Qwen/Qwen3-4B):
# the comparison between reading the logits and asking the model how sure it is.
# ---------------------------------------------------------------------------------------------------
OLLAMA = URI("http://localhost:11434/api/chat")

def score_ollama(dataset, items, model)
  model ||= "qwen3:4b"
  q = dataset.question
  items.map do |item|
    prompt = Datasets.prompt(dataset, item) +
             "\nAnswer with a JSON object only: {\"answer\": \"#{q[:options][0]}\" or \"#{q[:options][1]}\", \"confidence\": <0.5 to 1.0, how sure you are about your answer>}"
    req = Net::HTTP::Post.new(OLLAMA)
    req["content-type"] = "application/json"
    req.body = { model:, stream: false, format: "json", keep_alive: "30m", think: false,
                 options: { temperature: 0, num_predict: 200 }, messages: [{ role: "user", content: prompt }] }.to_json
    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    res = Net::HTTP.start(OLLAMA.host, OLLAMA.port, read_timeout: 120) { |http| http.request(req) }
    ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0) * 1000).round
    abort "Ollama #{res.code}: #{res.body[0, 300]}" unless res.is_a?(Net::HTTPSuccess)

    text = JSON.parse(res.body).dig("message", "content").to_s
    verdict = JSON.parse(text[text.index("{")..text.rindex("}")]) rescue { "answer" => nil, "confidence" => 0.5 }
    positive = verdict["answer"].to_s.strip.downcase == q[:options][0]
    conf = verdict["confidence"].to_f.clamp(0.5, 1.0)
    r = row(item, positive ? conf : 1 - conf, ms, 0, 0)
    yield r if block_given?
    r
  end
end

# ---------------------------------------------------------------------------------------------------
# Laya: a local open-weights decision engine with Jev's request shape. Same noul question as the Jev
# scorer, answered by laya_scorer.py through uv (no key). p = the noul.
# ---------------------------------------------------------------------------------------------------
def score_laya(dataset, items, _model)
  q = dataset.question
  input = items.map do |i|
    { id: i[:id], state: { context: q[:context], record: i[:text] },
      question: { type: "noul", instructions: q[:instructions], criteria: { true: q[:criteria][:true], false: q[:criteria][:false] } } }.to_json
  end.join("\n") + "\n"
  out, err, status = Open3.capture3("uv", "run", File.join(__dir__, "laya_scorer.py"), stdin_data: input)
  abort "laya scorer failed:\n#{err[-2000..] || err}" unless status.success?

  scores = out.lines.map { |l| JSON.parse(l) }.to_h { |s| [s["id"], s] }
  items.map do |item|
    s = scores[item[:id]] or abort "no score for #{item[:id]}"
    r = row(item, s["p"], s["ms"], 0, 0)
    yield r if block_given?
    r
  end
end

# ---------------------------------------------------------------------------------------------------
# Local 25 lines: the Python script scores a JSONL of prompts. p = probability of option A.
# ---------------------------------------------------------------------------------------------------
# --model=Qwen/Qwen3-4B picks another Hugging Face repo (LOCAL_MODEL for the Python script).
def score_local(dataset, items, model)
  input = items.map { |i| { id: i[:id], prompt: Datasets.prompt(dataset, i), options: dataset.question[:options] }.to_json }.join("\n") + "\n"
  env = model ? { "LOCAL_MODEL" => model } : {}
  out, err, status = Open3.capture3(env, "uv", "run", File.join(__dir__, "local_25_lines.py"), stdin_data: input)
  abort "local scorer failed:\n#{err[-2000..] || err}" unless status.success?

  scores = out.lines.map { |l| JSON.parse(l) }.to_h { |s| [s["id"], s] }
  items.map do |item|
    s = scores[item[:id]] or abort "no score for #{item[:id]}"
    r = row(item, s["p_a"], s["ms"], 0, 0)
    yield r if block_given?
    r
  end
end

def row(item, p, ms, tokens, cost)
  { id: item[:id], label: item[:label], difficulty: item[:difficulty], p: p.nil? ? nil : p.to_f.round(4),
    decision: p.nil? ? nil : p.to_f >= 0.5, ms: ms.round, input_tokens: tokens.round, cost_usd: cost.round(7) }
end

dataset_name = "inbox"
scorer = nil
limit = nil
passes = 1
model = nil
ARGV.each do |arg|
  case arg
  when /\A--dataset=(inbox|trips)\z/ then dataset_name = Regexp.last_match(1)
  when /\A--scorer=(jev|sonnet|claude|local|ollama|laya)\z/ then scorer = Regexp.last_match(1)
  when /\A--limit=(\d+)\z/ then limit = Regexp.last_match(1).to_i
  when /\A--passes=(\d+)\z/ then passes = Regexp.last_match(1).to_i
  when /\A--model=(.+)\z/ then model = Regexp.last_match(1)
  else abort "unknown argument #{arg}"
  end
end
abort "usage: ruby benchmark.rb --dataset=inbox|trips --scorer=jev|sonnet|local|ollama|laya [--limit=N] [--passes=N] [--model=...]" unless scorer

FileUtils.mkdir_p(RESULTS)
$stdout.sync = true
dataset = Datasets.load(dataset_name)
items = dataset.items
items = items.first(limit) if limit
scorer_name = scorer == "claude" ? "sonnet" : scorer
scorer_label = model ? "#{scorer == 'ollama' ? 'ollama_' : ''}#{model.gsub(/[^a-z0-9]+/i, '_')}" : (scorer == "ollama" ? "ollama_qwen3_4b" : scorer_name)
puts "#{dataset_name}: #{items.size} items, scorer #{scorer_label}, #{passes} pass(es)"

passes.times do |pass|
  started = Time.now
  path = File.join(RESULTS, "#{dataset_name}-#{scorer_label}-#{started.strftime('%Y%m%d-%H%M%S')}#{passes > 1 ? "-pass#{pass + 1}" : ''}.csv")
  # Everything printed during the run also goes to results/<same name>.log, with a final total line.
  log = File.open(path.sub(/\.csv\z/, ".log"), "w")
  say = lambda { |line| puts line; log.puts line; log.flush }
  say.call "#{dataset_name}: #{items.size} items, scorer #{scorer_label}, model #{model || 'default'}, started #{started.strftime('%Y-%m-%d %H:%M:%S')}"
  n = 0
  rows = []
  CSV.open(path, "w") do |csv|
    csv << %w[id label difficulty p decision ms input_tokens cost_usd]
    report = lambda do |r|
      n += 1
      csv << r.values_at(:id, :label, :difficulty, :p, :decision, :ms, :input_tokens, :cost_usd)
      csv.flush
      ok = r[:decision] == r[:label]
      elapsed = (Time.now - started).round
      say.call format("%3d / %d  %s  label=%-5s p=%.2f %s  %dms  elapsed %dm%02ds", n, items.size, r[:id], r[:label], r[:p].to_f, ok ? "ok  " : "MISS", r[:ms], elapsed / 60, elapsed % 60)
    end
    rows = case scorer
           when "jev" then score_jev(dataset, items, model, &report)
           when "sonnet", "claude" then score_claude(dataset, items, model, &report)
           when "local" then score_local(dataset, items, model, &report)
           when "ollama" then score_ollama(dataset, items, model, &report)
           when "laya" then score_laya(dataset, items, model, &report)
           end
  end
  acc = rows.count { |r| r[:decision] == r[:label] }.to_f / rows.size
  elapsed = (Time.now - started).round
  say.call format("pass %d: accuracy %.1f%%, total cost $%.4f, median %dms -> %s", pass + 1, acc * 100, rows.sum { |r| r[:cost_usd] }, rows.map { |r| r[:ms] }.sort[rows.size / 2], File.basename(path))
  say.call format("total: %d items in %dm%02ds (%d s), accuracy %.1f%%, cost $%.4f", rows.size, elapsed / 60, elapsed % 60, elapsed, acc * 100, rows.sum { |r| r[:cost_usd] })
  log.close
end
