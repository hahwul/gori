require "json"
require "./form_data"
require "./entity"
require "./media_type"
require "./json_spans"
require "./miner/types"
require "./miner/inject"
require "./proxy/codec/http1"

module Gori
  # Every named INPUT a captured request carries — query, urlencoded form, multipart, JSON,
  # header and cookie — as a flat (location, name, value) stream. The read behind the
  # parameter inventory (`ParamInventory`, #1231), and deliberately a READ: nothing here is
  # ever spliced back onto the wire.
  #
  # Not a lift of `Probe::Active::InsertionPoints.enumerate` or `Miner::Inject.existing_names`,
  # although both walk the same surfaces. Each is shaped by the injector it serves, and
  # widening either would break the invariant it exists for: InsertionPoints yields only
  # TOP-LEVEL JSON strings (the members `build` can splice) with `index`/`raw_*` addressing
  # that the per-rule `dedup_key` equivalence pins, and `existing_names`' JSON set is on purpose
  # the same capped BFS `inject_json_nodes` writes into. An inventory needs the opposite of
  # both — every leaf at every depth, with its value — so it has its own walk, built on the
  # same primitives rather than a re-derivation of them:
  #
  #   * query / form / multipart → `FormData.from_flow`, the PARAMS pane's projection (it
  #     already reads the ENTITY, so a chunked or gzip'd form is not listed as garbage);
  #   * JSON → a pull-parser walk over `Entity.bytes`, gated by `MediaType.json?` and
  #     `JsonSpans.valid?`, reading numbers as their TEXT (never converted, so a value past
  #     Int64 cannot raise);
  #   * headers / cookies → `Miner::Inject.each_ascii_line`, the byte-safe head walk.
  #
  # Values are DECODED and UNSCRUBBED — captured bytes may be invalid UTF-8, and a surface
  # scrubs at the point it prints (P7: the octets stay canonical here).
  module Params
    extend self

    # One named input. `note` is set where the value is not text worth sampling — a multipart
    # file or binary part — and then `value` is empty. `literal` marks a JSON number, bool or
    # null: its text (`true`, `3600`) is the SPELLING of a value, not text the client chose,
    # and it occurs in almost any JSON response — so neither kind is searched for reflection.
    record Param, loc : Miner::Location, name : String, value : String, note : String? = nil,
      literal : Bool = false do
      def reflectable? : Bool
        note.nil? && !literal
      end
    end

    # JSON walk bounds: a pathological body (a million-element array, a 10k-deep nest) must
    # cost a bounded amount per flow, since the inventory reads thousands of flows.
    JSON_MAX_DEPTH  =   32
    JSON_MAX_LEAVES = 2000

    # Most a compressed JSON body is inflated to. The inventory reads thousands of flows on
    # the proxy's own scheduler, and the decoder's default ceiling (a 32 MiB bomb guard) is
    # sized for ONE body an operator opened, not for a sweep.
    DECODE_MAX = 1024 * 1024

    # `FormData`'s label for a multipart part with no `name=` — right for the PARAMS pane,
    # which shows the part, and wrong here: it is not a name a request carried, and as a
    # wordlist entry or a Miner seed it would be a guess nobody made.
    UNNAMED_PART = "(unnamed)"

    # Request headers every browser (or HTTP client) sends on its own, which say nothing about
    # the APPLICATION's inputs. Excluded from the header location unless the caller asks for
    # all of them; a header an app actually reads (`X-Api-Key`, `X-Tenant`, `X-Forwarded-For`)
    # is not on this list. Prefix families (`sec-*`, `accept-*`, `if-*`) are matched in
    # `standard_header?`, and hop-by-hop/framing names come from Miner's list, not a copy.
    STANDARD_HEADERS = Set{
      "host", "user-agent", "accept", "content-type", "content-length", "content-encoding", "cache-control",
      "pragma", "origin", "referer", "upgrade-insecure-requests", "dnt", "priority", "range",
      "x-requested-with", "cookie",
    }
    STANDARD_HEADER_PREFIXES = {"sec-", "accept-", "if-", "proxy-", "access-control-request-"}

    def standard_header?(name : String) : Bool
      n = name.downcase
      STANDARD_HEADERS.includes?(n) || Miner::Inject::FORBIDDEN_HEADERS.includes?(n) ||
        n.starts_with?(':') || STANDARD_HEADER_PREFIXES.any? { |p| n.starts_with?(p) }
    end

    # Yield each input of one request, in a stable order: query, body (form, multipart or
    # JSON), headers, cookies. `head` is the stored request head (request line included),
    # `body` the stored wire body. A malformed request line still has its body and head read
    # — the query is the only part that needs the line, so it is the only part that is lost.
    def each(head : Bytes, body : Bytes?, all_headers : Bool = false, & : Param ->) : Nil
      _, target, malformed = Proxy::Codec::Http1.parse_request_line(head)
      form_target = malformed ? "" : target
      ctype = MediaType.of(head)
      json = MediaType.json?(ctype)
      # A JSON body is never a form, so FormData gets the query alone and the body is decoded
      # once, below, rather than once there and again here.
      if fields = FormData.from_flow(form_target, head, json ? nil : body)
        multipart = MediaType.multipart?(ctype)
        fields.each do |f|
          next if f.name.empty?
          next if multipart && f.name == UNNAMED_PART
          loc = if f.source == :query
                  Miner::Location::Query
                elsif multipart
                  Miner::Location::Multipart
                else
                  Miner::Location::Form
                end
          yield Param.new(loc, f.name, f.value, f.note)
        end
      end

      if json && (entity = Entity.bytes(head, body, DECODE_MAX)) && !entity.empty?
        each_json_leaf(entity) do |path, value, literal|
          yield Param.new(Miner::Location::Json, path, value, literal: literal)
        end
      end

      each_head(head, all_headers) { |p| yield p }
    end

    # The member name as it appears inside a path: bare when it is a plain identifier-ish
    # key, else the bracket-quoted form `JsonPath.parse` reads back (`["a.b"]`).
    def json_key(key : String) : String
      return %([#{key.to_json}]) if key.empty? || key.each_char.any? { |c| c == '.' || c == '[' || c == ']' || c == '"' }
      key
    end

    # The LEAF member name of a JSON path — `user.email` → `email`, `items[].id` → `id`,
    # `["a.b"]` → `a.b` — which is what Miner's Json location injects (a key into an object
    # node, not a path). nil when the path ends in an array (`tags[]`), which has no name.
    def json_leaf(path : String) : String?
      return nil if path.ends_with?("[]")
      if path.ends_with?("\"]") && (open = path.rindex("[\""))
        return String.from_json(path[(open + 1)...-1]) rescue nil
      end
      dot = path.rindex('.')
      br = path.rindex(']')
      cut = [dot, br].compact.max?
      cut ? path[(cut + 1)..].presence : path
    end

    # Yield {path, scalar text, literal?} for every scalar leaf of a JSON document: strings decoded,
    # numbers/bools/null as their literal text. Arrays collapse their index to `[]`, so every
    # element of `items` contributes to one `items[].id` — an inventory counts names, not
    # positions. A body that is not exactly one JSON value yields nothing.
    def each_json_leaf(bytes : Bytes, & : String, String, Bool ->) : Nil
      return unless JsonSpans.valid?(bytes)
      acc = [] of {String, String, Bool}
      begin
        walk_json(JSON::PullParser.new(String.new(bytes)), "", 0, acc)
      rescue JSON::ParseException
        # `valid?` already ran the stdlib lexer over the whole document, so this is unreachable
        # short of a lexer disagreement with itself — and a best-effort read keeps what it had.
      end
      acc.each { |(path, value, literal)| yield path, value, literal }
    end

    # Recursive descent collecting into `acc` (a yielding method cannot recurse into itself),
    # bounded by JSON_MAX_DEPTH and JSON_MAX_LEAVES — past either, the rest is skipped.
    private def walk_json(pull : JSON::PullParser, path : String, depth : Int32,
                          acc : Array({String, String, Bool})) : Nil
      case pull.kind
      when .begin_object?
        return pull.skip if depth >= JSON_MAX_DEPTH
        pull.read_begin_object
        until pull.kind.end_object?
          key = json_key(pull.read_object_key)
          child = if path.empty?
                    key
                  elsif key.starts_with?('[')
                    "#{path}#{key}"
                  else
                    "#{path}.#{key}"
                  end
          acc.size >= JSON_MAX_LEAVES ? pull.skip : walk_json(pull, child, depth + 1, acc)
        end
        pull.read_end_object
      when .begin_array?
        return pull.skip if depth >= JSON_MAX_DEPTH
        pull.read_begin_array
        until pull.kind.end_array?
          acc.size >= JSON_MAX_LEAVES ? pull.skip : walk_json(pull, "#{path}[]", depth + 1, acc)
        end
        pull.read_end_array
      else
        literal = !pull.kind.string?
        value = scalar_text(pull)
        acc << {path, value, literal} unless path.empty? # a bare scalar document has no name to report
      end
    end

    private def scalar_text(pull : JSON::PullParser) : String
      case pull.kind
      when .string?
        pull.read_string
      when .int?, .float?
        text = pull.raw_value # the literal, never converted
        pull.skip
        text
      when .bool?
        pull.read_bool.to_s
      else
        pull.read_null
        "null"
      end
    end

    # Header and cookie inputs off the head. Header names are DOWN-CASED (field names are
    # case-insensitive, so `X-Api-Key` and `x-api-key` are one input); cookie names are kept
    # verbatim, since that namespace is case-sensitive. An obs-fold continuation line (leading
    # SP/HTAB) belongs to the header above it and is skipped rather than read as a header
    # whose NAME is value bytes.
    private def each_head(head : Bytes, all_headers : Bool, & : Param ->) : Nil
      first = true
      Miner::Inject.each_ascii_line(head) do |line|
        if first
          first = false
          next # the request line
        end
        break if line.empty? # the blank line ends the head
        next if line.starts_with?(' ') || line.starts_with?('\t')
        colon = line.index(':')
        next unless colon && colon > 0
        name = line[0...colon].strip.downcase
        value = line[(colon + 1)..].strip
        if name == "cookie"
          value.split(';') do |crumb|
            cname, eq, cval = crumb.partition('=')
            cname = cname.strip
            next if cname.empty? || eq.empty?
            yield Param.new(Miner::Location::Cookies, cname, cval.strip)
          end
        elsif all_headers || !standard_header?(name)
          yield Param.new(Miner::Location::Headers, name, value)
        end
      end
    end
  end
end
