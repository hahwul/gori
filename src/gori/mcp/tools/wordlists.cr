require "json"
require "../../wordlist_catalog"

module Gori
  module MCP
    class Tools
      # Most values one `save_wordlist` call may carry, and their total bytes. The list
      # arrives inside a JSON-RPC message the agent's own context paid for, so neither bound
      # is a real limit on what an operator can keep (`gori run wordlist save --from FILE`
      # has none) — it is what keeps one call from stalling this single-threaded server.
      WORDLIST_SAVE_VALUES_MAX = 1_000_000
      WORDLIST_SAVE_BYTES_MAX  = 32 * 1024 * 1024

      # `get_wordlist`'s value preview: opt-in, and bounded however long the lines are.
      WORDLIST_PREVIEW_DEFAULT =  20
      WORDLIST_PREVIEW_MAX     = 200

      # The global wordlist catalog (#1353): named lists under `$GORI_HOME/wordlists`. They
      # are GLOBAL, not project data, so every tool here is `unbound` (a server with no
      # project bound can still list and save) and the writes sit in the `write` group with the
      # other records an operator lets an agent keep.
      #
      # A listing and `get_wordlist` answer from `stat` and a bounded line count and never
      # return a VALUE unless `include_values:true` is passed: a list can be a credential list,
      # or values lifted from a capture, and "what lists do I have" is not a reason to put
      # them in an agent's context.
      @[Tool("list_wordlists", unbound: true)]
      private def list_wordlists(h) : Result
        limit = clamp(optional_int_arg(h, "limit"), 200, WordlistCatalog::LIST_MAX)
        listing = WordlistCatalog.list(limit)
        Result.new(JSON.build do |j|
          j.object do
            j.field "directory", Paths.wordlists_dir
            j.field "wordlists" do
              j.array { listing.entries.each { |e| j.object { wordlist_entry_fields(j, e) } } }
            end
            j.field "returned", listing.entries.size
            j.field "truncated", listing.truncated
          end
        end)
      end

      @[Tool("get_wordlist", unbound: true)]
      private def get_wordlist(h) : Result
        name = wordlist_name_arg(h, "name") || return wordlist_name_missing("name")
        include_values = bool_arg(h, "include_values", false)
        max_lines = clamp(optional_int_arg(h, "max_lines"), WORDLIST_PREVIEW_DEFAULT, WORDLIST_PREVIEW_MAX)
        info, preview = begin
          i = WordlistCatalog.info(name)
          {i, include_values ? WordlistCatalog.preview(name, max_lines) : nil}
        rescue ex : WordlistCatalog::Error
          return wordlist_refusal(ex)
        end
        Result.new(JSON.build do |j|
          j.object do
            wordlist_entry_fields(j, info.entry)
            j.field "path", info.entry.path
            j.field "lines", info.lines
            j.field "lines_complete", info.lines_complete
            if pv = preview
              # A value is BYTES; JSON is text. A line that is not valid UTF-8 is scrubbed here,
              # and only here, and the count says how many were.
              scrubbed = pv.lines.count { |l| !l.valid_encoding? }
              j.field "preview", pv.lines.map(&.scrub)
              j.field "preview_truncated", pv.truncated
              j.field "preview_scrubbed_lines", scrubbed if scrubbed > 0
            end
          end
        end)
      end

      # `values` is taken as an ARRAY of strings and nothing else: a bare string that happens
      # to look like JSON (`[1,2]`, a real payload) must not be parsed into other values, which
      # is the leniency `str_list` gives an argument where that is the point. A scalar in an
      # entry is coerced and a container refused (`str_entry`), and a value with a line break
      # is refused by the catalog rather than split into two.
      #
      # `payload_from` is the other source (#1352): values read out of the BOUND project's
      # captured data (`'<QL> <projection>'`, the same descriptor `fuzz_start` takes), saved as a
      # global list. It is an explicit act on both ends — the project is the one this server is
      # bound to, and credential material stays out unless `include_sensitive` says otherwise —
      # and the reply carries the source's report. A value that cannot be one line of the file (it
      # holds a line break) is left out and COUNTED, since the format cannot carry it.
      @[Tool("save_wordlist", gated: true, agent_action: true, unbound: true, permission: "write")]
      private def save_wordlist(h) : Result
        name = wordlist_name_arg(h, "name") || return wordlist_name_missing("name")
        overwrite = bool_arg(h, "overwrite", false)
        source = wordlist_save_source(h)
        return source if source.is_a?(Result)
        values, report, skipped = source
        replaced = !WordlistCatalog.entry(name).nil?
        entry = begin
          WordlistCatalog.save_values(name, values, overwrite: overwrite)
        rescue ex : WordlistCatalog::Error
          return wordlist_refusal(ex, overwrite_arg: true)
        end
        Result.new(JSON.build do |j|
          j.object do
            wordlist_entry_fields(j, entry)
            j.field "path", entry.path
            j.field "values", values.size
            j.field "replaced", replaced && overwrite
            if r = report
              j.field "payload_source" do
                payload_report_json(j, r)
              end
              j.field("skipped_line_break", skipped) if skipped > 0
            end
            j.field "message", "Wordlist saved. Pass name #{entry.name.to_json} as `wordlist` to fuzz_start, " \
                               "mine_start or discover_start."
          end
        end)
      end

      # The values to save and where they came from: the `values` array, or the bound project's
      # captured data read through `payload_from`, or the refusal. `{values, report, skipped}` —
      # the report is the source's when it was `payload_from`, and `skipped` counts the values a
      # one-value-per-line file cannot carry (they hold a line break).
      private def wordlist_save_source(h) : {Array(String), PayloadFrom::Report?, Int32} | Result
        desc = str(h, "payload_from").try(&.presence)
        values = wordlist_values_arg(h)
        if desc && values
          return err("pass 'values' or 'payload_from', not both", "INVALID_ARGUMENT", field: "payload_from")
        end
        return {values, nil, 0} if values
        unless desc
          return err("missing required 'values' (or 'payload_from')", "INVALID_ARGUMENT", field: "values")
        end
        return no_project if unbound?
        spec = payload_spec_arg(desc, "payload_from").apply(payload_policy_arg(h))
        resolved = begin
          PayloadFrom.resolve(store, spec)
        rescue ex : PayloadFrom::Error
          return err(ex.message || "payload_from failed", "INVALID_ARGUMENT", field: "payload_from")
        end
        lines, skipped = WordlistCatalog.one_per_line(resolved.values)
        {lines, resolved.report, skipped}
      end

      @[Tool("rename_wordlist", gated: true, agent_action: true, unbound: true, permission: "write")]
      private def rename_wordlist(h) : Result
        from = wordlist_name_arg(h, "name") || return wordlist_name_missing("name")
        to = wordlist_name_arg(h, "new_name") || return wordlist_name_missing("new_name")
        overwrite = bool_arg(h, "overwrite", false)
        entry = begin
          WordlistCatalog.rename(from, to, overwrite: overwrite)
        rescue ex : WordlistCatalog::Error
          return wordlist_refusal(ex, overwrite_arg: true)
        end
        Result.new(JSON.build do |j|
          j.object do
            wordlist_entry_fields(j, entry)
            j.field "path", entry.path
            j.field "renamed_from", from
          end
        end)
      end

      # `confirm:true` is the gate, as it is on `clear_history`: a list is a file outside any
      # project, and a deleted one is gone. Without it the call says what it would remove.
      @[Tool("delete_wordlist", gated: true, agent_action: true, unbound: true, permission: "write")]
      private def delete_wordlist(h) : Result
        name = wordlist_name_arg(h, "name") || return wordlist_name_missing("name")
        entry = begin
          WordlistCatalog.check_name!(name)
          WordlistCatalog.entry(name) || raise WordlistCatalog::Error.new(
            WordlistCatalog::Error::Reason::NotFound, "no wordlist named #{name.inspect} in #{Paths.wordlists_dir}", name)
        rescue ex : WordlistCatalog::Error
          return wordlist_refusal(ex)
        end
        unless bool_arg(h, "confirm", false)
          return err("refusing to delete wordlist #{name.inspect} (#{entry.bytes} bytes) without confirm:true — " \
                     "this cannot be undone",
            "CONFIRM_REQUIRED", field: "confirm",
            details: JSON.parse({"name" => name, "bytes" => entry.bytes}.to_json))
        end
        begin
          WordlistCatalog.delete(name)
        rescue ex : WordlistCatalog::Error
          return wordlist_refusal(ex)
        end
        Result.new({"deleted" => name}.to_json)
      end

      # The one row shape every tool above uses, written into an object the caller opened.
      private def wordlist_entry_fields(j : JSON::Builder, e : WordlistCatalog::Entry) : Nil
        j.field "name", e.name
        j.field "bytes", e.bytes
        j.field "modified_at", Serialize.unix_micros_iso(e.modified.to_unix_ms * 1000)
        j.field "symlink", e.symlink
      end

      # The name as given — exactly, never trimmed: a catalog name cannot begin or end with
      # a space, and quietly trimming one would make `" x"` resolve where the CLI refuses it.
      private def wordlist_name_arg(h, key : String) : String?
        v = str(h, key)
        return nil if v.nil? || v.empty?
        v
      end

      private def wordlist_name_missing(key : String) : Result
        err("missing required '#{key}'", "INVALID_ARGUMENT", field: key)
      end

      private def wordlist_values_arg(h) : Array(String)?
        raw = h["values"]?
        return nil if raw.nil? || raw.raw.nil?
        arr = raw.as_a? || raise Gori::Error.new("invalid 'values' (expected an array of strings, one per line)")
        if arr.size > WORDLIST_SAVE_VALUES_MAX
          raise Gori::Error.new("too many 'values' (#{arr.size}; at most #{WORDLIST_SAVE_VALUES_MAX} per call — " \
                                "`gori run wordlist save --from FILE` has no such limit)")
        end
        bytes = 0
        arr.map do |v|
          s = str_entry(v, "values")
          bytes += s.bytesize + 1
          if bytes > WORDLIST_SAVE_BYTES_MAX
            raise Gori::Error.new("'values' is too large (over #{WORDLIST_SAVE_BYTES_MAX // (1024 * 1024)} MiB per call — " \
                                  "`gori run wordlist save --from FILE` has no such limit)")
          end
          s
        end
      end

      # A catalog refusal as this surface's error. The catalog wrote the sentence; the code is
      # the only part that is MCP's.
      private def wordlist_refusal(ex : WordlistCatalog::Error, overwrite_arg : Bool = false) : Result
        field = case ex.reason
                in .invalid_name?          then "name"
                in .bad_value?, .empty?    then "values"
                in .exists?, .not_regular? then "name"
                in .not_found?, .io?       then nil
                end
        code = case ex.reason
               in .not_found?                                                   then "NOT_FOUND"
               in .io?                                                          then "INTERNAL"
               in .invalid_name?, .exists?, .not_regular?, .bad_value?, .empty? then "INVALID_ARGUMENT"
               end
        hint = overwrite_arg && ex.reason.exists? ? " Pass overwrite:true to replace it." : ""
        err("#{ex.message}#{hint}", code, field: field)
      end

      private def list_wordlists_tools(j : JSON::Builder) : Nil
        tool j, "list_wordlists",
          "List the global wordlist catalog (named lists under GORI_HOME/wordlists): name, size, modified time. " \
          "Never returns values. Use a name as `wordlist` in fuzz_start, mine_start or discover_start; " \
          "a name is looked up in the server's working directory first, then here." do |s|
          s.field "limit", intprop("max lists to return (default 200)")
        end

        tool j, "get_wordlist",
          "One catalog list's metadata: path, bytes and a line count (bounded — `lines_complete:false` means " \
          "more). Values are returned only with include_values:true, and may be sensitive." do |s|
          s.field "name", strprop("catalog list name"), required: true
          s.field "include_values", boolprop("also return the first lines (default false)")
          s.field "max_lines", intprop("lines to return with include_values (default #{WORDLIST_PREVIEW_DEFAULT}, max #{WORDLIST_PREVIEW_MAX})")
        end

        return unless @allow_actions

        tool j, "save_wordlist",
          "Save a list in the global catalog, one value per line exactly as given (a blank or `#` line stays a " \
          "payload), from `values` or from the bound project's data with `payload_from`. Atomic and owner-only; " \
          "refuses to replace an existing list unless overwrite:true. A value cannot contain a line break." do |s|
          s.field "name", strprop("catalog name: letters, digits, _ . + - and inner spaces; not a path"), required: true
          s.field "values", strarrprop("the values, one per line (or use payload_from)")
          s.field "payload_from", strprop("instead of values: read them from the bound project's captured data, '<QL> <projection>' " \
                                          "(param-names | param-values | path-segments | js-endpoints | extracted; e.g. 'host:api.example param-names'). " \
                                          "Credential material stays out unless include_sensitive; values with a line break are left out and counted")
          s.field "include_sensitive", boolprop("with payload_from: also save credential material (default false; `extracted` needs it)")
          s.field "locations", strprop("with payload_from: comma list of query,form,multipart,json,headers,cookies (default query,form,multipart,json)")
          s.field "max_flows", intprop("with payload_from: newest flows read (default #{PayloadFrom::DEFAULT_MAX_FLOWS}, max #{PayloadFrom::MAX_FLOWS})")
          s.field "max_values", intprop("with payload_from: distinct values kept (default #{PayloadFrom::DEFAULT_MAX_VALUES}, max #{PayloadFrom::MAX_VALUES})")
          s.field "overwrite", boolprop("replace a list of that name (default false)")
        end

        tool j, "rename_wordlist",
          "Rename a catalog list. Refuses to replace an existing list unless overwrite:true." do |s|
          s.field "name", strprop("current catalog name"), required: true
          s.field "new_name", strprop("new catalog name"), required: true
          s.field "overwrite", boolprop("replace a list already named new_name (default false)")
        end

        tool j, "delete_wordlist",
          "Delete a catalog list. Requires confirm:true — without it the call is refused and reports what it " \
          "would have removed. This cannot be undone." do |s|
          s.field "name", strprop("catalog list name"), required: true
          s.field "confirm", boolprop("must be true to actually delete; anything else refuses"), required: true
        end
      end
    end
  end
end
