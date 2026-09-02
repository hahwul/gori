require "json"

module Gori
  # Message catalogs for the TUI: English, plus every language under `i18n/locales/`.
  #
  # msgid-style — the English string written in code IS the key, so a call reads as the text
  # it draws and English needs no catalog at all:
  #
  #     I18n.ui("History")                           # a label
  #     I18n.sys("sent → %{host}", host: h)           # a toast, with a placeholder
  #     I18n.ui_n(n, "%{n} flow", "%{n} flows", n: n) # a count
  #
  # Translation happens where text is DRAWN, never where a table is built: the verb registry,
  # the Help sections and the settings fields stay English in memory, and a live language
  # switch is a repaint. `revision` exists for the few caches that bake rendered text; they
  # compare it the way colour-baking caches compare `Theme.revision`.
  #
  # Four DOMAINS, each with its own language. The operator who wants English labels (to match
  # the docs and their muscle memory) can still read Help, the toasts, or Miss Ring in Korean,
  # or the other way around. `Settings` stores the choice (settings/language.cr); the TUI is
  # the only surface that installs it (`Tui.apply_language`), so `gori run` and `gori mcp`
  # never read a catalog and their output stays English whatever the operator picked. This
  # module never requires Settings, and nothing on the render path raises: an entry that is
  # missing falls back to the msgid, a placeholder the caller did not pass falls back to the
  # English template.
  module I18n
    enum Domain
      Ui        # chrome: labels, menus, key legends, titles
      Help      # explanatory prose: the Help tab, field hints, the tutorial, wizard copy
      System    # what happened: toasts, notifications, confirm bodies, errors
      Companion # Miss Ring speaking for herself

      # The catalog and settings key: "ui", "help", "system", "companion".
      def key : String
        to_s.downcase
      end
    end

    record Language, code : String, endonym : String

    # Every language gori speaks. Adding one is one row here plus `locales/<code>.json`:
    # Settings derives its allowed values from this list and the wizard offers what is here.
    # Endonyms are what a picker shows for a language and are never translated.
    LANGUAGES = [
      Language.new("en", "English"),
      Language.new("ko", "한국어"),
    ]
    DEFAULT_CODE = "en"
    # Settings-level sentinel: follow the process locale (see `resolve_auto`).
    AUTO = "auto"
    # Per-domain sentinel: follow the default language.
    INHERIT = "inherit"

    # code → the embedded catalog. `read_file` takes a compile-time string; "#{__DIR__}/…"
    # resolves against THIS source file, the way `Fuzz::Presets` embeds its payload sets.
    # English is the identity locale and has no file. The seam spec (spec/i18n_catalog_spec.cr)
    # holds this table to `LANGUAGES`.
    CATALOG_RAW = {
      "ko" => {{ read_file("#{__DIR__}/i18n/locales/ko.json") }},
    }

    def self.codes : Array(String)
      LANGUAGES.map(&.code)
    end

    def self.known?(code : String) : Bool
      LANGUAGES.any? { |l| l.code == code }
    end

    # The language's own name for itself, or the code itself when unknown.
    def self.endonym(code : String) : String
      LANGUAGES.find { |l| l.code == code }.try(&.endonym) || code
    end

    # --- state -------------------------------------------------------------------------

    @@default : String = DEFAULT_CODE
    # The resolved language per domain, indexed by Domain#value.
    @@locales = Array(String).new(Domain.values.size, DEFAULT_CODE)
    # That domain's catalog slice; nil is English, and nil is the fast path — `t` returns the
    # msgid after one array index and one nil check, with no hash lookup at all.
    @@slices = Array(Hash(String, String)?).new(Domain.values.size, nil)
    # code → domain key → msgid → text, parsed from CATALOG_RAW on first use.
    @@parsed = {} of String => Hash(String, Hash(String, String))
    @@revision : UInt32 = 0_u32
    # Spec seam: while non-nil, every lookup that fell back to its msgid is recorded here.
    @@missing : Set(String)? = nil

    # Bumped whenever a domain's resolved language changes.
    def self.revision : UInt32
      @@revision
    end

    # The resolved default — what `auto` came out as, or the code as given.
    def self.default_code : String
      @@default
    end

    def self.locale_for(domain : Domain) : String
      @@locales[domain.value]
    end

    # The language the process locale asks for: `GORI_LANG`, then `LC_ALL`, `LC_MESSAGES`,
    # `LANG` — the first that is set and non-empty decides, as libc does. The language subtag
    # is what precedes `_`, `.` or `@` (`ko_KR.UTF-8` → `ko`); `C`, `POSIX`, and any language
    # gori has no catalog for resolve to English. Pure over the hash it is handed, so no spec
    # depends on the developer's own environment.
    def self.resolve_auto(env : Hash(String, String) = ENV.to_h) : String
      {"GORI_LANG", "LC_ALL", "LC_MESSAGES", "LANG"}.each do |var|
        raw = env[var]?.try(&.strip)
        next if raw.nil? || raw.empty?
        code = raw.split(/[_.@]/, 2)[0].downcase
        return known?(code) ? code : DEFAULT_CODE
      end
      DEFAULT_CODE
    end

    # Resolve and install the languages. `default` is a code or AUTO; `overrides` maps a domain
    # to a code, or to INHERIT (the same as absent). An unknown code anywhere falls back rather
    # than raising — a hand-edited settings.json must not take the TUI down. Returns true when
    # any domain's language changed (`revision` moved with it); a re-apply of the same values
    # is a no-op, which is what lets the callers re-assert it freely.
    def self.apply(default : String, overrides : Hash(Domain, String) = {} of Domain => String,
                   env : Hash(String, String) = ENV.to_h) : Bool
      base = if default == AUTO
               resolve_auto(env)
             else
               known?(default) ? default : DEFAULT_CODE
             end
      changed = false
      Domain.values.each do |domain|
        pick = overrides[domain]?
        code = pick && pick != INHERIT && known?(pick) ? pick : base
        next if @@locales[domain.value] == code
        @@locales[domain.value] = code
        @@slices[domain.value] = code == DEFAULT_CODE ? nil : catalog(code).try(&.[domain.key]?)
        changed = true
      end
      @@default = base
      @@revision &+= 1 if changed
      changed
    end

    # --- lookup ------------------------------------------------------------------------

    # `msgid` in `domain`'s language — or `msgid` itself under English, and when untranslated.
    def self.t(domain : Domain, msgid : String) : String
      slice = @@slices[domain.value]
      return msgid unless slice
      if hit = slice[msgid]?
        return hit unless hit.empty? # "" in the catalog means "not yet translated"
      end
      @@missing.try(&.add("#{domain.key}:#{msgid}"))
      msgid
    end

    # As above, with `%{name}` placeholders filled from `args`.
    def self.t(domain : Domain, msgid : String, **args) : String
      text = t(domain, msgid)
      args.empty? ? text : interpolate(text, args, msgid)
    end

    # One of two msgids by count — `one` when `count == 1`, `other` otherwise. (`count`, not `n`:
    # the count is almost always also the `n:` argument the msgid interpolates.) English needs the
    # split; Korean does not inflect, so both keys carry the same text there. Both msgids are
    # catalog keys (the seam spec extracts both).
    def self.n(domain : Domain, count : Int, one : String, other : String, **args) : String
      t(domain, count == 1 ? one : other, **args)
    end

    {% for name, domain in {ui: "Ui", help: "Help", sys: "System", ring: "Companion"} %}
      def self.{{name.id}}(msgid : String) : String
        t(Domain::{{domain.id}}, msgid)
      end

      def self.{{name.id}}(msgid : String, **args) : String
        t(Domain::{{domain.id}}, msgid, **args)
      end

      def self.{{name.id}}_n(count : Int, one : String, other : String, **args) : String
        n(Domain::{{domain.id}}, count, one, other, **args)
      end
    {% end %}

    # --- catalogs ----------------------------------------------------------------------

    # The parsed catalog for `code` (domain key → msgid → text): nil for English and for a code
    # with no file. Parsed once. This is the one place a catalog is read, so a user-supplied
    # file could later enter here; it raises only on a malformed built-in, which the seam spec
    # catches in CI — never from `t`.
    def self.catalog(code : String) : Hash(String, Hash(String, String))?
      return nil if code == DEFAULT_CODE
      return @@parsed[code] if @@parsed.has_key?(code)
      raw = CATALOG_RAW[code]?
      return nil unless raw
      @@parsed[code] = parse_catalog(raw)
    end

    # Spec seam: put a synthetic catalog under a known `code` so lookup and interpolation can
    # be exercised without editing the shipped file. Forgets the resolved languages so the next
    # `apply` re-slices every domain; `reset_catalogs!` puts the built-ins back.
    def self.install(code : String, parsed : Hash(String, Hash(String, String))) : Nil
      @@parsed[code] = parsed
      forget_resolution
    end

    def self.reset_catalogs! : Nil
      @@parsed.clear
      forget_resolution
    end

    # Spec seam: the `domain:msgid` pairs that fell back to English inside the block.
    def self.collect_missing(&) : Set(String)
      @@missing = seen = Set(String).new
      yield
      seen
    ensure
      @@missing = nil
    end

    private def self.forget_resolution : Nil
      @@slices.fill(nil)
      @@locales.fill("")
    end

    private def self.parse_catalog(raw : String) : Hash(String, Hash(String, String))
      parsed = {} of String => Hash(String, String)
      root = JSON.parse(raw).as_h?
      return parsed unless root
      root.each do |domain_key, node|
        next unless entries = node.as_h?
        slice = {} of String => String
        entries.each { |msgid, text| text.as_s?.try { |s| slice[msgid] = s } }
        parsed[domain_key] = slice
      end
      parsed
    end

    private def self.interpolate(template : String, args, msgid : String) : String
      template % args
    rescue KeyError | ArgumentError
      # The translation names a placeholder the caller did not pass (or carries a stray `%`):
      # show the English template, whose placeholders are the ones the caller wrote for.
      begin
        msgid % args
      rescue KeyError | ArgumentError
        msgid
      end
    end
  end
end
