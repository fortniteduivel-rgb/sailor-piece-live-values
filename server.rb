#!/usr/bin/env ruby

require "json"
require "open-uri"
require "set"
require "time"
require "webrick"

ROOT = File.expand_path(__dir__)
PORT = Integer(ARGV[0] || ENV.fetch("PORT", "4173"))
BIND_ADDRESS = ENV.fetch("BIND_ADDRESS", "0.0.0.0")
TRADE_ADS_URL = "https://sailor-piece.vaultedvaluesx.com/api/trade-ads"
VALUE_LIST_URL = "https://valuevaultx.com/_functions/api/sailor-piece"
SAILOR_PIECE_GAME_ID = "b97b498b-4ebc-49e9-a1da-d275d43edd53"
TRADE_AVERAGE_WINDOW_HOURS = 12
TRADE_AVERAGE_CACHE_SECONDS = 3600

def concrete_trade_items(entries)
  Array(entries).select do |entry|
    item = entry["item"]
    item.is_a?(String) && !item.start_with?("trade-option:")
  end
end

OFFER_SIDE_ONLY_CATEGORIES = ["Game Pass"].freeze
UPPER_PERCENTILE_VALUE_TITLES = ["2x Drop", "2x Luck", "Madoka Set", "Ragna Set"].freeze

def fetch_item_strategy_ids
  items = JSON.parse(URI.open(VALUE_LIST_URL, &:read))

  items.each_with_object({
    offer_side_only_item_ids: Set.new,
    upper_percentile_item_ids: Set.new
  }) do |item, strategy_ids|
    strategy_ids[:offer_side_only_item_ids] << item["_id"] if OFFER_SIDE_ONLY_CATEGORIES.include?(item["category"].to_s)
    strategy_ids[:upper_percentile_item_ids] << item["_id"] if UPPER_PERCENTILE_VALUE_TITLES.include?(item["title"].to_s)
  end
end

def upper_percentile_value(sorted_values, percentile)
  return nil if sorted_values.empty?

  index = ((sorted_values.length - 1) * percentile).ceil
  sorted_values[index]
end

def build_trade_average_payload
  cutoff = Time.now.utc - (TRADE_AVERAGE_WINDOW_HOURS * 60 * 60)
  ads = JSON.parse(URI.open(TRADE_ADS_URL, &:read))
  strategy_ids = fetch_item_strategy_ids
  offer_side_only_item_ids = strategy_ids[:offer_side_only_item_ids]
  upper_percentile_item_ids = strategy_ids[:upper_percentile_item_ids]
  item_prices = Hash.new { |hash, key| hash[key] = [] }

  ads.each do |ad|
    next unless ad["game_id"] == SAILOR_PIECE_GAME_ID

    created_at = Time.parse(ad["created_at"].to_s) rescue nil
    next unless created_at && created_at >= cutoff

    offer_items = concrete_trade_items(ad["offer"])
    request_items = concrete_trade_items(ad["request"])
    offer_crr = ad["offer_additional_amount"].to_f
    request_crr = ad["request_additional_amount"].to_f

    if offer_items.length == 1 && request_items.empty? && offer_crr <= 0 && request_crr > 0
      quantity = offer_items.first["amount"].to_f
      next unless quantity.positive?

      item_prices[offer_items.first["item"]] << (request_crr / quantity)
      next
    end

    if request_items.length == 1 && offer_items.empty? && request_crr <= 0 && offer_crr > 0
      next if offer_side_only_item_ids.include?(request_items.first["item"])

      quantity = request_items.first["amount"].to_f
      next unless quantity.positive?

      item_prices[request_items.first["item"]] << (offer_crr / quantity)
    end
  end

  averages = item_prices.each_with_object({}) do |(item_id, prices), hash|
    sorted = prices.compact.select { |price| price.finite? && price.positive? }.sort
    next if sorted.empty?

    computed_value = if upper_percentile_item_ids.include?(item_id)
      upper_percentile_value(sorted, 0.75)
    else
      trimmed = if sorted.length >= 5
        trim_count = [1, (sorted.length * 0.1).floor].max
        trimmed_slice = sorted[trim_count..-(trim_count + 1)]
        trimmed_slice.nil? || trimmed_slice.empty? ? sorted : trimmed_slice
      else
        sorted
      end

      trimmed.sum / trimmed.length
    end

    hash[item_id] = {
      "average_cRR" => computed_value,
      "sample_count" => sorted.length
    }
  end

  {
    "generated_at" => Time.now.utc.iso8601,
    "window_hours" => TRADE_AVERAGE_WINDOW_HOURS,
    "items" => averages
  }
end

cache = {
  generated_at: nil,
  payload: nil
}

server = WEBrick::HTTPServer.new(
  Port: PORT,
  BindAddress: BIND_ADDRESS,
  DocumentRoot: ROOT,
  AccessLog: [],
  Logger: WEBrick::Log.new($stderr, WEBrick::Log::INFO)
)

server.mount_proc "/health" do |_req, res|
  res.status = 200
  res["Content-Type"] = "application/json; charset=utf-8"
  res["Cache-Control"] = "no-store"
  res.body = JSON.generate({ status: "ok" })
end

server.mount_proc "/api/live-trade-averages" do |_req, res|
  begin
    if cache[:generated_at].nil? || (Time.now - cache[:generated_at]) > TRADE_AVERAGE_CACHE_SECONDS
      cache[:payload] = build_trade_average_payload
      cache[:generated_at] = Time.now
    end

    res.status = 200
    res["Content-Type"] = "application/json; charset=utf-8"
    res["Cache-Control"] = "no-store"
    res["Access-Control-Allow-Origin"] = "*"
    res.body = JSON.generate(cache[:payload])
  rescue StandardError => error
    res.status = 500
    res["Content-Type"] = "application/json; charset=utf-8"
    res["Cache-Control"] = "no-store"
    res["Access-Control-Allow-Origin"] = "*"
    res.body = JSON.generate({ error: error.message })
  end
end

server.mount "/", WEBrick::HTTPServlet::FileHandler, ROOT

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

puts "Serving Sailor Piece live document from #{ROOT} on http://#{BIND_ADDRESS}:#{PORT}"
server.start
