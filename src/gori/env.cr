require "json"
require "./settings"
require "./store"

module Gori
  # Global + per-project environment variables for `$KEY`-style substitution in
  # outbound requests (Replay, Fuzzer, Miner, Intercept, CLI, MCP). The editor
  # keeps the raw `$KEY` text; `expand` runs at send time only. Highlighting
  # reuses the same prefix/KEY rules via `token_regions`.
  module Env
    DEFAULT_PREFIX   = "$"
    PROJECT_VARS_KEY = "env.vars"
    KEY_HEAD         = /[A-Za-z_]/
    KEY_TAIL         = /[A-Za-z0-9_]/

    @@highlight_rev : UInt32 = 0

    def self.highlight_rev : UInt32
      @@highlight_rev
    end

    def self.bump_highlight_rev : Nil
      @@highlight_rev += 1
    end

    # Merged vars: global first, then project (project wins on KEY collision).
    def self.effective_vars : Hash(String, String)
      h = {} of String => String
      Settings.env_vars.each { |(k, v)| h[k] = v }
      Settings.project_env_vars.each { |(k, v)| h[k] = v }
      h
    end

    # Expand env tokens in wire-form HTTP text (LF or CRLF) and return CRLF bytes.
    def self.expand_wire(text : String, vars : Hash(String, String) = effective_vars,
                         prefix : String = Settings.env_prefix) : Bytes
      expand(text, vars, prefix).split('\n').join("\r\n").to_slice
    end

    # Substitute registered `prefix+KEY` tokens; unknown keys stay literal.
    def self.expand(text : String, vars : Hash(String, String) = effective_vars,
                    prefix : String = Settings.env_prefix) : String
      return text if prefix.empty?
      out = IO::Memory.new
      chars = text.chars
      n = chars.size
      plen = prefix.size
      prefix_chars = prefix.chars
      i = 0
      while i < n
        if i + plen <= n && prefix_chars.each_with_index.all? { |c, j| chars[i + j] == c }
          if parsed = read_key(chars, i + plen, n)
            key, consumed = parsed
            if val = vars[key]?
              out << val
              i += plen + consumed
            else
              out << prefix
              i += plen
            end
          else
            out << prefix
            i += plen
          end
        else
          out << chars[i]
          i += 1
        end
      end
      out.to_s
    end

    # Scans the text for occurrences of any registered env var value and replaces
    # it with the corresponding token (e.g. "$KEY"). Sorted by value size descending
    # to avoid sub-string collisions (e.g. matching "secret_value" before "secret").
    def self.mask_secrets(text : String, vars : Hash(String, String) = effective_vars,
                          prefix : String = Settings.env_prefix) : String
      return text if prefix.empty? || vars.empty?

      # Filter out empty values and short/common values that might lead to false positives (e.g., single characters)
      candidates = vars.to_a
        .reject { |(k, v)| v.strip.empty? || v.size < 4 }
        .sort_by { |(k, v)| -v.size }

      return text if candidates.empty?

      result = text
      candidates.each do |key, value|
        result = result.gsub(value, "#{prefix}#{key}")
      end
      result
    end

    # Byte offsets [start, end) of each env-shaped token in `text` (end exclusive).
    # `known` is true when KEY is registered in `vars`.
    def self.token_regions(text : String, prefix : String = Settings.env_prefix,
                           vars : Hash(String, String) = effective_vars) : Array({Int32, Int32, Bool})
      return [] of {Int32, Int32, Bool} if prefix.empty?
      regions = [] of {Int32, Int32, Bool}
      chars = text.chars
      n = chars.size
      plen = prefix.size
      prefix_chars = prefix.chars
      i = 0
      while i < n
        if i + plen <= n && prefix_chars.each_with_index.all? { |c, j| chars[i + j] == c }
          if parsed = read_key(chars, i + plen, n)
            key, consumed = parsed
            regions << {i, i + plen + consumed, vars.has_key?(key)}
            i += plen + consumed
          else
            i += plen
          end
        else
          i += 1
        end
      end
      regions
    end

    # Parse "KEY VALUE" or "KEY=value" (value may contain spaces when using the
    # space form). Returns nil when KEY is invalid.
    def self.parse_line(text : String) : {String, String}?
      raw = text.strip
      return nil if raw.empty?
      if eq = raw.index('=')
        key = raw[0...eq].strip
        val = raw[eq + 1..]
        return nil unless valid_key?(key)
        {key, val}
      else
        parts = raw.split(/\s+/, 2)
        return nil if parts.size < 2
        key = parts[0]
        return nil unless valid_key?(parts[0])
        {key, parts[1]}
      end
    end

    def self.parse_vars_json(raw : String?) : Array({String, String})
      return [] of {String, String} if raw.nil? || raw.strip.empty?
      arr = JSON.parse(raw).as_a?
      return [] of {String, String} unless arr
      out = [] of {String, String}
      arr.each do |e|
        next unless o = e.as_h?
        key = o["key"]?.try(&.as_s?)
        val = o["value"]?.try(&.as_s?)
        next if key.nil? || key.empty? || val.nil?
        next unless valid_key?(key)
        out << {key, val}
      end
      out
    end

    def self.serialize_vars(vars : Array({String, String})) : String
      JSON.build do |j|
        j.array do
          vars.each do |(key, val)|
            j.object do
              j.field "key", key
              j.field "value", val
            end
          end
        end
      end
    end

    def self.load_project(store : Store) : Nil
      Settings.project_env_vars = parse_vars_json(store.setting(PROJECT_VARS_KEY))
      bump_highlight_rev
    end

    def self.save_project(store : Store, vars : Array({String, String})) : Nil
      if vars.empty?
        store.delete_setting(PROJECT_VARS_KEY)
      else
        store.set_setting(PROJECT_VARS_KEY, serialize_vars(vars))
      end
      Settings.project_env_vars = vars.dup
      bump_highlight_rev
    end

    def self.valid_key?(key : String) : Bool
      return false if key.empty?
      return false unless KEY_HEAD.matches?(key[0].to_s)
      key.chars[1..].all? { |c| KEY_TAIL.matches?(c.to_s) }
    end

    private def self.read_key(chars : Array(Char), start : Int32, n : Int32) : {String, Int32}?
      return nil if start >= n || !KEY_HEAD.matches?(chars[start].to_s)
      j = start + 1
      while j < n && KEY_TAIL.matches?(chars[j].to_s)
        j += 1
      end
      {chars[start...j].join, j - start}
    end
  end
end
