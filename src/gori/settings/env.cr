require "json"
require "socket"
require "../dial_address"

# ENV section: global hostname overrides (a process-wide /etc/hosts) and the
# `$KEY`-substitution env vars (global + a per-project runtime-only layer). See
# settings.cr for the module-level overview and the load/save/serialize orchestration.
module Gori::Settings
  DEFAULT_ENV_PREFIX = "$"

  # The grammar an install reads and writes tokens in. See `Gori::Env::Syntax`.
  #
  # NAMESPACED is the grammar for everyone (`$ENV.KEY` / `$BIND.NAME`). `bare` stays as an
  # explicit opt-out, and it is explicit in the file too: `env.syntax` is ALWAYS serialized, both
  # values, because the ABSENCE of the key no longer means bare — it means this settings.json
  # PREDATES namespaces, and that is a migration to run rather than a grammar to keep (see
  # `adopt_env_syntax_for_absent_key`).
  DEFAULT_ENV_SYNTAX = Env::Syntax::Namespaced

  # What gori READS tokens as when `env.syntax` is there and says nothing gori understands — a
  # typo, a `null`, a number, a list. NOT `DEFAULT_ENV_SYNTAX`: the default is the answer for a
  # file that PREDATES namespaces, which is a date gori can act on (adopt, re-spell, write the key
  # down). A value nobody can read is the opposite — it is the one state where gori knows it does
  # not know, so it reads tokens the way the install's stored bytes are most likely to be spelled
  # and rewrites nothing (`env_syntax_origin = Unreadable`). Bare is that reading for the same
  # reason `EnvMigration.stored_syntax` picks it: it is the answer a wrong guess cannot lose data
  # over, and it is what the unreadable-FILE sibling (`adopt_env_syntax_for_absent_key`) already
  # picks for a settings.json gori could not read a byte of.
  UNREADABLE_ENV_SYNTAX = Env::Syntax::Bare

  # What the ABSENCE of `env.syntax` resolves to. A class_property so the suite can pin it: every
  # spec home is a fresh one with no settings file, and without the pin ~1,000 bare `$TOKEN`
  # fixtures would be read under the other grammar — and migrated on their way past.
  class_property env_syntax_when_absent : Env::Syntax = DEFAULT_ENV_SYNTAX

  # Whether a long-lived process may RE-READ `env.syntax` off the file mid-run and adopt it
  # (`EnvMigration.follow_disk`). True in production, which is the whole point: a TUI session and a
  # `gori mcp` server both live for hours and must follow a `gori settings env-syntax` run.
  #
  # A class_property so the SUITE can pin it. `with_env_syntax` sets the grammar in memory, over a
  # temp home whose settings.json says something else entirely (or nothing) — and a seam that
  # dutifully adopted the file's answer there would be fighting the pin rather than following a
  # peer. The examples that exercise the seam write a real file and leave this alone.
  class_property? env_syntax_follow_disk : Bool = true

  # WHERE the grammar in memory came from, which decides whether gori may act on it. A migration
  # rewrites stored bytes, so it may only run when this install's grammar is something the
  # install actually SAID — never over a value gori guessed because a file could not be read
  # (see `env_syntax_stated?`).
  enum EnvSyntaxOrigin
    # No `env.syntax` key on a file that was read in full (or no file at all): this home predates
    # namespaces, so the stored tokens are bare and the grammar is adopted + written.
    Absent
    # A readable grammar, from the file or recovered textually from a torn one.
    Stated
    # The key is there and names no grammar gori knows (`"NAMESPACED!"`, `null`, `1`), or the
    # file could not be read at all. A guess, and nothing may be rewritten against a guess.
    Unreadable
  end

  @@env_syntax_origin : EnvSyntaxOrigin = EnvSyntaxOrigin::Absent

  def self.env_syntax_origin : EnvSyntaxOrigin
    @@env_syntax_origin
  end

  protected def self.env_syntax_origin=(o : EnvSyntaxOrigin) : EnvSyntaxOrigin
    @@env_syntax_origin = o
  end

  # May gori rewrite stored tokens against the grammar in memory? True when the install SAID it
  # (or when the absence rule settled it over a file that was read in full), false over a guess:
  # an unreadable settings.json, a half-applied one, a value that names no grammar. A project
  # database whose marker disagrees with a GUESS must be left exactly as it is — re-spelling it
  # would be a permissions problem or a typo rewriting an operator's drafts.
  def self.env_syntax_stated? : Bool
    !@@env_syntax_origin.unreadable? && !load_degraded?
  end

  @@env_syntax : Env::Syntax = DEFAULT_ENV_SYNTAX

  def self.env_syntax : Env::Syntax
    @@env_syntax
  end

  # Bumps the highlight revision like every other env write: a `TextArea`'s styled buffer, the
  # `Highlight` span caches and `Rules#subst_snapshot` are all keyed on it, and the SPELLING of
  # every token in every open editor just changed.
  def self.env_syntax=(s : Env::Syntax) : Env::Syntax
    @@env_syntax = s
    Env.bump_highlight_rev
    s
  end

  # Adopt a grammar this install STATED, read back off settings.json by a long-lived process whose
  # in-memory copy went stale under it — see `EnvMigration.follow_disk`.
  #
  # The ORIGIN moves with the value, and that is the whole reason this is not a plain assignment: a
  # value that came out of a parsed `env.syntax` is exactly what `env_syntax_stated?` asks about,
  # and leaving the origin at this run's `Absent`/`Unreadable` would let the grammar change while
  # the re-spelling that has to accompany it stayed refused.
  def self.adopt_stated_env_syntax(s : Env::Syntax) : Nil
    self.env_syntax = s
    self.env_syntax_origin = EnvSyntaxOrigin::Stated
  end

  # Global hostname overrides (a process-wide /etc/hosts): ordered {host (lowercased),
  # ip} pairs. Read LIVE by Upstream.dial (edits apply on the next flow); layered
  # UNDER each project's own HostOverrides, which wins on a host collision. Edited via
  # settings:network (the HostsOverlay).
  class_property hostname_overrides : Array({String, String}) = [] of {String, String}
  class_property env_prefix : String = DEFAULT_ENV_PREFIX
  class_property env_vars : Array({String, String}) = [] of {String, String}
  class_property project_env_vars : Array({String, String}) = [] of {String, String}

  # `syntax` is assigned ONLY when the key is present, and the "an absent key means this file
  # predates namespaces" rule lives in `Settings.load` instead. That split is not cosmetic:
  # `import_document` reuses `apply_sections` over a FILTERED document, so a theme-only profile
  # import reaches this method with no `env` node at all — and an install would have its grammar
  # re-derived (and its projects re-spelled) by an import that never mentioned env. An unknown
  # value is a bad file rather than a new grammar: say so, read tokens as the default, and mark
  # the origin `Unreadable` so nothing gets REWRITTEN against a value gori had to guess.
  private def self.parse_env(node : JSON::Any?) : Nil
    return unless e = node.try(&.as_h?)
    if pref = e["prefix"]?.try(&.as_s?)
      self.env_prefix = pref.empty? ? Env::DEFAULT_PREFIX : pref
    end
    if node = e["syntax"]?
      # PRESENT but not a string (`null`, `1`, `["namespaced"]`) is the typo path, not the
      # absence path. `as_s?` alone would have skipped the assignment altogether and left
      # whatever grammar was in memory — the PREVIOUS home's, since `load` runs repeatedly over
      # different homes in one process — while `Settings.load`'s absence guard read the key as
      # present and declined to correct it. Say so and stay bare, exactly like an unknown value.
      if raw = node.as_s?
        if s = Env::Syntax.parse?(raw.strip)
          self.env_syntax = s
          self.env_syntax_origin = EnvSyntaxOrigin::Stated
        else
          self.env_syntax = UNREADABLE_ENV_SYNTAX
          self.env_syntax_origin = EnvSyntaxOrigin::Unreadable
          note_load_warning("settings: env.syntax #{raw.inspect} is not one of " \
                            "#{Env::Syntax.values.join('/', &.to_s.downcase)} — reading tokens as " \
                            "#{UNREADABLE_ENV_SYNTAX.to_s.downcase} for this run, and re-spelling " \
                            "nothing until the value is fixed")
        end
      else
        self.env_syntax = UNREADABLE_ENV_SYNTAX
        self.env_syntax_origin = EnvSyntaxOrigin::Unreadable
        note_load_warning("settings: env.syntax must be a string (got #{node.to_json}) — reading " \
                          "tokens as #{UNREADABLE_ENV_SYNTAX.to_s.downcase} for this run, and " \
                          "re-spelling nothing until the value is fixed")
      end
    end
    # `vars` follows the same rule as `syntax`: assigned ONLY when the key is PRESENT. An absent
    # key is not an empty table — `export_document` strips `syntax` out of an exported `env`
    # section, so a profile taken from a var-less install carries the literal document `{"env":{}}`,
    # and a reader that treated that as "no vars" emptied the IMPORTER's global env var table (its
    # token VALUES included) over a profile that said nothing about vars at all. `{"vars": []}` is
    # still how a profile says "no vars", the same wholesale-replace rule every list section has.
    self.env_vars = parse_env_vars(e["vars"]?) if e.has_key?("vars")
  end

  # Recover the token grammar from a settings file that would not PARSE, textually.
  #
  # The parse failure is somewhere in a file that is mostly rule tables and theme scalars, while
  # the env section is three keys — so a torn or hand-mangled settings.json very often still
  # carries `"syntax": "namespaced"` verbatim. Reading it back matters more than it looks: the
  # unparseable path leaves every section at a factory default but `save` stays ARMED, and
  # `serialize_env` then omits the section entirely — which the next start reads as "no syntax
  # key", i.e. bare, forever. A namespaced install would have downgraded itself, silently, in
  # the one direction that reinterprets every `$ENV.KEY` already stored in its projects as
  # literal bytes.
  #
  # Assigns the grammar either way (`load` runs over different homes in one process, so no exit
  # path may leave the previous home's value in memory) and returns the sentence the corrupt-file
  # warning appends, or nil when the grammar was recovered and there is nothing to warn about.
  # TEXTUAL on purpose: the JSON is by definition not available, and the value set is closed.
  private def self.recover_env_syntax_from_corrupt(raw : String) : String?
    self.env_syntax = DEFAULT_ENV_SYNTAX
    # A torn file is not a file that predates namespaces, whatever the regex finds: nothing may be
    # rewritten against it until it parses again. Recovered or not, the origin says `Unreadable`.
    self.env_syntax_origin = EnvSyntaxOrigin::Unreadable
    values = Env::Syntax.values.join('|', &.to_s.downcase)
    if m = raw.match(/"syntax"\s*:\s*"(#{values})"/)
      if s = Env::Syntax.parse?(m[1])
        self.env_syntax = s
        return nil
      end
    end
    "gori could not read which token grammar this install speaks and is reading tokens as " \
    "#{DEFAULT_ENV_SYNTAX.to_s.downcase} — `gori settings env-syntax` restores it"
  end

  private def self.parse_env_vars(node : JSON::Any?) : Array({String, String})
    arr = node.try(&.as_a?)
    return [] of {String, String} unless arr
    out = [] of {String, String}
    arr.each do |entry|
      next unless o = entry.as_h?
      key = o["key"]?.try(&.as_s?)
      val = o["value"]?.try(&.as_s?)
      next if key.nil? || key.empty? || val.nil?
      next unless valid_env_key?(key)
      out << {key, val}
    end
    out
  end

  private def self.valid_env_key?(key : String) : Bool
    !key.empty? && key.matches?(/\A[A-Za-z_][A-Za-z0-9_]*\z/)
  end

  # Tolerant hostname-override parse: a non-array (or absent) node keeps the current
  # value; entries missing/blank "host" or "ip" are dropped. The host is lowercased so
  # the live lookup (host_override_address) and the project store stay consistent. Mirrors
  # parse_decoder_chains' robustness.
  private def self.parse_hostname_overrides(node : JSON::Any?) : Array({String, String})
    arr = node.try(&.as_a?)
    return hostname_overrides unless arr
    out = [] of {String, String}
    arr.each do |e|
      next unless o = e.as_h?
      host = o["host"]?.try(&.as_s?)
      ip = o["ip"]?.try(&.as_s?)
      next if host.nil? || host.empty? || ip.nil? || ip.empty?
      next unless Gori::DialAddress.valid?(ip) # defense-in-depth: a hand-edited non-literal "ip" would re-resolve via DNS
      key = Gori::OverrideHost.key(host)
      next if key.empty? # a hand-edited "." folds to nothing and could never match a request
      out << {key, ip}
    end
    out
  end

  # Factory reset for these two sections (dispatched by Settings.reset_to_factory). Both
  # hold operator DATA rather than preferences, so a factory reset really does drop the
  # hostname map and every global env var — token values included. That is why the only
  # surface offering it puts it behind a confirm that names them.
  private def self.reset_hostname_overrides : Nil
    self.hostname_overrides = [] of {String, String}
  end

  # `env_syntax` is deliberately NOT reset. It is not a preference: it decides how the tokens
  # already stored in PROJECT DATABASES — env var names, Repeater drafts, rewrite-rule
  # replacements, slot headers — are read, and a settings reset does not speak for those. Resetting
  # it would silently reinterpret every one of them (the same argument that keeps `project_env_vars`
  # and the `cli_*` overlay out of a factory reset).
  private def self.reset_env : Nil
    self.env_vars = [] of {String, String}
    self.env_prefix = DEFAULT_ENV_PREFIX
  end

  # Omit when empty so an untouched install never writes "hostname_overrides": [].
  private def self.serialize_hostname_overrides(j : JSON::Builder) : Nil
    unless hostname_overrides.empty?
      j.field "hostname_overrides" do
        j.array do
          hostname_overrides.each { |(host, ip)| j.object { j.field "host", host; j.field "ip", ip } }
        end
      end
    end
  end

  # ALWAYS written, both values, which is why the `env` section is never omitted any more.
  #
  # The absence of `env.syntax` is no longer a value: it means the file predates namespaces, and
  # the next load treats it as a MIGRATION to run (`adopt_env_syntax_for_absent_key`). So a
  # grammar that is not written down is a grammar that gets re-derived — and for the `bare`
  # opt-out that would mean the opt-out is overwritten on the very next start.
  #
  # This is also what lets `load` stay a READ. It adopts the absent grammar in memory and saves
  # only when the global-rule re-spelling actually changed the file's bytes; the key itself rides
  # out on the next save this install makes for any other reason, because that save always emits
  # it. Re-deriving the same answer from the same absence until then is free.
  #
  # An EXPORT still carries no grammar: `strip_env_syntax` drops the key from an exported
  # document (settings.cr), because a teammate's profile does not speak for how the tokens in
  # THIS install's projects are read.
  private def self.serialize_env(j : JSON::Builder) : Nil
    j.field "env" do
      j.object do
        j.field "syntax", env_syntax.to_s.downcase
        j.field "prefix", env_prefix unless env_prefix == DEFAULT_ENV_PREFIX
        unless env_vars.empty?
          j.field "vars" do
            j.array do
              env_vars.each { |(key, val)| j.object { j.field "key", key; j.field "value", val } }
            end
          end
        end
      end
    end
  end

  # The global override ADDRESS to dial for `host` (exact match on the `Gori::OverrideHost`
  # key, so case and a trailing root dot don't decide it), or nil when no global override
  # applies. May carry a port (`Gori::DialAddress`). Read LIVE by Upstream.dial, so settings
  # edits take effect on the next flow. A project-level HostOverrides entry is consulted
  # FIRST and wins on a collision — ask both through `Proxy::Upstream.override_address`
  # rather than open-coding the pair.
  def self.host_override_address(host : String) : String?
    return nil if hostname_overrides.empty?
    h = Gori::OverrideHost.key(host)
    hostname_overrides.each { |(oh, ip)| return ip if oh == h }
    nil
  end
end
