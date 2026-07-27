require "./import/builder"
require "./import/har"
require "./import/urls"
require "./import/oas"
require "./import/postman"
require "./import/insomnia"
require "./import/burp"

module Gori
  # Bulk-import captured flows from HAR files, URL lists, OpenAPI specs, Postman or
  # Insomnia collections, or a Burp item export.
  module Import
    record Result, count : Int32, skipped : Int32 = 0

    # The human name of each source, in ONE place. The TUI card title, the TUI toast and the
    # CLI result line all read it, so they cannot drift apart as sources are added — the
    # comment in `ImportOverlay#label` promised one source of truth and, with six formats,
    # three parallel `case`s is where that promise breaks.
    LABELS = {
      :har      => "HAR",
      :urls     => "URLs",
      :oas      => "OpenAPI",
      :postman  => "Postman",
      :insomnia => "Insomnia",
      :burp     => "Burp",
    }

    def self.label(kind : Symbol) : String
      LABELS[kind]? || kind.to_s
    end

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

    def self.from_postman(path : String) : ParseResult
      Postman.parse_file(path)
    end

    def self.from_insomnia(path : String) : ParseResult
      Insomnia.parse_file(path)
    end

    def self.from_burp(path : String) : ParseResult
      Burp.parse_file(path)
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
               when :har      then from_har(expanded)
               when :urls     then from_urls(expanded)
               when :oas      then from_oas(expanded)
               when :postman  then from_postman(expanded)
               when :insomnia then from_insomnia(expanded)
               when :burp     then from_burp(expanded)
               else                raise Gori::Error.new("unknown import kind: #{kind}")
               end
      if parsed.flows.empty?
        # Preserve WHY nothing landed: if every entry was skipped as malformed, say so
        # (with the count) instead of the generic "no flows found", which hid the real
        # reason and threw away the skipped tally.
        if parsed.skipped > 0
          noun = parsed.skipped == 1 ? "entry was" : "entries were"
          raise Gori::Error.new("no flows imported from #{expanded} — all #{parsed.skipped} #{noun} skipped as malformed")
        end
        raise Gori::Error.new("no flows found in #{expanded}")
      end
      Result.new(insert_all(store, parsed.flows), parsed.skipped)
    end
  end
end
