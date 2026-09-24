require "./import/builder"
require "./import/har"
require "./import/urls"
require "./import/oas"
require "./import/postman"
require "./import/insomnia"
require "./import/burp"
require "./import/xml_mini"
require "./import/wsdl"
require "./import/raw"
require "./import/curl"

module Gori
  # Bulk-import captured flows from HAR files, URL lists, OpenAPI specs, Postman or
  # Insomnia collections, a Burp item export, or pasted curl commands.
  module Import
    # `attempted` is how many parsed pairs the import TRIED to write; `count` is how many
    # committed. They differ only when a chunk rolled back part-way (see `insert_all`), and
    # every surface that prints `count` has to say so when they do — a smaller number printed
    # as a success is how an import that half-failed looks like an import of a small file.
    #
    # `notes` are what the source said that the import could not carry — today only a curl
    # command's ignored transport flags. Empty for every file format.
    record Result, count : Int32, skipped : Int32 = 0, attempted : Int32 = 0,
      notes : Array(String) = [] of String do
      def short? : Bool
        attempted > 0 && count < attempted
      end

      # The clause a surface appends when the import did not finish. One home, because three
      # surfaces print this line and a fourth (MCP) emits the same facts as JSON.
      def shortfall_note : String?
        return nil unless short?
        "#{attempted - count} of #{attempted} did NOT commit (store busy or unwritable) — re-run the import to retry them"
      end
    end

    # The human name of each source, in ONE place. The TUI card title, the TUI toast and the
    # CLI result line all read it, so they cannot drift apart as sources are added — the
    # comment in `ImportOverlay#label` promised one source of truth and, with seven formats,
    # three parallel `case`s is where that promise breaks.
    LABELS = {
      :har      => "HAR",
      :urls     => "URLs",
      :oas      => "OpenAPI",
      :postman  => "Postman",
      :insomnia => "Insomnia",
      :burp     => "Burp",
      :wsdl     => "WSDL",
      :curl     => "cURL",
    }

    def self.label(kind : Symbol) : String
      LABELS[kind]? || kind.to_s
    end

    # Parsed flows plus a count of malformed entries skipped. Every parser skips a
    # bad ENTRY (invalid base64 body, non-http URL scheme, wrong-shaped path item)
    # rather than aborting the whole import — one stray line no longer discards an
    # otherwise-valid multi-thousand-entry file.
    record ParseResult, flows : Array(Builder::FlowPair), skipped : Int32 = 0

    # Where an imported flow came from, threaded from `import_file` down to the format parsers.
    #
    # A parser knows the bytes; it does not know which surface asked for the import or what the
    # file was called, and both of those are learned one layer up. Carried as one record so six
    # parser signatures grow by one parameter instead of three, and defaulted to `none` so a
    # caller that has no provenance to state (a spec, a direct `Har.parse_file`) still compiles
    # — the flow's `source` is `Import` either way, which is the fact that matters.
    record Provenance, surface : FlowSource::Surface? = nil, ref : String? = nil do
      def self.none : Provenance
        new
      end
    end

    def self.from_har(path : String, prov : Provenance = Provenance.none) : ParseResult
      Har.parse_file(path, prov)
    end

    def self.from_urls(path : String, prov : Provenance = Provenance.none) : ParseResult
      Urls.parse_file(path, prov)
    end

    def self.from_oas(path : String, prov : Provenance = Provenance.none) : ParseResult
      Oas.parse_file(path, prov)
    end

    def self.from_postman(path : String, prov : Provenance = Provenance.none) : ParseResult
      Postman.parse_file(path, prov)
    end

    def self.from_insomnia(path : String, prov : Provenance = Provenance.none) : ParseResult
      Insomnia.parse_file(path, prov)
    end

    def self.from_burp(path : String, prov : Provenance = Provenance.none) : ParseResult
      Burp.parse_file(path, prov)
    end

    def self.from_wsdl(path : String, prov : Provenance = Provenance.none) : ParseResult
      Wsdl.parse_file(path, prov)
    end

    # Every curl command in `text`, one flow per request, each stored BYTE-EXACT through
    # `Raw.request_flow` — the head `Curl` built is the request, so it is neither re-serialized
    # nor re-split. A command `Curl` refused is a skipped entry, like a malformed HAR entry, and
    # its reason rides in the notes; when NOTHING came out, the refusal itself is the error,
    # since "no flows found" would hide the one reason there is. Returns the parse plus every
    # note, deduplicated.
    def self.from_curl_text(text : String, prov : Provenance = Provenance.none) : {ParseResult, Array(String)}
      parsed = Curl.parse(text)
      if parsed.requests.empty?
        raise Gori::Error.new(parsed.skipped.first? || "the paste holds no curl command with a URL")
      end
      now = Time.utc.to_unix * 1_000_000
      skipped = parsed.skipped.size
      pairs = [] of Builder::FlowPair
      refused = parsed.skipped.map { |why| "refused: #{why}" }
      parsed.requests.each do |req|
        pairs << Raw.request_flow(now, "#{req.origin}/", req.head, req.body,
          source_surface: prov.surface, source_ref: prov.ref)
      rescue ex : Gori::Error
        skipped += 1
        refused << "refused #{req.method} #{req.url}: #{ex.message}"
      end
      notes = (parsed.notes + parsed.requests.flat_map(&.notes) + refused).uniq
      {ParseResult.new(pairs, skipped), notes}
    end

    # Pasted curl text straight into History — the TUI's Import: cURL and MCP's
    # `import_flows{kind:"curl", text}`, where there is no file to name. `ref` stands in for
    # the file name on each flow's provenance.
    def self.import_curl_text(store : Store, text : String, surface : FlowSource::Surface? = nil,
                              ref : String = "curl") : Result
      parsed, notes = from_curl_text(text, Provenance.new(surface, ref))
      raise Gori::Error.new("no flows imported — every curl command was refused") if parsed.flows.empty?
      committed, attempted = insert_all(store, parsed.flows)
      Result.new(committed, parsed.skipped, attempted, notes)
    end

    # Pairs per store write. The whole file used to go in as ONE `insert_import_batch`, which
    # is one writer op and therefore ONE transaction — and `Store::BATCH_MAX` bounds ops per
    # transaction, not pairs per op, so nothing capped it. A captured flow arriving mid-import
    # waits behind the entire file, which is the one thing P6 says must not happen.
    #
    # MEASURED on a 50k-entry HAR, with capture writes running against the same store
    # (median of three; the numbers are stable to ~1%):
    #
    #   chunk   import    worst capture stall
    #   none     598 ms   598 ms
    #   1000     703 ms    13 ms
    #   2000     569 ms    22 ms
    #   4000     496 ms    41 ms
    #
    # 2000 is the size that is better than today on BOTH axes — the import is slightly faster
    # than the single giant transaction, and the stall drops 26x. (Chunking being faster is
    # not a typo: one enormous transaction costs more in WAL and memory than several medium
    # ones. 4000 is faster still, but there is no reason to buy speed with stall when the
    # smaller size already beats the status quo.)
    IMPORT_CHUNK = 2000

    # Insert every parsed pair. Returns {committed, attempted}.
    #
    # NOT atomic across the file any more, and the count says so. A chunk that rolls back (a
    # closing store, a full disk) stops the import with the earlier chunks already committed,
    # so the caller is handed both numbers and every surface reports the shortfall rather than
    # printing a smaller success. Whole-file atomicity was not protecting much: nothing
    # deduplicates on re-import, so a failed all-or-nothing import meant starting over anyway,
    # and 80% of a 200 MB HAR plus an honest message beats losing all of it.
    #
    # `cancelled` is polled between chunks (the TUI's import job sets it from the palette;
    # what is committed stays) and `progress` is told the running count after each — both
    # optional, and neither changes the count that comes back: a cancelled import is a
    # short one, and the caller says so.
    def self.insert_all(store : Store, pairs : Array(Builder::FlowPair), *,
                        cancelled : (-> Bool)? = nil, progress : (Int32, Int32? ->)? = nil) : {Int32, Int32}
      committed = 0
      pairs.each_slice(IMPORT_CHUNK) do |slice|
        break if cancelled.try(&.call)
        landed = insert_chunk(store, slice)
        committed += landed
        progress.try(&.call(committed, pairs.size))
        # A short answer means the batch rolled back or the store is closing; stop rather than
        # push more work at a store that just refused some.
        break if landed < slice.size
      end
      {committed, pairs.size}
    end

    # One chunk, one transaction: the flows, then each flow's WebSocket transcript against the
    # id it just got. Returns how many of `slice` committed.
    def self.insert_chunk(store : Store, slice : Array(Builder::FlowPair)) : Int32
      # `_ids`, not the counting form: a flow's WebSocket transcript is stored against the
      # flow id, which does not exist until this write commits.
      ids = store.insert_import_batch_ids(slice.map { |pair| {pair.request, pair.response} })
      # Ids come back in PAIR ORDER, which is what makes the index the pairing. A short
      # answer is a rolled-back batch, and walking the ids we actually got is then exactly
      # right: the pairs past the end have no flow to hang messages on.
      ids.each_with_index do |id, i|
        msgs = slice[i].ws_messages
        store.insert_ws_messages(id, msgs) unless msgs.empty?
      end
      ids.size
    end

    # A HAR is imported as it is READ: `Har.each_flow` walks the entries off the file one at a
    # time and this writes them a chunk at a time, so neither the parsed tree nor the flow
    # pairs of a 200 MB file are ever all in memory, and the fiber yields on the way (the
    # walk paces itself; the store write does). The other formats are small by nature and
    # keep the parse-then-insert shape.
    #
    # `progress` gets a nil total — a stream does not know its length. A file that turns out
    # to be invalid JSON PAST some entries has already had those written; the error says so,
    # because "not valid JSON" alone reads as "nothing happened".
    private def self.import_har_stream(store : Store, path : String, prov : Provenance,
                                       cancelled : (-> Bool)?, progress : (Int32, Int32? ->)?) : Result
      committed = 0
      attempted = 0
      chunk = [] of Builder::FlowPair
      refused = false
      flush = -> {
        return if chunk.empty? || refused
        attempted += chunk.size
        landed = insert_chunk(store, chunk)
        committed += landed
        refused = landed < chunk.size # the store rolled back / is closing: stop pushing
        chunk.clear
        progress.try(&.call(committed, nil))
      }
      skipped = begin
        Har.each_flow(path, prov, cancelled: -> { refused || (cancelled.try(&.call) || false) }) do |pair|
          chunk << pair
          flush.call if chunk.size >= IMPORT_CHUNK
        end
      rescue ex : Gori::Error
        raise ex if committed == 0
        raise Gori::Error.new("#{ex.message} — #{committed} flows from the entries before it were written")
      end
      flush.call
      raise_nothing_landed(path, skipped) if attempted == 0 && !cancelled.try(&.call)
      Result.new(committed, skipped, attempted)
    end

    # Preserve WHY nothing landed: if every entry was skipped as malformed, say so (with the
    # count) instead of the generic "no flows found", which hid the real reason and threw
    # away the skipped tally.
    private def self.raise_nothing_landed(path : String, skipped : Int32) : NoReturn
      if skipped > 0
        noun = skipped == 1 ? "entry was" : "entries were"
        raise Gori::Error.new("no flows imported from #{path} — all #{skipped} #{noun} skipped as malformed")
      end
      raise Gori::Error.new("no flows found in #{path}")
    end

    # A file of curl commands: read whole (a paste is small), then the text path.
    private def self.import_curl_file(store : Store, path : String, surface : FlowSource::Surface?,
                                      prov : Provenance) : Result
      text = begin
        File.read(path)
      rescue ex : File::Error
        raise Gori::Error.new("cannot read #{path}: #{ex.message}")
      end
      import_curl_text(store, text, surface, prov.ref || "curl")
    end

    # `surface` is which of gori's three faces asked for this import. Every imported flow is
    # stamped `source: import` and `source_ref: <basename>`, so a History row can say WHICH file
    # it came out of — the provenance question an operator actually asks of an imported row.
    def self.import_file(store : Store, kind : Symbol, path : String,
                         surface : FlowSource::Surface? = nil, *,
                         cancelled : (-> Bool)? = nil, progress : (Int32, Int32? ->)? = nil) : Result
      expanded = Path[path].expand(home: true).to_s
      raise Gori::Error.new("file not found: #{expanded}") unless File.exists?(expanded)
      raise Gori::Error.new("not a file: #{expanded}") unless File.file?(expanded)
      prov = Provenance.new(surface, File.basename(expanded))

      if kind == :har
        begin
          return import_har_stream(store, expanded, prov, cancelled, progress)
        rescue ex : File::Error
          raise Gori::Error.new("cannot read #{expanded}: #{ex.message}")
        end
      end
      return import_curl_file(store, expanded, surface, prov) if kind == :curl
      parsed = begin
        case kind
        when :har      then from_har(expanded, prov)
        when :urls     then from_urls(expanded, prov)
        when :oas      then from_oas(expanded, prov)
        when :postman  then from_postman(expanded, prov)
        when :insomnia then from_insomnia(expanded, prov)
        when :burp     then from_burp(expanded, prov)
        when :wsdl     then from_wsdl(expanded, prov)
        else                raise Gori::Error.new("unknown import kind: #{kind}")
        end
      rescue ex : File::Error
        raise Gori::Error.new("cannot read #{expanded}: #{ex.message}")
      end
      raise_nothing_landed(expanded, parsed.skipped) if parsed.flows.empty?
      committed, attempted = insert_all(store, parsed.flows, cancelled: cancelled, progress: progress)
      Result.new(committed, parsed.skipped, attempted)
    end
  end
end
