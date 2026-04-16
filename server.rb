#!/usr/bin/env ruby

require "json"
require "open-uri"
require "set"
require "time"
require "webrick"

ROOT = File.expand_path(__dir__)
PORT = Integer(ARGV[0] || ENV.fetch("PORT", "4173"))
BIND_ADDRESS = ENV.fetch("BIND_ADDRESS", "0.0.0.0")
SAILOR_PIECE_GAME_ID = "b97b498b-4ebc-49e9-a1da-d275d43edd53"
TRADE_ADS_SOURCE_URL = "https://sailor-piece.vaultedvaluesx.com/api/trade-ads"
VALUE_LIST_SOURCE_URL = "https://valuevaultx.com/_functions/api/sailor-piece"
VALUE_LIST_CACHE_SECONDS = 60
TRADE_AVERAGE_WINDOW_HOURS = 12
TRADE_AVERAGE_CACHE_SECONDS = 3600

def concrete_trade_items(entries)
  Array(entries).filter_map do |entry|
    item_name = entry["item"].to_s.strip
    quantity = entry["amount"].to_f
    next if item_name.empty? || item_name.start_with?("trade-option:")
    next unless quantity.positive?

    {
      "item" => item_name,
      "amount" => quantity
    }
  end
end

OFFER_SIDE_ONLY_CATEGORIES = ["Game Pass"].freeze
UPPER_PERCENTILE_VALUE_TITLES = ["2x Drop", "2x Luck", "Madoka Set", "Ragna Set"].freeze
CRR_RANGE_REGEX = /
  (?<first>\d[\d,.]*)
  \s*(?<first_suffix>[kmb]?)
  \s*(?:-|to)\s*
  (?<second>\d[\d,.]*)
  \s*(?<second_suffix>[kmb]?)
  \s*(?:de\s+|pure\s+)?crr(?:s)?\b
/ix
CRR_SINGLE_REGEX = /
  (?<value>\d[\d,.]*)
  \s*(?<suffix>[kmb]?)
  \s*(?:de\s+|pure\s+)?crr(?:s)?\b
/ix
CRR_POSTFIX_REGEX = /
  \bcrr(?:s)?\b
  [^\d]{0,12}
  (?<value>\d[\d,.]*)
  \s*(?<suffix>[kmb]?)
/ix

def canonical_item_name(value)
  value.to_s.tr("’", "'").downcase.gsub(/\s+/, " ").strip
end

def parse_number_token(number_text, suffix_text = "")
  raw_text = number_text.to_s.strip.downcase.gsub(/\s+/, "")
  return nil if raw_text.empty?

  normalized_text =
    if raw_text.include?(".") && raw_text.include?(",")
      raw_text.delete(",")
    elsif raw_text.count(",") == 1 && !raw_text.include?(".") && raw_text.split(",").last.length != 3
      raw_text.tr(",", ".")
    else
      raw_text.delete(",")
    end

  numeric = Float(normalized_text)
  multiplier = case suffix_text.to_s.downcase
               when "k" then 1_000
               when "m" then 1_000_000
               when "b" then 1_000_000_000
               else 1
               end

  numeric * multiplier
rescue ArgumentError, TypeError
  nil
end

def parse_crr_amount_from_title(title)
  text = title.to_s
  return nil if text.empty?

  if (range_match = text.match(CRR_RANGE_REGEX))
    values = [
      parse_number_token(range_match[:first], range_match[:first_suffix]),
      parse_number_token(range_match[:second], range_match[:second_suffix])
    ].compact
    return values.sum / values.length if values.any?
  end

  if (single_match = text.match(CRR_SINGLE_REGEX))
    value = parse_number_token(single_match[:value], single_match[:suffix])
    return value if value&.positive?
  end

  if (postfix_match = text.match(CRR_POSTFIX_REGEX))
    value = parse_number_token(postfix_match[:value], postfix_match[:suffix])
    return value if value&.positive?
  end

  nil
end

def fetch_value_list_items
  payload = JSON.parse(URI.open(VALUE_LIST_SOURCE_URL, &:read))
  raise "Value list payload was not an array." unless payload.is_a?(Array)

  payload
end

def fetch_trade_ads
  payload = JSON.parse(URI.open("#{TRADE_ADS_SOURCE_URL}?gameId=#{SAILOR_PIECE_GAME_ID}", &:read))
  ads = payload["ads"]
  raise "Trade ads payload was invalid." unless ads.is_a?(Array)

  ads
end

