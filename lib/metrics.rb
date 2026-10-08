# frozen_string_literal: true

# Benchmark metrics, shared by benchmark/metrics.rb (writes report.md) and the demo app (/benchmark page).
# Reads benchmark/results/<dataset>-<scorer>-<timestamp>[-passN].csv. Ruby stdlib only.

require "csv"

module Metrics
  ROOT = File.expand_path("..", __dir__)
  RESULTS = File.join(ROOT, "benchmark", "results")
  BINS = 10

  SCORER_NAMES = {
    "jev" => "Jev 1.13 (TypeSafe)",
    "sonnet" => "Claude Sonnet 5.5",
    "claude_opus_5_5" => "Claude Opus 5.5",
    "claude_fable_5_1" => "Claude Fable 5.1",
    "claude_haiku_4_5" => "Claude Haiku 4.5",
    "laya" => "Laya multilingual (local, 322M)",
    "local" => "Qwen3-0.6B, 25 lines",
    "Qwen_Qwen3_4B" => "Qwen3-4B, 25 lines",
    "Qwen_Qwen3_1_7B" => "Qwen3-1.7B, 25 lines",
    "Qwen_Qwen3_8B" => "Qwen3-8B, 25 lines",
    "ollama_qwen3_4b" => "Qwen3-4B, asked for its confidence",
    "ollama_qwen3_0_6b" => "Qwen3-0.6B, asked for its confidence",
    "ollama_gemma4_26b" => "Gemma 4 26B, asked for its confidence",
    "ollama_qwen3_coder_30b" => "Qwen3-coder 30B, asked for its confidence"
  }.freeze
  SCORER_ORDER = %w[jev laya sonnet claude_opus_5_5 claude_fable_5_1 claude_haiku_4_5 ollama_gemma4_26b ollama_qwen3_coder_30b ollama_qwen3_4b
                    Qwen_Qwen3_8B Qwen_Qwen3_4B Qwen_Qwen3_1_7B ollama_qwen3_0_6b local].freeze

  def self.scorer_name(slug)
    SCORER_NAMES[slug] || slug.tr("_", " ")
  end

  def self.load_rows(path)
    CSV.read(path, headers: true).map do |r|
      { id: r["id"], label: r["label"] == "true", difficulty: r["difficulty"], p: r["p"].to_f, ms: r["ms"].to_i, cost: r["cost_usd"].to_f }
    end
  end

  # { ["inbox", "jev"] => { latest: path, passes: [paths] } }
  def self.runs
    out = Hash.new { |h, k| h[k] = { latest: nil, passes: [] } }
    Dir[File.join(RESULTS, "*.csv")].sort.each do |f|
      base = File.basename(f, ".csv")
      next unless base =~ /\A(inbox|trips)-([A-Za-z0-9_]+)-(\d{8}-\d{6})(?:-pass(\d+))?\z/

      key = [Regexp.last_match(1), Regexp.last_match(2)]
      if Regexp.last_match(4)
        out[key][:passes] << f
      else
        out[key][:latest] = f
      end
    end
    out.each_value { |v| v[:latest] ||= v[:passes].last }
    out
  end

  def self.compute(rows)
    n = rows.size.to_f
    return nil if n.zero?

    dec = rows.map { |r| r[:p] >= 0.5 }
    tp = rows.each_with_index.count { |r, i| dec[i] && r[:label] }
    fp = rows.each_with_index.count { |r, i| dec[i] && !r[:label] }
    fn = rows.each_with_index.count { |r, i| !dec[i] && r[:label] }
    precision = tp.zero? ? 0 : tp.to_f / (tp + fp)
    recall = tp.zero? ? 0 : tp.to_f / (tp + fn)
    f1 = (precision + recall).zero? ? 0 : 2 * precision * recall / (precision + recall)
    brier = rows.sum { |r| (r[:p] - (r[:label] ? 1 : 0))**2 } / n
    bins = Array.new(BINS) { [] }
    rows.each { |r| bins[[(r[:p] * BINS).floor, BINS - 1].min] << r }
    ece = bins.sum { |b| b.empty? ? 0 : (b.size / n) * (b.sum { |r| r[:p] } / b.size - b.count { |r| r[:label] }.to_f / b.size).abs }
    zone = rows.select { |r| r[:p].between?(0.4, 0.6) }
    zone_acc = zone.empty? ? nil : zone.count { |r| (r[:p] >= 0.5) == r[:label] }.to_f / zone.size
    per_diff = %w[easy medium hard].to_h do |d|
      sub = rows.select { |r| r[:difficulty] == d }
      [d, sub.empty? ? nil : sub.count { |r| (r[:p] >= 0.5) == r[:label] }.to_f / sub.size]
    end
    lat = rows.map { |r| r[:ms] }.sort
    { n: rows.size, accuracy: rows.each_with_index.count { |r, i| dec[i] == r[:label] } / n, f1: f1, brier: brier, ece: ece,
      zone_share: zone.size / n, zone_acc: zone_acc, per_diff: per_diff, bins: bins,
      median_ms: lat[lat.size / 2], p95_ms: lat[(lat.size * 0.95).floor.clamp(0, lat.size - 1)], cost: rows.sum { |r| r[:cost] } }
  end

  def self.stability(paths)
    runs = paths.map { |f| load_rows(f).to_h { |r| [r[:id], r] } }
    ids = runs.map(&:keys).reduce(:&)
    return nil if runs.size < 2 || ids.empty?

    sds = ids.map { |id| ps = runs.map { |r| r[id][:p] }; mean = ps.sum / ps.size; Math.sqrt(ps.sum { |p| (p - mean)**2 } / ps.size) }
    flips = ids.count { |id| runs.map { |r| r[id][:p] >= 0.5 }.uniq.size > 1 }
    { passes: runs.size, items: ids.size, mean_sd: sds.sum / sds.size, flips: flips }
  end

  def self.pct(x)
    x.nil? ? "n/a" : format("%.1f%%", x * 100)
  end

  # Two panels. Top: for the items the scorer put in each bracket of stated probability, how often they really
  # were positive; the diagonal is perfect calibration, the 40 to 60 band is where a human review would sit.
  # Bottom: how many items landed in each bracket, split into right (grey) and wrong (red) decisions at 0.5.
  # A calibrated scorer has its red in the middle, where it said it was unsure; an overconfident one at the edges.
  def self.reliability_svg(m, title, positive: "positive")
    w = 440
    pad_l = 52
    pad_r = 16
    top_y = 48
    top_h = 200
    gap = 36
    bot_h = 90
    h = top_y + top_h + gap + bot_h + 40
    plot_w = w - pad_l - pad_r
    bw = plot_w / BINS.to_f
    bot_y = top_y + top_h + gap
    max_n = [m[:bins].map(&:size).max, 1].max
    o = ["<svg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 #{w} #{h}' width='#{w}' height='#{h}' font-family='sans-serif' font-size='11'>"]
    o << "<rect width='#{w}' height='#{h}' fill='white'/>"
    o << "<text x='#{pad_l}' y='16' font-size='13' font-weight='600'>#{title}</text>"
    o << "<text x='#{pad_l}' y='31' font-size='10' fill='#555'>ECE #{format('%.3f', m[:ece])}, accuracy #{pct(m[:accuracy])}, #{m[:n]} items. Dashed line: perfect calibration.</text>"
    # top panel: band, grid, diagonal
    o << "<rect x='#{pad_l + 0.4 * plot_w}' y='#{top_y}' width='#{0.2 * plot_w}' height='#{top_h}' fill='#f3e8c8' opacity='0.6'/>"
    o << "<text x='#{pad_l + 0.5 * plot_w}' y='#{top_y + 12}' text-anchor='middle' font-size='9' fill='#8a6d1f'>human review band</text>"
    [0.25, 0.5, 0.75, 1.0].each do |g|
      y = top_y + top_h - g * top_h
      o << "<line x1='#{pad_l}' y1='#{y}' x2='#{w - pad_r}' y2='#{y}' stroke='#e5e7eb'/>"
      o << "<text x='#{pad_l - 6}' y='#{y + 4}' text-anchor='end' fill='#555'>#{(g * 100).round}%</text>"
    end
    o << "<text x='#{pad_l - 6}' y='#{top_y + top_h + 4}' text-anchor='end' fill='#555'>0%</text>"
    o << "<line x1='#{pad_l}' y1='#{top_y + top_h}' x2='#{w - pad_r}' y2='#{top_y}' stroke='#999' stroke-dasharray='5 4'/>"
    m[:bins].each_with_index do |b, i|
      x = pad_l + i * bw
      if b.empty?
        o << "<text x='#{x + bw / 2}' y='#{top_y + top_h - 4}' text-anchor='middle' font-size='9' fill='#bbb'>no item</text>"
        next
      end
      freq = b.count { |r| r[:label] }.to_f / b.size
      mean_p = b.sum { |r| r[:p] } / b.size
      y = top_y + top_h - freq * top_h
      o << "<rect x='#{x + 2}' y='#{y}' width='#{bw - 4}' height='#{top_y + top_h - y}' fill='#4a7fb5' opacity='0.85'>" \
           "<title>says #{(mean_p * 100).round}% on average, #{positive} in #{(freq * 100).round}% of cases, #{b.size} items</title></rect>"
      o << "<text x='#{x + bw / 2}' y='#{[y - 4, top_y + 10].max}' text-anchor='middle' font-size='10' font-weight='600' fill='#1f2430'>#{(freq * 100).round}%</text>"
    end
    o << "<line x1='#{pad_l}' y1='#{top_y + top_h}' x2='#{w - pad_r}' y2='#{top_y + top_h}' stroke='#333'/>"
    o << "<line x1='#{pad_l}' y1='#{top_y}' x2='#{pad_l}' y2='#{top_y + top_h}' stroke='#333'/>"
    o << "<text x='#{pad_l - 40}' y='#{top_y + top_h / 2}' text-anchor='middle' font-size='10' fill='#333' transform='rotate(-90 #{pad_l - 40} #{top_y + top_h / 2})'>how often it really was #{positive}</text>"
    # x ticks shared
    (0..BINS).each do |i|
      x = pad_l + i * bw
      o << "<text x='#{x}' y='#{top_y + top_h + 13}' text-anchor='middle' font-size='9' fill='#555'>#{i * 10}%</text>"
    end
    o << "<text x='#{pad_l + plot_w / 2}' y='#{top_y + top_h + 26}' text-anchor='middle' font-size='10' fill='#333'>what the scorer said: probability of #{positive}, by bracket of 10 points</text>"
    # bottom panel: counts, right in grey, wrong in red
    o << "<text x='#{pad_l - 40}' y='#{bot_y + bot_h / 2}' text-anchor='middle' font-size='10' fill='#333' transform='rotate(-90 #{pad_l - 40} #{bot_y + bot_h / 2})'>items</text>"
    total_wrong = 0
    m[:bins].each_with_index do |b, i|
      x = pad_l + i * bw
      wrong = b.count { |r| (r[:p] >= 0.5) != r[:label] }
      total_wrong += wrong
      hh = b.size.to_f / max_n * bot_h
      hw = wrong.to_f / max_n * bot_h
      o << "<rect x='#{x + 2}' y='#{bot_y + bot_h - hh}' width='#{bw - 4}' height='#{hh - hw}' fill='#9aa5b1'><title>#{b.size} items, #{b.size - wrong} right</title></rect>"
      o << "<rect x='#{x + 2}' y='#{bot_y + bot_h - hw}' width='#{bw - 4}' height='#{hw}' fill='#d9534f'><title>#{wrong} wrong</title></rect>" if wrong.positive?
      label = wrong.positive? ? "#{b.size} <tspan fill='#c53030'>(#{wrong})</tspan>" : b.size.to_s
      o << "<text x='#{x + bw / 2}' y='#{bot_y + bot_h - hh - 3}' text-anchor='middle' font-size='10' fill='#1f2430'>#{label}</text>"
    end
    o << "<line x1='#{pad_l}' y1='#{bot_y + bot_h}' x2='#{w - pad_r}' y2='#{bot_y + bot_h}' stroke='#333'/>"
    o << "<text x='#{pad_l + plot_w / 2}' y='#{bot_y + bot_h + 14}' text-anchor='middle' font-size='10' fill='#333'>how many items the scorer placed in each bracket, <tspan fill='#c53030'>in red the wrong decisions</tspan> (#{total_wrong} in all)</text>"
    o << "</svg>"
    o.join("\n")
  end

  # Total wall time of a run, from the "total:" line of its .log (nil for runs made before the logs existed).
  def self.elapsed_seconds(csv_path)
    log = csv_path.sub(/\.csv\z/, ".log")
    return nil unless File.exist?(log)

    line = File.readlines(log).reverse.find { |l| l.start_with?("total:") }
    line && line[/\((\d+) s\)/, 1]&.to_i
  end

  # Everything a page or a report needs for one dataset: scorers sorted, full runs first, partial runs flagged.
  def self.dataset_summary(dataset, full_size)
    rows = runs.select { |(d, _), _| d == dataset }.map do |(_, slug), r|
      m = compute(load_rows(r[:latest]))
      { slug: slug, name: scorer_name(slug), metrics: m, partial: m[:n] < full_size, file: File.basename(r[:latest]),
        elapsed: elapsed_seconds(r[:latest]), stability: r[:passes].size > 1 ? stability(r[:passes]) : nil }
    end
    rows.sort_by { |r| [r[:partial] ? 1 : 0, SCORER_ORDER.index(r[:slug]) || 99] }
  end

  READING = "Reading: ECE is the gap between stated probability and observed frequency, averaged over 10 bins (0 is perfect). Brier is the mean squared error of the probability. The 0.40-0.60 zone is where a human-review band would sit: a calibrated scorer should be near 50% accurate there, an overconfident one is rarely there at all. A partial run covers fewer items than the dataset: a setup check, not a result."

  # Writes results/report.md and one SVG reliability diagram per run (named like its CSV), from the summaries the
  # /benchmark page shows. Called by the page on every load and by benchmark/metrics.rb, so the files on disk
  # never lag behind the page. summaries: { "inbox" => rows of dataset_summary }, full_sizes: { "inbox" => 325 }.
  # Returns the markdown.
  def self.write_report(summaries, full_sizes)
    lines = ["# Benchmark report", "", "Generated #{Time.now.strftime('%Y-%m-%d %H:%M')}. Same prompt for every scorer (lib/datasets.rb). Decision threshold 0.5.", ""]
    summaries.each do |ds, rows|
      next if rows.empty?

      lines << "## #{ds} (#{full_sizes[ds]} items)"
      lines << ""
      lines << "| Scorer | items | accuracy | F1 | Brier | ECE | in 0.40-0.60 | acc. in zone | easy | medium | hard | median ms | p95 ms | total time | cost USD |"
      lines << "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"
      rows.each do |r|
        m = r[:metrics]
        name = r[:partial] ? "#{r[:name]} (partial run)" : r[:name]
        lines << "| #{name} | #{m[:n]} | #{pct(m[:accuracy])} | #{format('%.3f', m[:f1])} | #{format('%.3f', m[:brier])} | #{format('%.3f', m[:ece])} | #{pct(m[:zone_share])} | #{pct(m[:zone_acc])} | #{pct(m[:per_diff]['easy'])} | #{pct(m[:per_diff]['medium'])} | #{pct(m[:per_diff]['hard'])} | #{m[:median_ms]} | #{m[:p95_ms]} | #{r[:elapsed] ? format('%dm%02ds', r[:elapsed] / 60, r[:elapsed] % 60) : 'n/a'} | #{format('%.4f', m[:cost])} |"
        File.write(File.join(RESULTS, r[:file].sub(/\.csv\z/, ".svg")), reliability_svg(m, "#{ds} / #{r[:name]}", positive: ds == "inbox" ? "spam" : "business"))
      end
      lines << ""
      rows.select { |r| r[:stability] }.each do |r|
        s = r[:stability]
        lines << "Stability, #{r[:name]}, #{s[:passes]} passes on #{s[:items]} items: mean SD of p #{format('%.4f', s[:mean_sd])}, decision flipped on #{s[:flips]} items (#{pct(s[:flips].to_f / s[:items])})."
      end
      lines << ""
    end
    lines << READING
    markdown = lines.join("\n") + "\n"
    File.write(File.join(RESULTS, "report.md"), markdown)
    markdown
  end

  # Dataset quality from labels.csv and data/audits: counts per cell and disagreement per auditor and difficulty.
  def self.dataset_quality(dataset)
    dir = File.join(ROOT, dataset == "inbox" ? "inbox_triage" : "trips_business_or_personal", "data")
    table = CSV.read(File.join(dir, "labels.csv"), headers: true)
    field = dataset == "inbox" ? "spam" : "business"
    audits = Dir[File.join(dir, "audits", "*.csv")].sort.each_with_object({}) do |path, h|
      name = File.basename(path, ".csv").sub(/\A\d{8}-\d{6}-/, "")
      h[name] ||= {}
      CSV.read(path, headers: true).each { |r| h[name][r["id"]] = r }
    end
    auditors = audits.map do |name, by_id|
      rows = table.select { |r| by_id[r["id"]] }
      per = %w[easy medium hard].to_h do |d|
        sub = rows.select { |r| r["difficulty"] == d }
        [d, sub.empty? ? nil : sub.count { |r| by_id[r["id"]]["audit_label"].to_s != r[field].to_s }.to_f / sub.size]
      end
      confs = rows.map { |r| by_id[r["id"]]["confidence"].to_f }
      { name: name, items: rows.size, disagree: per, mean_confidence: confs.empty? ? nil : confs.sum / confs.size }
    end
    cells = [true, false].map do |pos|
      counts = %w[easy medium hard].map { |d| table.count { |r| r[field] == pos.to_s && r["difficulty"] == d && !%w[reject dropped].include?(r["status"]) } }
      { label: pos ? (dataset == "inbox" ? "spam" : "business") : (dataset == "inbox" ? "not spam" : "personal"), counts: counts }
    end
    { rows: table.size, cells: cells, status: table.group_by { |r| r["status"] }.transform_values(&:size),
      languages: table.group_by { |r| r["language"] }.transform_values(&:size), auditors: auditors,
      usable: table.count { |r| !%w[reject dropped].include?(r["status"]) } }
  end
end
