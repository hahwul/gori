require "./store"
require "./token_extract"

module Gori
  # User-defined History columns (#819) — the model shared by the TUI list, the column editor,
  # `gori run history --column` and MCP `list_history`.
  #
  # A column is an EXTRACT DESCRIPTOR the list draws. QL already answers "which flows match";
  # nothing answered "what is the value of X in each row" — an `X-Request-Id`, a JWT `sub`, a
  # rate-limit header, a JSON field. The machinery to pull those out of a message has existed
  # since session bindings (#501); until now its output only ever fed Bindings, never the eye.
  #
  # ## What this module is NOT
  #
  # It is not a second extraction grammar (P3). Every value here comes out of
  # `Gori::TokenExtract` through the same `TokenLoc` an extract rule carries, so a column and a
  # binding reading `header:x-request-id` off the same flow cannot disagree. What this adds is
  # the two axes a DISPLAYED value needs and a bound one does not: an order, and a side.
  #
  # It is also not a projection over the store (P8). Values are computed for the rows a caller
  # is about to draw or print, from bytes it reads for exactly those rows — never precomputed,
  # never indexed, never stored. `Prepared#values` takes one already-loaded `FlowDetail`; the
  # decision of which flows to load is the caller's, and every caller makes it per screenful or
  # per printed page.
  module DisplayColumns
    # The cell width a column with no explicit width gets, and the bounds an explicit one is
    # clamped to. 12 fits a short id, a rate-limit count or a truncated token; the operator
    # widens the ones that need it.
    DEFAULT_WIDTH = 12
    MIN_WIDTH     =  3
    MAX_WIDTH     = 40

    # How many columns one project may define. Every column takes cells from HOST and PATH —
    # the two that answer "what request is this" — so the ceiling is not arbitrary hygiene: past
    # a handful the list stops being a list of requests. Eight is already more than any terminal
    # under ~200 columns can draw.
    MAX_COLUMNS = 8

    # How many body bytes a body-scoped column reads per row.
    #
    # `Cookie`/`Header` read the head alone and cost nothing; `Regex`/`JsonPath`/`Position` need
    # the decoded entity, and a screenful of 50 rows with an uncapped read is 50 multi-MiB BLOBs
    # pulled out of SQLite per frame. The cap is generous enough that an ordinary JSON API
    # response is whole (a truncated body fails to parse and the cell goes blank — which is the
    # honest answer, since the value may well have been past the cut), and the exact bytes are
    # always one `↵` away in the detail pane.
    BODY_CAP = 512 * 1024

    # Longest cell any surface draws or prints. Far past `MAX_WIDTH` so the TUI never sees the
    # cut, and past anything an id, a token or a JSON leaf runs to — see `display_safe`.
    CELL_MAX = 512

    # Load this project's columns, left to right.
    def self.load(store : Store) : Array(Store::DisplayColumn)
      store.display_columns
    rescue ex
      # The History render path asks for this; a store that cannot answer must cost the columns,
      # not the tab.
      ::Log.warn { "display_columns read failed: #{ex.message}" }
      [] of Store::DisplayColumn
    end

    # Does this set need the message BODY? Answers whether a caller has to pay for the BLOBs at
    # all — a head-only set is served by `Store#get_flow(body_max: 0)`-shaped reads.
    def self.body_scoped?(columns : Array(Store::DisplayColumn)) : Bool
      columns.any?(&.body_scoped?)
    end

    # A column set with its regexes already compiled — the shape every row loop should hold.
    #
    # `TokenExtract.regex` compiles its pattern when it is not handed one, which on a row loop is
    # once per row per column: the same pattern rebuilt 50 times a frame. The engine's own
    # `run_live` takes a precompiled `re` for exactly this reason; this is that argument applied
    # to the list.
    #
    # A pattern that will not compile yields nil here and a BLANK cell for every row, which is
    # the same answer `TokenExtract.regex` gives (it rescues and returns nil). The editor refuses
    # to save one; this is the backstop for a hand-edited or peer-written row.
    class Prepared
      getter columns : Array(Store::DisplayColumn)
      @regexes : Array(Regex?)
      # `@body_prefix[i]` = does any of the FIRST `i + 1` columns read the body. Precomputed
      # beside the regexes for the same reason: `body_scoped?` is asked once per row in all three
      # row loops, and re-walking the array there is the work this class exists to have done
      # already. A prefix and not one flag, because a renderer that only fits the first N columns
      # must only pay for the first N (see `values`).
      @body_prefix : Array(Bool)

      def initialize(@columns : Array(Store::DisplayColumn))
        @regexes = @columns.map do |c|
          next nil unless c.kind.regex?
          begin
            Regex.new(c.selector)
          rescue ArgumentError | Regex::Error
            nil
          end
        end
        seen = false
        @body_prefix = @columns.map { |c| seen ||= c.body_scoped? }
      end

      def empty? : Bool
        @columns.empty?
      end

      def size : Int32
        @columns.size
      end

      # Does evaluating the first `count` columns need the message BODY? Answers whether a caller
      # has to pay for the BLOBs at all — a head-only set is served by a `body_max: 0` read.
      def body_scoped?(count : Int32 = @columns.size) : Bool
        n = count.clamp(0, @columns.size)
        n > 0 && @body_prefix[n - 1]
      end

      # One value per column, in column order, for the first `count` columns. A descriptor that
      # matches nothing yields "" — BLANK, never the selector: a cell that echoed its own
      # descriptor would read as a value the message carried.
      #
      # `count` exists because a narrow terminal draws only a PREFIX of the set (see
      # `HistoryView#granted_columns`), and extracting a column nothing will draw is not free:
      # the dropped one may be the only body-scoped descriptor, and evaluating it costs the BLOB
      # read and a full content-decode per row for cells that never reach the screen.
      #
      # The two subjects are built at most once each, so N columns over one flow parse the head
      # once per side rather than once per column.
      def values(detail : Store::FlowDetail, count : Int32 = @columns.size) : Array(String)
        n = count.clamp(0, @columns.size)
        return [] of String if n == 0
        req = nil.as(ExtractSubject?)
        res = nil.as(ExtractSubject?)
        Array(String).new(n) do |i|
          c = @columns[i]
          subject =
            if c.side.request?
              req ||= ExtractSubject.request(detail.request_head, detail.request_body, BODY_CAP)
            else
              res ||= ExtractSubject.response(detail.response_head, detail.response_body, BODY_CAP)
            end
          DisplayColumns.display_safe(TokenExtract.extract(subject, c.token_loc, @regexes[i]))
        end
      end
    end

    def self.prepare(columns : Array(Store::DisplayColumn)) : Prepared
      Prepared.new(columns)
    end

    # An extracted value as a SINGLE-LINE cell. `TokenExtract` is byte-faithful by design — a
    # `Position` range hands back raw bytes, and a header value may carry anything the peer put
    # on the wire — so a value reaching a terminal row, a padded CLI column or a JSON string has
    # to be repaired first: invalid UTF-8 scrubbed, and every control character (a CR that would
    # rewrite the row, a LF that would split it) drawn as `·`. The exact bytes stay one `↵` away
    # in the detail pane.
    def self.display_safe(value : String?) : String
      return "" if value.nil?
      s = value.scrub
      # A cell, not a document. `position:0:500000` is a legal descriptor and `regex` can match
      # most of a body, and without this the row loop would build a half-megabyte String per
      # row per frame to draw forty cells of it — and a text listing would print the whole
      # thing on one line. Cut with `…` rather than silently, so no reader mistakes the cell
      # for the whole value; the exact bytes are one `↵` (or `gori run show`) away.
      s = "#{s[0, CELL_MAX]}…" if s.size > CELL_MAX
      return s unless s.each_char.any?(&.control?)
      String.build { |io| s.each_char { |c| io << (c.control? ? '·' : c) } }
    end

    # The cell width this column draws in.
    def self.width_of(col : Store::DisplayColumn) : Int32
      col.width <= 0 ? DEFAULT_WIDTH : col.width.clamp(MIN_WIDTH, MAX_WIDTH)
    end

    # What is wrong with a column as described, or nil when it may be saved. One sentence per
    # problem, shared by the editor overlay, `gori run` and MCP so the three cannot word — or
    # decide — the same refusal differently.
    def self.invalid_reason(label : String, kind : Gori::ExtractKind, selector : String,
                            pos_start : Int32 = 0, pos_end : Int32 = 0) : String?
      return "enter a column label" if label.strip.empty?
      if kind.position?
        return "enter a byte range like 0:32" if pos_end <= pos_start
        return nil
      end
      return "enter a #{kind.label} selector" if selector.strip.empty?
      if kind.regex?
        begin
          Regex.new(selector)
        rescue ex : ArgumentError | Regex::Error
          return "that regex does not compile: #{ex.message}"
        end
      end
      nil
    end

    # --- `--column` / MCP spec strings -----------------------------------------------------
    #
    # `[LABEL=][side:]kind:selector`, e.g. `header:x-request-id`, `req:header:authorization`,
    # `RID=jsonpath:data.id`, `position:0:32`, `regex:token=(\w+)`.
    #
    # The two separators cannot be confused, and the rule that keeps them apart is written here
    # once: a `=` counts as the label separator only when it comes BEFORE the first `:`. Without
    # that, `regex:token=(\w+)` — a perfectly ordinary pattern — would be read as a column
    # labelled `regex:token` extracting `(\w+)` by a kind that does not exist.
    # No `width`: a spec has no syntax for one. The grammar is `[LABEL=][side:]kind:selector` and
    # nothing parses a cell width out of it, so a field here could only ever hold the 0 that means
    # "auto" — a member that reads as a supported axis of the flag and is not one. Width is a
    # persisted column's property, set in the editor.
    record Spec,
      label : String,
      side : Gori::MessageSide,
      kind : Gori::ExtractKind,
      selector : String,
      pos_start : Int32,
      pos_end : Int32 do
      # The store row this spec describes, with a synthetic id/position — what an EPHEMERAL
      # column (a `--column` flag, an MCP `columns` argument) is: a descriptor that draws for
      # this one listing and is never persisted.
      def to_column(index : Int32) : Store::DisplayColumn
        Store::DisplayColumn.new(0_i64, index, label, side, kind, selector, pos_start, pos_end, 0)
      end
    end

    # Parses one spec, or returns the refusal as a String. Returning the message rather than
    # raising is what lets `gori run` abort with a sentence and MCP answer INVALID_ARGUMENT
    # from the same parse.
    def self.parse_spec(raw : String) : Spec | String
      text = raw.strip
      return "empty --column spec" if text.empty?

      label = ""
      colon = text.index(':')
      eq = text.index('=')
      if eq && (colon.nil? || eq < colon)
        label = text[0...eq].strip
        text = text[(eq + 1)..]
        return "column #{raw.inspect}: the label before `=` is empty" if label.empty?
      end

      side = Gori::MessageSide::Response
      head, _, rest = text.partition(':')
      # A side prefix only counts when something follows it: `res:` alone names no descriptor,
      # and no `ExtractKind` spelling collides with a `MessageSide` one, so this cannot swallow
      # a kind.
      if !rest.empty? && (s = Gori::MessageSide.parse?(head)) && rest.includes?(':')
        side = s
        head, _, rest = rest.partition(':')
      end

      kind = Gori::ExtractKind.parse?(head)
      unless kind
        return "column #{raw.inspect}: unknown kind #{head.inspect} " \
               "(cookie | header | regex | position | jsonpath)"
      end

      pos_start = 0
      pos_end = 0
      selector = rest
      if kind.position?
        a, _, b = rest.partition(':')
        ai = a.strip.to_i32?
        bi = b.strip.to_i32?
        unless ai && bi
          return "column #{raw.inspect}: a position column needs a byte range like position:0:32"
        end
        pos_start, pos_end = ai, bi
        selector = ""
      end

      if reason = invalid_reason(label.empty? ? default_label(kind, selector, pos_start, pos_end) : label,
           kind, selector, pos_start, pos_end)
        return "column #{raw.inspect}: #{reason}"
      end
      label = default_label(kind, selector, pos_start, pos_end) if label.empty?
      # SCRUBBED here, at the seam where it enters gori. A `--column` label comes off ARGV, which
      # on Unix is bytes and need not be valid UTF-8 — and this label becomes a JSON object KEY
      # on two feeds. `JSON::Builder#string` escapes JSON metacharacters but passes raw bytes
      # through, so one such label would produce a document no parser accepts, poisoning every
      # row rather than its own cell. Repaired once here so no emitter has to remember.
      Spec.new(label.scrub, side, kind, selector, pos_start, pos_end)
    end

    # Parses every spec, or returns the FIRST refusal. `[]` for no specs.
    #
    # `MAX_COLUMNS` is enforced HERE and not only in the editor, for the reason `invalid_reason`
    # is shared: the refusal has to be one decision. Without it the editor refused a ninth column
    # while `gori run ls --column`×200 and an MCP `list_history{limit: 500, columns: [200 …]}`
    # compiled two hundred regexes and fanned out a hundred thousand extractions, on the surface
    # whose own schema text asks the caller to request only what they will read.
    def self.parse_specs(raw : Array(String)) : Array(Spec) | String
      if raw.size > MAX_COLUMNS
        return "#{raw.size} columns asked for; #{MAX_COLUMNS} is the limit " \
               "(every column costs one read per row)"
      end
      out = [] of Spec
      raw.each do |r|
        parsed = parse_spec(r)
        return parsed if parsed.is_a?(String)
        out << parsed
      end
      out
    end

    # `label → value` for one row, folded so two columns sharing a label become an ARRAY rather
    # than one dropping the other. Two columns MAY share one — the same header off the request
    # and off the response is a comparison, not a mistake — and nothing keys a column by name.
    #
    # Here rather than in each emitter because `CLI::Output` and `MCP::Serialize` had a byte-for-
    # byte copy each, differing only in which of two identical scrub helpers they called on a
    # value `display_safe` had already repaired. The label is matched EXACTLY, not
    # case-insensitively: unlike a header name it is operator text with no RFC folding it.
    def self.fold_by_label(columns : Array({String, String})) : Array({String, Array(String)})
      order = [] of String
      by_label = {} of String => Array(String)
      columns.each do |(label, value)|
        order << label unless by_label.has_key?(label)
        (by_label[label] ||= [] of String) << value
      end
      order.map { |label| {label, by_label[label]} }
    end

    # The header a spec with no explicit label gets: the selector itself, which is what the
    # operator typed and therefore what they will recognise at the top of the column.
    def self.default_label(kind : Gori::ExtractKind, selector : String,
                           pos_start : Int32 = 0, pos_end : Int32 = 0) : String
      return "#{pos_start}:#{pos_end}" if kind.position?
      selector.strip.empty? ? kind.label : selector.strip
    end
  end
end
