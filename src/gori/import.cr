require "./import/builder"
require "./import/har"
require "./import/urls"
require "./import/oas"

module Gori
  # Bulk-import captured flows from HAR files, URL lists, or OpenAPI specs.
  module Import
    record Result, count : Int32, skipped : Int32 = 0

    # Parsed flows plus a count of malformed entries skipped. Every parser skips a
    # bad ENTRY (invalid base64 body, non-http URL scheme, wrong-shaped path item)
    # rather than aborting the whole import — one stray line no longer discards an
    # otherwise-valid multi-thousand-entry file.
    record ParseResult, flows : Array(Builder::FlowPair), skipped : Int32 = 0

    def self.from_har(path : String) : ParseResult
      Har.parse_file(path)
    end

    def self.from_urls(path : String) : ParseResult
      Urls.parse_file(path)
    end

    def self.from_oas(path : String) : ParseResult
      Oas.parse_file(path)
    end

    # Insert every parsed pair into the store atomically. Returns the committed count.
    def self.insert_all(store : Store, pairs : Array(Builder::FlowPair)) : Int32
      batch = pairs.map do |pair|
        {pair.request, pair.response}
      end
      store.insert_import_batch(batch)
    end

    def self.import_file(store : Store, kind : Symbol, path : String) : Result
      expanded = Path[path].expand(home: true).to_s
      raise Gori::Error.new("file not found: #{expanded}") unless File.exists?(expanded)
      raise Gori::Error.new("not a file: #{expanded}") unless File.file?(expanded)

      parsed = case kind
               when :har  then from_har(expanded)
               when :urls then from_urls(expanded)
               when :oas  then from_oas(expanded)
               else            raise Gori::Error.new("unknown import kind: #{kind}")
               end
      raise Gori::Error.new("no flows found in #{expanded}") if parsed.flows.empty?
      Result.new(insert_all(store, parsed.flows), parsed.skipped)
    end
  end
end
