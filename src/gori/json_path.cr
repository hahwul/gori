require "json"
require "./raw_json"

module Gori
  # The one path grammar every JSON field reader shares: Retest's `json:`/`json-absent:`
  # assertions and `TokenExtract.json_path` (the Sequencer's `--jsonpath`, session-slot
  # bindings, display columns).
  #
  # There were two, and they disagreed: Retest split on `.` only, so `$.data.token` looked up
  # a key literally named `$` and `items[0]` one named `items[0]` — neither ever resolved, and
  # a `json-absent:` over either PASSED against a response still carrying the field (#1201).
  # TokenExtract read `$`/`[0]`/`["k"]` but not a dotted index, and quietly dropped whatever
  # followed an unclosed `[`. Now both read the same steps, and a path this cannot read is
  # REFUSED (`parse` answers why) rather than resolved as "absent", which for an assertion
  # whose job is to confirm a leak is gone is the one wrong answer that looks like success.
  #
  # Accepted: an optional leading `$`, then any mix of
  #   `.name` / a bare leading `name` — a member; all-digit (`items.0`) also indexes an array
  #   `["name"]` / `['name']`       — a member, any characters but its own quote
  #   `[n]`                         — an array index; negative counts from the end
  #   `[name]`                      — a member (unquoted, as TokenExtract always read it)
  # Refused: wildcards (`*`), recursive descent (`..`), filters/scripts, slices and unions in
  # an unquoted `[...]`, an empty step, and an unclosed or stray bracket.
  module JsonPath
    extend self

    # One step. `index` alone is `[n]` (arrays only). `key` alone is a member. Both is a dotted
    # all-digit step, which is a member on an object — an object may be keyed `"0"`, and the key
    # is the more specific reading — and an index on an array.
    record Step, key : String? = nil, index : Int32? = nil

    # Inside an unquoted `[...]` these are JSONPath syntax gori does not implement — a
    # wildcard, a filter or script, a slice, a union — never part of a name.
    UNSUPPORTED = {'*', '?', '(', ')', '@', ':', ','}

    # The steps of `path`, or the sentence saying why it cannot be read.
    def parse(path : String) : Array(Step) | String
      p = path.strip
      return "empty JSON path" if p.empty?
      steps = [] of Step
      i, err = head(p, steps)
      return err if err
      while i < p.size
        case p[i]
        when '.'
          return "recursive descent (`..`) is not supported in #{path.inspect}" if p[i + 1]? == '.'
          # A trailing `.` names nothing further; both readers always accepted it (`data.`).
          break if i == p.size - 1 && !steps.empty?
          i, err = dotted(p, i + 1, steps)
          return err if err
        when '['
          i, err = bracket(p, i, steps)
          return err if err
        else
          return "unexpected #{p[i].inspect} in JSON path #{path.inspect} — separate steps with `.` or `[...]`"
        end
      end
      steps
    end

    def valid?(path : String) : Bool
      parse(path).is_a?(Array)
    end

    # The value at `steps`, or nil when there is no such field. A field holding JSON `null`
    # resolves to the `JSON::Any` wrapping nil — it is PRESENT (`{"error": null}` has the field).
    def resolve(doc : JSON::Any, steps : Array(Step)) : JSON::Any?
      node = doc
      steps.each do |st|
        if (h = node.as_h?) && (key = st.key)
          node = h[key]? || return nil
        elsif (arr = node.as_a?) && (idx = st.index)
          idx += arr.size if idx < 0
          return nil unless 0 <= idx < arr.size
          node = arr[idx]
        else
          return nil
        end
      end
      node
    end

    # The value at `steps` as JSON TEXT read straight off `json` — compact, but with every number
    # as its literal digits and every duplicated member kept — or nil when there is no such
    # field. The twin of `resolve` for a reader that has to SHOW or COMPARE a value: a tree from
    # `RawJson.parse` carries a number past Int64 as a String, so writing a container back out
    # of it would quote that number (`{"id":"18446744073709551615"}`). Same last-wins rule for
    # a duplicated key as `resolve`. Raises JSON::ParseException when `json` is not JSON.
    def raw_at(json : String, steps : Array(Step)) : String?
      return RawJson.reformat(json) if steps.empty?
      text = json
      steps.each do |st|
        pull = JSON::PullParser.new(text)
        case pull.kind
        when .begin_object?
          key = st.key || return nil
          found = nil.as(String?)
          pull.read_object { |k| (raw = pull.read_raw; found = raw if k == key) }
          text = found || return nil
        when .begin_array?
          idx = st.index || return nil
          elems = [] of String
          pull.read_array { elems << pull.read_raw }
          idx += elems.size if idx < 0
          return nil unless 0 <= idx < elems.size
          text = elems[idx]
        else
          return nil
        end
      end
      text
    end

    # nil for a missing field AND for a path `parse` refuses — for a reader that has no one to
    # tell why (an extractor yields "no token" either way).
    def resolve(doc : JSON::Any, path : String) : JSON::Any?
      steps = parse(path)
      steps.is_a?(String) ? nil : resolve(doc, steps)
    end

    # Where the step loop starts: past a root `$`, past a bare leading member (`data.token`, or
    # `$oid` — a `$` not followed by a step is part of a name, read as if it followed a `.`),
    # or at 0 when the path opens with `.` or `[`.
    private def head(p : String, steps : Array(Step)) : {Int32, String?}
      return {1, nil} if p[0] == '$' && (p.size == 1 || p[1] == '.' || p[1] == '[')
      return {0, nil} if p[0] == '.' || p[0] == '['
      dotted(p, 0, steps)
    end

    # A member name after a `.` (or at the start), up to the next `.` or `[`.
    private def dotted(p : String, from : Int32, steps : Array(Step)) : {Int32, String?}
      j = from
      while j < p.size && p[j] != '.' && p[j] != '['
        return {j, "`]` without a matching `[` in #{p.inspect}"} if p[j] == ']'
        j += 1
      end
      name = p[from...j]
      return {j, "empty step in JSON path #{p.inspect}"} if name.empty?
      # A dotted name may hold anything but a wildcard: `:` or `?` in a key is just a key
      # (`urn:id`), while `a.*` can only mean "every member", which this does not do.
      if name.includes?('*')
        return {j, "wildcard `*` is not supported in JSON path #{p.inspect} — name the member, or quote it (a[\"k*\"])"}
      end
      idx = name.to_i32?(whitespace: false)
      steps << Step.new(key: name, index: idx)
      {j, nil}
    end

    # `[...]` starting at `p[from] == '['`.
    # Whitespace around a quoted name is allowed (`[ "k" ]`); a quote anywhere else inside an
    # unquoted `[...]` is refused rather than read as part of a name.
    private def bracket(p : String, from : Int32, steps : Array(Step)) : {Int32, String?}
      open = from + 1
      while p[open]?.try(&.whitespace?)
        open += 1
      end
      q = p[open]?
      return quoted(p, open, q, steps) if q && (q == '"' || q == '\'')
      close = p.index(']', from + 1)
      return {p.size, "unclosed `[` in JSON path #{p.inspect}"} unless close
      inner = p[(from + 1)...close].strip
      return {close + 1, "empty `[]` in JSON path #{p.inspect}"} if inner.empty?
      if idx = inner.to_i32?
        steps << Step.new(index: idx)
      elsif bad = unsupported(inner)
        return {close + 1, "#{bad.inspect} inside `[...]` is not supported in JSON path #{p.inspect} — use an index or a quoted name (a[0], a[\"k\"])"}
      else
        return {close + 1, "`[` inside `[...]` in JSON path #{p.inspect}"} if inner.includes?('[')
        if inner.includes?('"') || inner.includes?('\'')
          return {close + 1, "a quote inside an unquoted `[...]` in JSON path #{p.inspect} — quote the whole name (a[\"k\"])"}
        end
        steps << Step.new(key: inner)
      end
      {close + 1, nil}
    end

    # `["name"]` / `['name']`, the quote `q` at `open`.
    private def quoted(p : String, open : Int32, q : Char, steps : Array(Step)) : {Int32, String?}
      close = p.index(q, open + 1)
      return {p.size, "unclosed quote in JSON path #{p.inspect}"} unless close
      after = close + 1
      while p[after]?.try(&.whitespace?)
        after += 1
      end
      return {p.size, "expected `]` after the quoted name in #{p.inspect}"} unless p[after]? == ']'
      steps << Step.new(key: p[(open + 1)...close])
      {after + 1, nil}
    end

    private def unsupported(s : String) : Char?
      s.each_char { |c| return c if UNSUPPORTED.includes?(c) }
      nil
    end
  end
end
