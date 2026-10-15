require "json"
require "../token_extract"
require "../display_columns"

module Gori::Fuzz
  # One named value a Fuzzer run pulls out of every response, drawn as its own results column
  # (#1592) — Burp Intruder's Grep-Extract item, Caido Automate's extractor.
  #
  # Not a second extraction grammar (P3): the descriptor is a History display column's
  # (`[LABEL=][res:]kind:selector`, `DisplayColumns.parse_spec`) and the value comes out of
  # `TokenExtract`, so `header:x-request-id` means the same thing in the History list, a session
  # binding and a fuzz row. What it drops is the side: a fuzz row's REQUEST is the template plus
  # the payload, which the operator already has, so `req:` is refused rather than read.
  #
  # The run's old single `extract` regex is extractor 0 under the label `extracted`
  # (`legacy`), so `Result#extracted` — the first extractor's value — keeps every reader of it.
  record Extractor, label : String, loc : TokenLoc do
    LEGACY_LABEL = "extracted"

    # The pre-#1592 `--extract REGEX` / MCP `extract` / TUI `"extract"` key, as extractor 0.
    def self.legacy(pattern : String) : Extractor
      new(LEGACY_LABEL, TokenLoc.new(ExtractKind::Regex, pattern))
    end

    # The descriptor as `--extractor` spells it, which is what a saved run stores. `LABEL=` only
    # when the grammar would not derive that label anyway, as `Store::DisplayColumn#spec` does:
    # a derived one can itself hold a `=` (`regex:c=(\d+)`), which a prefix would split on.
    def spec : String
      tail = loc.kind.position? ? "#{loc.pos_start}:#{loc.pos_end}" : loc.selector
      body = "#{loc.kind.label}:#{tail}"
      label == DisplayColumns.default_label(loc.kind, loc.selector, loc.pos_start, loc.pos_end) ? body : "#{label}=#{body}"
    end

    # A cookie or a credential-bearing header: masked on MCP unless `include_sensitive`, the
    # rule `list_history{columns}` applies (`DisplayColumns.sensitive?`).
    def sensitive? : Bool
      DisplayColumns.sensitive?(loc.kind, loc.selector)
    end

    # The shared parser behind `--extract`/`--extractor`, MCP `extract`/`extractors` and the
    # TUI's persisted list: the legacy regex first (when given), then each spec in order. The
    # refusal comes back as a sentence, so the CLI aborts with it and MCP answers
    # INVALID_ARGUMENT, before anything is sent.
    def self.parse(specs : Array(String), legacy : String? = nil) : Array(Extractor) | String
      out = [] of Extractor
      if (pattern = legacy) && !pattern.empty?
        # The legacy regex is a column too, so it counts toward the ceiling.
        if specs.size >= DisplayColumns::MAX_COLUMNS
          return "#{specs.size + 1} extractors asked for (with --extract); #{DisplayColumns::MAX_COLUMNS} is the limit"
        end
        if reason = DisplayColumns.invalid_reason(LEGACY_LABEL, ExtractKind::Regex, pattern)
          return "extract regex #{pattern.inspect}: #{reason}"
        end
        out << legacy(pattern)
      end
      parsed = DisplayColumns.parse_specs(specs)
      return parsed if parsed.is_a?(String)
      parsed.zip(specs) do |sp, raw|
        if sp.side.request?
          return "extractor #{raw.inspect}: an extractor reads the RESPONSE " \
                 "(a fuzz row's request is the template plus the payload); drop the `req:` prefix"
        end
        out << new(sp.label, TokenLoc.new(sp.kind, sp.selector, sp.pos_start, sp.pos_end))
      end
      out
    end

    # The TUI's list as it will be stored: `parse` over the specs it writes, refusing a label
    # that would not read back as itself. `LABEL=` splits only before the first `:`, so a label
    # `header:x` over `jsonpath:a` stores as `header:x=jsonpath:a` and reopens as a header one.
    def self.of_columns(cols : Array(Store::DisplayColumn)) : Array(Extractor) | String
      parsed = parse(cols.map(&.spec))
      return parsed if parsed.is_a?(String)
      cols.zip(parsed) do |c, e|
        next if e.label == c.label
        return "label #{c.label.inspect} would be read back as #{e.label.inspect}; drop its ':' or '='"
      end
      parsed
    end

    # A saved run's extractors, from the `fuzz_runs.extractors` JSON its specs were written to.
    # A run saved before #1592 (NULL) had at most the legacy regex, whose values read back as
    # `extracted`, so it gets that one label.
    #
    # Each spec is read on its own and keeps its POSITION, since a row's values are matched to
    # extractors by index. One that will not parse (a hand-edited or imported project) keeps its
    # raw text as the header and reads as a cookie, which every surface masks: an unreadable
    # descriptor fails closed rather than printing a value whose kind nobody knows.
    def self.of_run(json : String?) : Array(Extractor)
      return [legacy("")] if json.nil?
      JSON.parse(json).as_a.map do |v|
        raw = v.as_s? || v.to_json
        sp = DisplayColumns.parse_spec(raw)
        next new(raw, TokenLoc.new(ExtractKind::Cookie, raw)) if sp.is_a?(String)
        new(sp.label, TokenLoc.new(sp.kind, sp.selector, sp.pos_start, sp.pos_end))
      end
    rescue JSON::ParseException | TypeCastError
      [legacy("")]
    end

    # The specs as the run stored them, for a surface that reports the run's `extractors`.
    def self.specs_of(json : String) : Array(String)
      JSON.parse(json).as_a.map { |v| v.as_s? || v.to_json }
    rescue JSON::ParseException | TypeCastError
      [] of String
    end

    # The pre-#1592 single regex keeps its whole capture, as `--extract` always has.
    def legacy? : Bool
      label == LEGACY_LABEL && loc.kind.regex?
    end

    def self.to_json(extractors : Array(Extractor)) : String?
      return nil if extractors.empty?
      JSON.build { |j| j.array { extractors.each { |e| j.string e.spec } } }
    end

    # One captured value, cut to a cell (`DisplayColumns::CELL_MAX`) with a `…` saying so: a
    # value is stored per result row, and `position:0:500000` or a greedy regex must not put a
    # half-megabyte copy of the body into every one. The bytes stay the origin's otherwise (P7);
    # every surface repairs them only on display.
    def self.cap(value : String?) : String?
      return nil unless value
      value.size > DisplayColumns::CELL_MAX ? "#{value[0, DisplayColumns::CELL_MAX]}…" : value
    end
  end
end