def fetch_item_strategy_lookup(items)
  items.each_with_object({
    item_id_by_title: {},
    offer_side_only_item_ids: Set.new,
    upper_percentile_item_ids: Set.new
  }) do |item, strategy_lookup|
    item_id = item["_id"].to_s
    canonical_title = canonical_item_name(item["title"])
    next if item_id.empty? || canonical_title.empty?

    strategy_lookup[:item_id_by_title][canonical_title] = item_id
    strategy_lookup[:offer_side_only_item_ids] << item_id if OFFER_SIDE_ONLY_CATEGORIES.include?(item["category"].to_s)
    strategy_lookup[:upper_percentile_item_ids] << item_id if UPPER_PERCENTILE_VALUE_TITLES.include?(item["title"].to_s)
  end
end

def upper_percentile_value(sorted_values, percentile)
  return nil if sorted_values.empty?

  index = ((sorted_values.length - 1) * percentile).ceil
  sorted_values[index]
end

def build_trade_average_payload(value_items)
  cutoff = Time.now.utc - (TRADE_AVERAGE_WINDOW_HOURS * 60 * 60)
  ads = fetch_trade_ads
  strategy_lookup = fetch_item_strategy_lookup(value_items)
  item_id_by_title = strategy_lookup[:item_id_by_title]
  offer_side_only_item_ids = strategy_lookup[:offer_side_only_item_ids]
  upper_percentile_item_ids = strategy_lookup[:upper_percentile_item_ids]
  item_prices = Hash.new { |hash, key| hash[key] = [] }

  ads.each do |ad|
    next unless ad["gameId"] == SAILOR_PIECE_GAME_ID

    created_at = Time.parse(ad["createdAt"].to_s) rescue nil
    next unless created_at && created_at >= cutoff

    crr_amount = parse_crr_amount_from_title(ad["title"])
    next unless crr_amount&.positive?

    offer_items = concrete_trade_items(ad["offerItems"])
    request_items = concrete_trade_items(ad["requestItems"])

    if offer_items.length == 1 && request_items.empty?
      item_id = item_id_by_title[canonical_item_name(offer_items.first["item"])]
      next unless item_id

      quantity = offer_items.first["amount"].to_f
      next unless quantity.positive?

      item_prices[item_id] << (crr_amount / quantity)
      next
    end

    if request_items.length == 1 && offer_items.empty?
      item_id = item_id_by_title[canonical_item_name(request_items.first["item"])]
      next unless item_id
      next if offer_side_only_item_ids.include?(item_id)

      quantity = request_items.first["amount"].to_f
      next unless quantity.positive?

      item_prices[item_id] << (crr_amount / quantity)
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

def cached_payload(cache_entry, ttl)
  if cache_entry[:generated_at].nil? || (Time.now - cache_entry[:generated_at]) > ttl
    cache_entry[:payload] = yield
    cache_entry[:generated_at] = Time.now
  end

  cache_entry[:payload]
end

cache = {
  value_list: {
    generated_at: nil,
    payload: nil
  },
  trade_averages: {
    generated_at: nil,
    payload: nil
  }
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

server.mount_proc "/api/value-list" do |_req, res|
  begin
    value_list = cached_payload(cache[:value_list], VALUE_LIST_CACHE_SECONDS) do
      fetch_value_list_items
    end

    res.status = 200
    res["Content-Type"] = "application/json; charset=utf-8"
    res["Cache-Control"] = "no-store"
    res["Access-Control-Allow-Origin"] = "*"
    res.body = JSON.generate(value_list)
  rescue StandardError => error
    res.status = 500
    res["Content-Type"] = "application/json; charset=utf-8"
    res["Cache-Control"] = "no-store"
    res["Access-Control-Allow-Origin"] = "*"
    res.body = JSON.generate({ error: error.message })
  end
end

server.mount_proc "/api/live-trade-averages" do |_req, res|
  begin
    value_list = cached_payload(cache[:value_list], VALUE_LIST_CACHE_SECONDS) do
      fetch_value_list_items
    end
    trade_averages = cached_payload(cache[:trade_averages], TRADE_AVERAGE_CACHE_SECONDS) do
      build_trade_average_payload(value_list)
    end

    res.status = 200
    res["Content-Type"] = "application/json; charset=utf-8"
    res["Cache-Control"] = "no-store"
    res["Access-Control-Allow-Origin"] = "*"
    res.body = JSON.generate(trade_averages)
  rescue StandardError => error
    res.status = 500
    res["Content-Type"] = "application/json; charset=utf-8"
    res["Cache-Control"] = "no-store"
    res["Access-Control-Allow-Origin"] = "*"
    res.body = JSON.generate({ error: error.message })
  end
end

server.mount_proc "/render-upload.zip" do |_req, res|
  res.status = 404
  res["Content-Type"] = "text/plain; charset=utf-8"
  res["Cache-Control"] = "no-store"
  res.body = "Not found"
end

server.mount "/", WEBrick::HTTPServlet::FileHandler, ROOT

trap("INT") { server.shutdown }
trap("TERM") { server.shutdown }

puts "Serving Purple Document Hub from #{ROOT} on http://#{BIND_ADDRESS}:#{PORT}"
server.start
