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
  # The DEFAULT is bare and is what the ABSENCE of `env.syntax` means, forever: the tokens an
  # existing install has are already written into project DBs, Repeater drafts, rewrite-rule
  # replacements and slot headers, and gori does not rewrite those behind the operator. The
  # absence rule is enforced in `Settings.load` and deliberately NOT in `parse_env` — see there.
  DEFAULT_ENV_SYNTAX = Env::Syntax::Bare

  # What a genuinely NEW home adopts (`adopt_env_syntax_for_new_home`). A class_property so the
  # suite can pin it: every spec home is new, and without the pin ~1,000 bare `$TOKEN` fixtures
  # would be read under the other grammar.
  NEW_INSTALL_ENV_SYNTAX = Env::Syntax::Namespaced

  class_property new_install_env_syntax : Env::Syntax = NEW_INSTALL_ENV_SYNTAX
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

  # Global hostname overrides (a process-wide /etc/hosts): ordered {host (lowercased),
  # ip} pairs. Read LIVE by Upstream.dial (edits apply on the next flow); layered
  # UNDER each project's own HostOverrides, which wins on a host collision. Edited via
  # settings:network (the HostsOverlay).
  class_property hostname_overrides : Array({String, String}) = [] of {String, String}
  class_property env_prefix : String = DEFAULT_ENV_PREFIX
  class_property env_vars : Array({String, String}) = [] of {String, String}
  class_property project_env_vars : Array({String, String}) = [] of {String, String}

  # `syntax` is assigned ONLY when the key is present, and the "absence means bare" rule lives in
  # `Settings.load` instead. That split is not cosmetic: `import_document` reuses `apply_sections`
  # over a FILTERED document, so a theme-only profile import reaches this method with no `env`
  # node at all — and a namespaced install would be flipped back to bare by an import that never
  # mentioned env. An unknown value is a bad file rather than a new grammar: say so and stay bare.
  private def self.parse_env(node : JSON::Any?) : Nil
    return unless e = node.try(&.as_h?)
    if pref = e["prefix"]?.try(&.as_s?)
      self.env_prefix = pref.empty? ? Env::DEFAULT_PREFIX : pref
    end
    if raw = e["syntax"]?.try(&.as_s?)
      if s = Env::Syntax.parse?(raw.strip)
        self.env_syntax = s
      else
        self.env_syntax = DEFAULT_ENV_SYNTAX
        note_load_warning("settings: env.syntax #{raw.inspect} is not one of " \
                          "#{Env::Syntax.values.join('/', &.to_s.downcase)} — reading tokens as " \
                          "#{DEFAULT_ENV_SYNTAX.to_s.downcase} for this run")
      end
    end
    self.env_vars = parse_env_vars(e["vars"]?)
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

  # Omitted only when there is NOTHING to say — no vars, the default prefix AND the default
  # grammar — so an untouched bare install still writes no `env` section at all and its
  # settings.json diff stays empty. Once the section exists the grammar is ALWAYS written: a file
  # that says `"vars"` but not `"syntax"` means bare by the absence rule, so a namespaced install
  # omitting the key would silently downgrade itself on the next load.
  private def self.serialize_env(j : JSON::Builder) : Nil
    unless env_vars.empty? && env_prefix == DEFAULT_ENV_PREFIX && env_syntax == DEFAULT_ENV_SYNTAX
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
