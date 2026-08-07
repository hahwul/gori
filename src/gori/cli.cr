require "option_parser"
require "log"
require "./config"
require "./paths"
require "./settings"
require "./app"
require "./cli/run"
require "./store"
require "./project_registry"
require "./mcp"
require "./proxy/tls/cert_authority"

module Gori
  # Subcommand-based CLI entrypoint.
  #
  # - `gori` or `gori tui [flags]`  → interactive TUI (`gori run capture` for capture-only)
  # - `gori settings [--edit]`      → print (and lazily init) / edit settings.json
  # - `gori ca`                     → print root CA path (or PEM); `ca regenerate` rotates it
  # - `gori run <sub>`              → non-interactive CLI (see Gori::CLI::Run)
  # - `gori mcp`                    → MCP (Model Context Protocol) server over stdio
  # - `gori wizard`                 → interactive first-run setup wizard (bind/theme)
  # - `gori tutorial`               → guided TUI tour (navigation, palette, menu, edit)
  # - `gori update`                 → channel-aware self-update (binary / brew / snap / AUR)
  module CLI
    def self.run(argv : Array(String) = ARGV) : Nil
      # `--config PATH` is consumed HERE, before subcommand detection, rather than being added
      # to each subcommand's OptionParser. It must apply to every surface (tui, run, mcp,
      # settings) and take effect before anything reads Settings, so one central strip is both
      # simpler and impossible to forget on a new subcommand — and every parser below would
      # otherwise reject it through invalid_option.
      argv = extract_config_flag(argv)

      # Split once: the version rule, the top-level help, and the dispatch all key off it.
      sub, subargs = split_subcommand(argv)

      # Global version (alone, or against a top-level subcommand) — see global_version_flag?.
      if global_version_flag?(subargs)
        puts "gori #{VERSION}"
        return
      end

      # Top-level help when no explicit subcommand is given
      if argv.any? { |a| a == "-h" || a == "--help" } && sub.nil?
        print_main_help
        return
      end

      subcmd = sub || "tui" # bare `gori` (or leading flags only) starts the TUI

      case subcmd
      when "tui"
        run_tui(subargs)
      when "settings"
        run_settings(subargs)
      when "ca"
        run_ca(subargs)
      when "run"
        run_run(subargs)
      when "wizard"
        run_wizard(subargs)
      when "tutorial"
        run_tutorial(subargs)
      when "mcp"
        run_mcp(subargs)
      when "update"
        run_update(subargs)
      else
        STDERR.puts "Unknown command: #{subcmd}"
        print_main_help
        exit 1
      end
    rescue ex : Error
      # Gori::Error is the project's EXPECTED-error type (see gori.cr) — something the
      # operator can act on, raised with a message written for them. One reaching the top
      # of the process printed a Crystal backtrace instead, which says the same thing in
      # the least usable form there is: `gori --ca-dir notes.txt`, or a GORI_HOME that is a
      # file, both landed that way. Deliberately narrow — an IO error, a nil, anything gori
      # did not anticipate still backtraces, because those are bugs and want a trace.
      abort "gori: #{ex.message.presence || ex.class}"
    end

    private VERSION_FLAGS = {"-v", "-V", "--version"}

    # The top-level subcommand and the arguments belonging to it. A leading flag — or an empty
    # argv — means none was named, so every token belongs to the default surface (the TUI).
    # Split once, because three rules key off it: the version flag, the top-level `-h`, and the
    # dispatch itself.
    private def self.split_subcommand(argv : Array(String)) : {String?, Array(String)}
      return {nil, argv} if argv.empty? || argv[0].starts_with?("-")
      {argv[0], argv[1..]}
    end

    # A version flag belongs to the TOP LEVEL — `gori -v`, `gori --version`, `gori run -v`,
    # `gori mcp --read-only --version` — which is what print_main_help and
    # docs/reference/cli.md both promise ("Flags like --version and --help work at the top
    # level too").
    #
    # It must NOT be claimed once a NESTED subcommand has been named, because there the same
    # token is that command's own option, or worse its option VALUE. A blanket `argv.any?`
    # claimed all of them, so `gori run rewriter add --find X -v boom` (rewriter's own
    # documented `-vVALUE`) and `gori run decoder base64-encode --input -v` printed the version
    # and returned 0 WITHOUT doing the work — a silent no-op carrying a SUCCESS status, the
    # worst failure mode there is for a surface scripts consume (`… || die` never fires).
    #
    # So scan only the LEADING FLAG RUN of the subcommand's own args and stop dead at the first
    # bare word: that word is a nested verb, and everything after it belongs to whoever owns it.
    # Keying on `subargs[0]` alone was too narrow and regressed the promise above — a version
    # flag sitting after a top-level subcommand's own flag (`gori mcp --read-only --version`,
    # `gori ca --pem -v`) reached that subcommand's parser and aborted with "unknown option",
    # while `--help` in the very same position still worked because every parser owns `-h`.
    #
    # KNOWN RESIDUAL, and why it is the right trade: a `-v` that is the VALUE of a top-level
    # flag (`gori run --project -v`) is still read as the flag, because telling a value from a
    # flag needs to know which flags take values — that lives in each subcommand's OptionParser,
    # which is not built yet at this layer. It only misfires on input that is already invalid
    # (`gori run --project x` is not a subcommand either), whereas the alternative broke a
    # documented, working invocation. Every NESTED case — the ones that actually bit — stays
    # excluded, because a nested verb is a bare word and ends the scan.
    private def self.global_version_flag?(subargs : Array(String)) : Bool
      subargs.each do |arg|
        return true if VERSION_FLAGS.includes?(arg)
        return false unless arg.starts_with?('-')
      end
      false
    end

    # Pull `--config PATH` / `--config=PATH` out of argv, point Settings at it, and return the
    # remaining args. Aborts on a missing value rather than silently ignoring the flag — a
    # config that quietly did not apply is the worst outcome for a reproducible run.
    private def self.extract_config_flag(argv : Array(String)) : Array(String)
      rest = [] of String
      i = 0
      while i < argv.size
        arg = argv[i]
        if arg == "--config"
          value = argv[i + 1]?
          # A following flag is not a path — treat `--config --edit` as the missing value it is,
          # rather than writing settings to a file literally named "--edit".
          abort "gori: --config needs a path" if value.nil? || value.starts_with?("-")
          Settings.path_override = value
          i += 2
          next
        elsif arg.starts_with?("--config=")
          value = arg["--config=".size..]
          abort "gori: --config needs a path" if value.empty?
          Settings.path_override = value
          i += 1
          next
        end
        rest << arg
        i += 1
      end
      rest
    end

    private def self.print_main_help : Nil
      puts "gori – interactive HTTP/HTTPS MITM proxy with TUI"
      puts ""
      puts "Usage: gori [command] [options]"
      puts ""
      puts "Commands:"
      puts "  tui       Start the interactive TUI (default when no command)"
      puts "  settings  Show the settings.json path (or --edit to open it)"
      puts "  ca        Print the root CA path, or regenerate it (see gori ca --help)"
      puts "  run       Non-interactive CLI: capture, history, show, repeater, issues, project"
      puts "  wizard    Interactive setup wizard (bind, theme, pet) — also runs on first launch"
      puts "  tutorial  Guided TUI tour with try-it steps (nav, palette, menu, edit)"
      puts "  mcp       Start an MCP server over stdio (AI/tool integration)"
      puts "  update    Update gori (channel-aware: binary download or package manager)"
      puts ""
      puts "See 'gori <command> --help' for more."
      puts "Flags like --version and --help work at the top level too."
    end

    # Runs the TUI.
    private def self.run_tui(args : Array(String)) : Nil
      Settings.load # persisted bind/upstream are the defaults; CLI flags override below
      listen = Settings.bind_host
      port = Settings.bind_port
      db_path = Paths.default_db
      db_explicit = false
      ca_dir = Paths.default_ca_dir
      insecure = false

      # Tracked separately from `listen`/`port` (which are pre-seeded from Settings and so can't
      # say whether a flag was actually GIVEN), because only an actual flag goes into the
      # process-only override layer below. See Settings.cli_bind_host.
      listen_flag = nil.as(String?)
      port_flag = nil.as(Int32?)

      parser = OptionParser.new do |p|
        p.banner = "Usage: gori tui [options]"
        p.on("-lHOST", "--listen=HOST", "Listen address (default #{Settings.bind_host})") { |v| listen = v; listen_flag = v }
        p.on("-pPORT", "--port=PORT", "Listen port (default #{Settings.bind_port})") do |v|
          parsed = v.to_i?
          abort "gori: invalid --port '#{v}' (expected 0-65535)" unless parsed && 0 <= parsed <= 65535
          port = parsed
          port_flag = parsed
        end
        p.on("--db=PATH", "SQLite database path (opens it directly, skipping the project picker)") { |v| db_path = v; db_explicit = true }
        p.on("--ca-dir=PATH", "Directory for the root CA") { |v| ca_dir = v }
        p.on("--insecure-upstream", "Do not verify upstream TLS certificates") { insecure = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.on("-v", "--version", "Show version") { puts "gori #{VERSION}"; exit 0 }
        p.on("-V", "Show version") { puts "gori #{VERSION}"; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      Paths.ensure_dirs
      # Publish the bind override into its OWN runtime layer, NOT into Settings.bind_host /
      # bind_port. Those are the persisted global, so assigning them here handed every later
      # `Settings.save` in the session a one-run flag to write to disk — see
      # Settings.cli_bind_host for the whole story. `effective_bind_*` (what the proxy binds,
      # and what every surface displays) picks the override up from there.
      Settings.cli_bind_host = listen_flag
      Settings.cli_bind_port = port_flag
      # --insecure-upstream stays a write into the PERSISTED property, deliberately unlike the
      # bind above: it carries no one-run promise to break (nothing documents it as temporary),
      # and the settings:network editor is expected to show verification as actually off so
      # toggling it back re-syncs the live proxy. Giving it an override layer too would be a
      # behaviour change, not a bug fix.
      Settings.verify_upstream = false if insecure
      config = Config.new(listen, port, db_path, ca_dir, !Settings.verify_upstream?)
      # Settings.load already put any corrupt-file warning on STDERR, which the alt screen
      # is about to wipe — hand it to the TUI so it reaches the operator on the picker.
      App.new(config).run_tui(open_db_path: db_explicit ? db_path : nil,
        settings_warning: Settings.load_warning)
    end

    # `gori settings` prints the path to the persisted settings file (settings.json
    # — the same file the TUI's settings:* + ^E editor write); `--edit` opens it in
    # $EDITOR. Lazily created with current defaults on first invocation. ("config"
    # the word is reserved for the runtime Config struct — flags/effective config.)
    private SETTINGS_USAGE = "Usage: gori settings [--edit]\n" \
                             "       gori settings sections\n" \
                             "       gori settings export [--sections a,b] [-o FILE]\n" \
                             "       gori settings import FILE [--sections a,b] [--dry-run]"

    private SETTINGS_VERBS = {"export", "import", "sections"}

    # A leading BARE WORD that is not one of the three verbs is a typo, not a flag. Letting it
    # fall through to `run_settings`'s own parser dropped it — OptionParser ignores leftover
    # positionals with no `unknown_args` handler — so `gori settings expor -o profile.json`
    # printed the settings path and exited 0: no export, no file, and `… || die` never fires.
    # That is the silent-no-op-carrying-SUCCESS failure this very file refuses for version flags
    # (see global_version_flag?), and `run_ca` below already rejects the identical shape.
    private def self.unknown_settings_verb?(args : Array(String)) : Bool
      return false unless first = args[0]?
      !first.starts_with?('-') && !SETTINGS_VERBS.includes?(first)
    end

    # Parse, then refuse any leftover positional. OptionParser silently DROPS unclaimed bare
    # words when no `unknown_args` handler is installed, and every `gori settings` verb but
    # `import` takes none — so `gori settings --edit export` opened the editor and dropped
    # `export`, `gori settings sections --help` printed the section list and never saw `--help`,
    # and `gori settings export team-profile.json` (a forgotten `-o`) dumped the profile to
    # stdout, created no file, and exited 0. `import` parses on its own because it does take a
    # positional; its own `rest.size > 1` guard is the same rule.
    private def self.reject_stray_args!(cmd : String, parser : OptionParser, args : Array(String)) : Nil
      rest = [] of String
      parser.unknown_args { |before, _| rest = before }
      parser.parse(args)
      return if rest.empty?
      label = cmd.empty? ? "gori settings" : "gori settings #{cmd}"
      abort "#{label}: unexpected argument(s): #{rest.join(", ")}\n#{parser}"
    end

    # Refuse to read or write a profile against settings gori could not load. Every section is
    # at its factory default at that point, so an EXPORT writes those defaults out under the
    # operator's name — into a file that outlives the stderr warning and gets committed or
    # shared — and an IMPORT persists them back over the real file (the 3-way merge has no base;
    # see Settings.load_degraded?). Both directions turn a recoverable local problem into a
    # permanent one, so neither is worth guessing at.
    private def self.abort_on_degraded_settings!(cmd : String) : Nil
      return unless Settings.load_degraded?
      abort "gori settings #{cmd}: #{Settings.path} could not be loaded (see the warning above, " \
            "if any), so every section is at its factory default right now — this would #{cmd} " \
            "those defaults, not your settings.\nFix or remove that file, then re-run."
    end

    private def self.run_settings(args : Array(String)) : Nil
      case args[0]?
      when "export"   then return run_settings_export(args[1..])
      when "import"   then return run_settings_import(args[1..])
      when "sections" then return run_settings_sections(args[1..])
      end
      if unknown_settings_verb?(args)
        STDERR.puts "unknown settings subcommand: #{args[0]}"
        STDERR.puts SETTINGS_USAGE
        exit 1
      end

      edit = false
      parser = OptionParser.new do |p|
        p.banner = SETTINGS_USAGE
        p.on("--edit", "Open the settings file in your editor (Settings: Editor / $VISUAL / $EDITOR / vi)") { edit = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      reject_stray_args!("", parser, args)

      Paths.ensure_dirs
      Settings.load                                    # pick up the persisted editor pref + existing values
      Settings.save unless File.exists?(Settings.path) # lazily materialize with current defaults
      path = Settings.path

      unless edit
        puts path
        return
      end

      # --edit spawns $EDITOR/vi with inherited stdio. A terminal editor reading from a
      # non-tty stdin (pipe/redirect/CI/background job) hangs waiting for input it can
      # never get, so require an interactive stdin. Guard on STDIN only: a GUI editor
      # (`code -w`, `subl -w`) needs no tty, and stdout may legitimately be redirected,
      # so don't over-restrict those — point at the non-interactive path otherwise.
      unless STDIN.tty?
        abort "gori settings --edit: stdin is not an interactive terminal; run 'gori settings' to print the path, then edit it directly"
      end

      cmd = Settings.editor_command
      status =
        begin
          Process.run(cmd[0], cmd[1..] + [path],
            input: Process::Redirect::Inherit, output: Process::Redirect::Inherit, error: Process::Redirect::Inherit)
        rescue File::NotFoundError
          # Process.run RAISES when the program isn't on PATH, and CLI.run's rescue catches only
          # Gori::Error — so a stale $EDITOR, or an `"editor": {"command": …}` naming something
          # this box doesn't have, printed a Crystal backtrace at the user. ExternalEditor (the
          # TUI's ^E path) has always handled this properly; match its wording.
          abort "gori settings --edit: editor not found: #{cmd[0]}\n" \
                "Set one with 'Settings: Editor' in the TUI, or via $VISUAL / $EDITOR."
        rescue ex
          abort "gori settings --edit: could not run the editor (#{cmd.join(' ')}): #{ex.message}"
        end
      abort "gori settings: editor (#{cmd.join(' ')}) exited #{status.exit_code}" unless status.success?
    end

    # `gori settings sections` — the top-level keys export/import operate on.
    #
    # Lists Settings::SECTION_KEYS (every section gori knows), not `document_keys` (the ones
    # this install happens to have a value for). Listing the latter meant a fresh config
    # advertised 6 of 28 sections, and the ones it hid were exactly the ones export then
    # rejected as "unknown" — so the message pointing here for "the list" pointed at a list that
    # did not contain the name. The "not set" annotation keeps the information that was
    # genuinely useful about the old output.
    private def self.run_settings_sections(args : Array(String)) : Nil
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori settings sections"
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
      end
      reject_stray_args!("sections", parser, args)

      Settings.load
      present = Settings.document_keys
      Settings::SECTION_KEYS.each do |k|
        notes = [] of String
        notes << "holds secrets — excluded unless named" if Settings::SECRET_SECTIONS.includes?(k)
        notes << "not set — at its default" unless present.includes?(k)
        puts notes.empty? ? k : "#{k}  (#{notes.join("; ")})"
      end
    end

    # `gori settings export` — write a shareable profile to stdout (or -o FILE).
    private def self.run_settings_export(args : Array(String)) : Nil
      sections = nil.as(Array(String)?)
      out = nil.as(String?)
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori settings export [--sections a,b] [-o FILE]"
        p.on("--sections=LIST", "Comma-separated top-level sections (default: all but #{Settings::SECRET_SECTIONS.join('/')})") { |v| sections = split_sections("export", v) }
        p.on("-o FILE", "--out=FILE", "Write here instead of stdout") { |v| out = v }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      reject_stray_args!("export", parser, args)

      Settings.load
      abort_on_degraded_settings!("export")
      if list = sections
        # Names were already validated against SECTION_KEYS in split_sections. What is left is
        # informational: a KNOWN section this install never touched is omitted by `serialize`,
        # so it is simply absent from the profile — correct (there is no value to carry), but
        # silently handing back `{}` for `--sections scan_rules` reads as a bug. Say it, on
        # STDERR so a piped profile stays clean, and keep exit 0: nothing went wrong.
        at_default = list - Settings.document_keys
        STDERR.puts "note: at their default, nothing to export: #{at_default.join(", ")}" unless at_default.empty?
      end
      doc = Settings.export_document(sections)
      if path = out
        write_export(path, doc, Settings.exported_secret_sections(sections))
      else
        puts doc
      end
    end

    # Write the profile, 0600 the moment it actually carries a secret.
    #
    # Naming `env`/`decoder` in --sections IS the consent to export them (that is the whole
    # point of the SECRET_SECTIONS default), but consenting to export a credential is not
    # consenting to leave it world-readable in a shared checkout or on a multi-user box. The
    # mode is set at CREATE time, not by a chmod after `File.write`, so the bytes are never on
    # disk at 0644 even briefly. The explicit chmod additionally tightens a file that already
    # existed at a looser mode — `File.open`'s perm applies only to a file it creates.
    #
    # Best-effort on a filesystem that cannot represent the mode (a mounted share): an export
    # the operator asked for must not fail over it, but they ARE told, because the file is
    # then genuinely unprotected and that is not ours to hide.
    private def self.write_export(path : String, doc : String, secrets : Array(String)) : Nil
      perm = File::Permissions.new(secrets.empty? ? 0o644 : 0o600)
      begin
        File.open(path, "w", perm: perm) do |f|
          File.chmod(path, perm) unless secrets.empty?
          f.print(doc)
        end
      rescue ex
        abort "gori settings export: cannot write #{path}: #{ex.message}"
      end
      return STDERR.puts "wrote #{path}" if secrets.empty?
      carried = secrets.join(", ")
      mode = begin
        File.info(path).permissions.value & 0o777
      rescue
        -1
      end
      if mode == 0o600
        STDERR.puts "wrote #{path} (0600 — it carries #{carried})"
      else
        STDERR.puts "wrote #{path} — WARNING: it carries #{carried} and this filesystem " \
                    "would not take 0600; protect it yourself"
      end
    end

    # `gori settings import` — apply a profile's sections to this config.
    private def self.run_settings_import(args : Array(String)) : Nil
      sections = nil.as(Array(String)?)
      dry = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori settings import FILE [--sections a,b] [--dry-run]"
        p.on("--sections=LIST", "Comma-separated top-level sections to apply (default: every section in FILE)") { |v| sections = split_sections("import", v) }
        p.on("--dry-run", "Print which sections would be applied, then exit without writing") { dry = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      rest = [] of String
      parser.unknown_args { |before, _| rest = before }
      parser.parse(args)

      file = rest[0]?
      abort "gori settings import: needs a file\n#{parser}" unless file
      # One profile per run. Taking rest[0] and dropping the rest turned a typo — a missing
      # `--sections`, a glob that matched two files — into a half-done import reported as a
      # full success.
      abort "gori settings import: one file at a time (got #{rest.size}: #{rest.join(", ")})" if rest.size > 1
      raw = begin
        File.read(file)
      rescue ex
        abort "gori settings import: cannot read #{file}: #{ex.message}"
      end
      # Reject a non-object before touching anything: apply_sections is tolerant by design and
      # would silently no-op on a JSON array or scalar, which reads as "imported, nothing
      # happened" rather than "this is not a settings document".
      begin
        abort "gori settings import: #{file} is not a settings document (expected a JSON object)" unless JSON.parse(raw).as_h?
      rescue
        abort "gori settings import: #{file} is not valid JSON"
      end

      Settings.load
      # Settings gori could not load leave EVERY section at its factory default and the 3-way
      # merge without a base, so the `save` inside import_document writes those defaults over
      # the operator's real file — theme, env token values, hostname overrides, upstream rules,
      # the TLS pass-through list — while the summary names only the section they asked for.
      # `load_root` promises the fallback lasts "for this run"; an import is the surface that
      # would make it permanent. `--dry-run` writes nothing, so it may proceed — but the
      # comparison it prints is against defaults, and saying so is the whole point of the note.
      if dry
        STDERR.puts "note: the comparison below is against DEFAULTS, not your real settings" if Settings.load_degraded?
      else
        abort_on_degraded_settings!("import")
      end

      applicable, changed, unknown = Settings.import_preview(raw, sections)
      STDERR.puts "warning: unrecognised section(s) ignored: #{unknown.join(", ")}" unless unknown.empty?

      if dry
        if applicable.empty?
          puts "nothing to apply — #{file} carries none of the selected sections"
        elsif changed.empty?
          # Only say "already match" when something really was compared. With no applicable
          # section this line claimed a match that was never tested.
          puts "no changes — the #{applicable.size} selected section(s) already match #{Settings.path}"
        else
          # This list is EXACTLY what a real run reports as imported, so the two commands agree
          # on the count; the `(unchanged)` marks carry what printing only the differing subset
          # used to convey. "apply", not "replace": apply_sections merges the object-of-scalars
          # sections key by key, and `changed` is an over-approximation of what differs (see
          # Settings.import_preview) — a marked section may prove a no-op, an unmarked one is
          # guaranteed to be.
          puts "would apply #{applicable.size} section(s) to #{Settings.path}:"
          applicable.each { |k| puts changed.includes?(k) ? "  #{k}" : "  #{k}  (unchanged)" }
        end
        return
      end

      # import_document drops unrecognised keys itself and raises if the write fails, so what it
      # returns IS what was handed to the settings. Subtracting `unknown` from it here was the
      # second half of the miscount: with a valid section wrongly classed unknown, the summary
      # read "imported 0 section(s)" over a write that had just happened.
      applied = Settings.import_document(raw, sections)
      puts "imported #{applied.size} section(s) into #{Settings.path}#{applied.empty? ? "" : ": #{applied.join(", ")}"}"
    end

    # Split a `--sections` value into names. Pure, so the suite can exercise it — `abort` calls
    # `exit`, which is not catchable, so the aborts stay at the call site below.
    private def self.parse_sections_value(value : String) : Array(String)
      value.split(',').compact_map(&.strip.presence)
    end

    # The names in `list` gori does not know. Static SECTION_KEYS, never `document_keys` — the
    # latter made this reject a name gori knows perfectly well but has no value for yet, which
    # is how the documented `--sections network,scan_rules` example failed on a fresh install.
    private def self.unknown_sections(list : Array(String)) : Array(String)
      list - Settings::SECTION_KEYS
    end

    # `--sections` takes at least one KNOWN name, on both export and import.
    #
    # Two silent-success holes met here. An empty or all-commas value compact_map'd down to
    # `[] of String` — TRUTHY in Crystal — so it sailed past the unknown-section check with
    # nothing to check and then matched nothing: `--sections=""` exported `{}` and imported
    # nothing, both exit 0, which is where a shell expanding an unset variable lands. And only
    # export validated the names at all, so `gori settings import p.json --sections netwrok`
    # selected nothing and reported "imported 0 section(s)" — or, with `--dry-run`, the flatly
    # wrong "no changes — the selected sections already match".
    private def self.split_sections(cmd : String, value : String) : Array(String)
      list = parse_sections_value(value)
      if list.empty?
        abort "gori settings #{cmd}: --sections needs at least one section name\n" \
              "Run 'gori settings sections' for the list."
      end
      unknown = unknown_sections(list)
      unless unknown.empty?
        abort "gori settings #{cmd}: unknown section(s): #{unknown.join(", ")}\n" \
              "Run 'gori settings sections' for the list."
      end
      list
    end

    # `gori ca` is the CA utility surface:
    # - bare / flags  → print path (default) or PEM (`--pem`); creates CA on first use
    # - `regenerate`  → replace the root CA (destructive; needs --yes or an interactive confirm)
    # - `import`      → adopt an externally-created root CA (cert + key PEM); destructive
    private def self.run_ca(args : Array(String)) : Nil
      if (first = args[0]?) && !first.starts_with?("-")
        case first
        when "regenerate"
          run_ca_regenerate(args[1..])
        when "import"
          run_ca_import(args[1..])
        else
          STDERR.puts "unknown ca subcommand: #{first}"
          print_ca_usage(STDERR)
          exit 1
        end
        return
      end
      run_ca_show(args)
    end

    private def self.print_ca_usage(io : IO) : Nil
      io.puts "Usage: gori ca [options]"
      io.puts "       gori ca regenerate [--yes] [--ca-dir=DIR]"
      io.puts "       gori ca import --cert FILE --key FILE [--yes] [--ca-dir=DIR]"
      io.puts ""
      io.puts "Print the root CA certificate path (default), create it on first use,"
      io.puts "regenerate it, or import an externally-created root CA (both invalidate"
      io.puts "existing client trust)."
      io.puts ""
      io.puts "Options:"
      io.puts "  --ca-dir=DIR   CA directory (default ~/.gori/ca or $GORI_HOME/ca)"
      io.puts "  --pem          Print the certificate PEM to stdout instead of the path"
      io.puts "  -h, --help     Show this help"
      io.puts ""
      io.puts "Regenerate options:"
      io.puts "  --yes, -y      Skip the interactive confirm (required when stdin is not a tty)"
      io.puts "  --ca-dir=DIR   CA directory to regenerate"
      io.puts ""
      io.puts "Import options:"
      io.puts "  --cert FILE    Root CA certificate PEM to adopt (required)"
      io.puts "  --key FILE     Matching private key PEM (required)"
      io.puts "  --yes, -y      Skip the interactive confirm (required when stdin is not a tty)"
      io.puts "  --ca-dir=DIR   CA directory to install into"
    end

    # Path / PEM print path (the default `gori ca` action).
    private def self.run_ca_show(args : Array(String)) : Nil
      ca_dir = Paths.default_ca_dir
      pem = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori ca [options]\n       gori ca regenerate [--yes] [--ca-dir=DIR]"
        p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
        p.on("--pem", "Print the certificate PEM to stdout instead of the path") { pem = true }
        p.on("-h", "--help", "Show this help") { print_ca_usage(STDOUT); exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      begin
        Paths.ensure_dirs
        ca = Proxy::Tls::CertAuthority.load_or_create(ca_dir)
        if pem
          print ca.ca_cert_pem
          # PEM files usually already end with a newline; don't double them.
          STDOUT.flush
        else
          puts ca.ca_cert_path
        end
      rescue ex
        abort "gori ca: could not create/read the CA in #{ca_dir}: #{ex.message}"
      end
    end

    # Replace the on-disk root CA. Destructive: voids every prior client trust entry.
    # A *running* gori process keeps the old CA in memory until restart — warn on stderr.
    # Confirmation mirrors the TUI (type "regenerate", or pass --yes for scripts/CI).
    private def self.run_ca_regenerate(args : Array(String)) : Nil
      ca_dir = Paths.default_ca_dir
      yes = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori ca regenerate [--yes] [--ca-dir=DIR]"
        p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
        p.on("-y", "--yes", "Skip the interactive confirm") { yes = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      confirm_ca_regenerate!(ca_dir) unless yes

      begin
        Paths.ensure_dirs
        ca = Proxy::Tls::CertAuthority.load_or_create(ca_dir)
        ca.regenerate!
        puts ca.ca_cert_path
        STDERR.puts "gori ca: regenerated — re-trust clients; restart any running gori"
      rescue ex
        abort "gori ca regenerate: could not replace the CA in #{ca_dir}: #{ex.message}"
      end
    end

    # Interactive gate for regenerate (skipped when --yes). Non-tty stdin without --yes
    # is rejected so a pipe/CI job can't hang waiting for a typed confirm.
    private def self.confirm_ca_regenerate!(ca_dir : String) : Nil
      unless STDIN.tty?
        abort "gori ca regenerate: stdin is not a terminal; re-run with --yes to confirm"
      end
      STDERR.puts "Replace the root CA in #{ca_dir}?"
      STDERR.puts "This invalidates existing client trust."
      STDERR.puts "Running gori instances keep the old CA until restarted."
      STDERR.print "Type 'regenerate' to confirm: "
      STDERR.flush
      line = (STDIN.gets || "").strip
      abort "gori ca regenerate: cancelled" unless line == "regenerate"
    end

    # Adopt an externally-created root CA (cert + key PEM) in place of gori's own.
    # Destructive like regenerate — it overwrites the on-disk root and voids prior
    # client trust — so it shares the confirm gate. Validation (key↔cert match, CA
    # flag) happens inside import! BEFORE anything is written, so a bad pair aborts
    # without touching the current CA.
    private def self.run_ca_import(args : Array(String)) : Nil
      ca_dir = Paths.default_ca_dir
      cert_path = nil.as(String?)
      key_path = nil.as(String?)
      yes = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori ca import --cert FILE --key FILE [--yes] [--ca-dir=DIR]"
        p.on("--cert FILE", "Root CA certificate PEM to adopt") { |v| cert_path = v }
        p.on("--key FILE", "Matching private key PEM") { |v| key_path = v }
        p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
        p.on("-y", "--yes", "Skip the interactive confirm") { yes = true }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      cert = cert_path
      key = key_path
      abort "gori ca import: --cert and --key are both required\n#{parser}" unless cert && key

      # Validate the pair up front so a bad --cert/--key aborts BEFORE we touch (or,
      # in a fresh dir, auto-create) any CA — the user asked for THEIR cert, not a
      # surprise gori-generated one.
      begin
        Proxy::Tls::CertAuthority.validate_pem_pair(cert, key)
      rescue ex
        abort "gori ca import: #{ex.message}"
      end

      confirm_ca_import!(ca_dir) unless yes

      begin
        Paths.ensure_dirs
        ca = Proxy::Tls::CertAuthority.load_or_create(ca_dir)
        warning = ca.import!(cert, key)
        puts ca.ca_cert_path
        STDERR.puts "gori ca: WARNING — #{warning}" if warning
        STDERR.puts "gori ca: imported — re-trust the imported cert; restart any running gori"
      rescue ex
        abort "gori ca import: could not install the CA in #{ca_dir}: #{ex.message}"
      end
    end

    # Interactive gate for import (skipped when --yes). Same non-tty rule as regenerate.
    private def self.confirm_ca_import!(ca_dir : String) : Nil
      unless STDIN.tty?
        abort "gori ca import: stdin is not a terminal; re-run with --yes to confirm"
      end
      STDERR.puts "Replace the root CA in #{ca_dir} with the imported cert/key?"
      STDERR.puts "This invalidates existing client trust."
      STDERR.puts "Running gori instances keep the old CA until restarted."
      STDERR.print "Type 'import' to confirm: "
      STDERR.flush
      line = (STDIN.gets || "").strip
      abort "gori ca import: cancelled" unless line == "import"
    end

    # Handler for `gori run` (the non-interactive CLI mode). Named run_run to match
    # the run_<subcommand> dispatch convention; the subcommand suite itself lives in
    # `Gori::CLI::Run` (src/gori/cli/run.cr).
    private def self.run_run(args : Array(String)) : Nil
      Run.dispatch(args)
    end

    # `gori wizard` and `gori tutorial` take no arguments at all. `unknown_args` runs BEFORE
    # `invalid_option` (both fire for an undeclared flag), so this is what actually reports one
    # — the `invalid_option` handlers below are the fallback, not the primary path. A stray flag
    # and a stray word are named apart so `gori wizard --port 9000` reads as the misplaced
    # `gori tui` flag it actually is.
    #
    # `after` is the run following a `--` separator, which OptionParser strips and hands over
    # separately. It has to be rejected too: discarding it left `gori wizard -- --port 9000`
    # launching with the flag silently dropped, which is the whole failure this replaced.
    private def self.reject_extra_args(cmd : String, rest : Array(String), after : Array(String),
                                       parser : OptionParser) : Nil
      return if (first = (rest + after).first?).nil?
      abort "unknown option: #{first}\n#{parser}" if first.starts_with?('-')
      abort "gori #{cmd} takes no arguments (got #{first.inspect})\n#{parser}"
    end

    # Run `body` against a terminal `Tui.open_terminal` has just switched into raw mode + the
    # alternate screen, and restore it on every way out — including a DELIVERED SIGNAL, which
    # never reaches an `ensure` at all (the default disposition kills the process with no
    # stack unwind). `gori wizard` and `gori tutorial` were the only two surfaces that opened
    # a terminal without this: an SSH drop's SIGHUP, or `pkill gori`, handed the operator's
    # pane back in raw mode with the alternate screen up and mouse reporting on, recoverable
    # only with `reset`. App#run_tui has armed the same guard for the TUI all along — see
    # App::SignalGuard for why it restores and re-raises rather than nudging a channel.
    private def self.with_tui_terminal(term : Termisu, &)
      App::SignalGuard.new(-> { term.close; nil }).install
      begin
        yield
      ensure
        term.close # restore the terminal even on error
        # Disarmed AFTER the close, in that order for the reason App#run_tui gives: until the
        # terminal is actually restored the guard is the only thing between a delivered
        # signal and a wrecked tty, and afterwards it would only re-close a closed Termisu.
        App::TUI_SIGNALS.each(&.reset)
      end
    end

    # `gori wizard` launches the interactive, step-by-step setup wizard (bind
    # address → theme). It also runs automatically on first launch
    # (App#run_tui, when settings.json doesn't exist yet); this command re-runs it
    # anytime. Config-only — it edits settings.json + the live theme, so it sets up
    # its own terminal directly instead of going through App (which eagerly loads
    # the CA).
    private def self.run_wizard(args : Array(String)) : Nil
      # A real OptionParser, not a hand-rolled scan for -h: this used to IGNORE everything it
      # didn't recognise, so `gori wizard --port 9000` — which the help text below all but
      # invites, and which belongs to `gori tui` — was a silent no-op. Every other subcommand
      # aborts on an unknown flag; this one now does too.
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori wizard\n" \
                   "  Interactive setup wizard: global proxy bind (default for projects), TUI theme, Miss Ring.\n" \
                   "  Runs automatically on first launch; use this to re-run it anytime.\n" \
                   "  Bind is the shared default — pin a different address per project in the Project tab;\n" \
                   "  `gori tui --listen/--port` override settings for one run only (not written to disk)."
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
        p.unknown_args { |rest, after| reject_extra_args("wizard", rest, after, p) }
      end
      parser.parse(args)

      Paths.ensure_dirs
      Settings.load
      Tui::Theme.load_custom           # register user themes before the theme step
      Tui::Theme.apply(Settings.theme) # honour the persisted theme from the first frame
      # The wizard drives /dev/tty directly (not STDIN/STDOUT, which may be redirected
      # while a real terminal is still present), so the guard lives at the shared
      # Tui.open_terminal construction point (same as App#run_tui).
      term = Tui.open_terminal("run the wizard directly, not under CI or a detached/background job")
      # The wizard hands a failed persist back rather than printing onto a screen that is
      # about to be wiped — report it here, on the restored terminal, and fail the command.
      # Silently exiting 0 having written nothing was the worst version of this.
      err = with_tui_terminal(term) do
        # INSIDE the guarded block, mirroring App#run_tui: a signal delivered while these run
        # would otherwise leave the tty raw with the alternate screen up, and an enable_* that
        # raises needs the `ensure term.close` to cover it.
        term.enable_enhanced_keyboard       # Kitty disambiguation for IME/Unicode
        term.enable_mouse if Settings.mouse # SGR-1006 click + scroll-wheel nav
        Tui::SetupWizard.new(term).run
      end
      if err
        STDERR.puts "gori: setup wizard: #{err}"
        exit 1
      end
    end

    # `gori tutorial` launches the guided TUI tour — tab/pane navigation, the
    # command palette (^P), the action menu (space), and edit mode (READ/INS) —
    # on a harmless mock of the UI. It is also offered at the end of `gori wizard`
    # / first launch; this command repeaters it anytime. Like the wizard it drives
    # /dev/tty directly, so it sets up its own terminal instead of going through App.
    private def self.run_tutorial(args : Array(String)) : Nil
      parser = OptionParser.new do |p| # same reasoning as run_wizard's: no silent no-ops
        p.banner = "Usage: gori tutorial\n" \
                   "  Interactive tour of gori's TUI on a mock UI: tab/pane navigation,\n" \
                   "  the command palette (^P), the action menu (space), and edit mode\n" \
                   "  (READ/INS). Each lesson asks you to try the key; a final practice\n" \
                   "  step covers all four moves, then a first-session checklist.\n" \
                   "  Also offered at the end of `gori wizard`; safe to re-run anytime."
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
        p.unknown_args { |rest, after| reject_extra_args("tutorial", rest, after, p) }
      end
      parser.parse(args)

      Paths.ensure_dirs
      Settings.load
      Tui::Theme.load_custom           # honour user themes so the mock matches the real UI
      Tui::Theme.apply(Settings.theme) # render the tour in the persisted theme
      term = Tui.open_terminal("run the tutorial directly, not under CI or a detached/background job")
      with_tui_terminal(term) do
        term.enable_enhanced_keyboard # Kitty disambiguation (mirrors the wizard)
        term.enable_mouse             # always on for the tour: Prev/Next buttons + mock clicks
        Tui::Tutorial.new(term).run
      end
    end

    # `gori mcp` starts a Model Context Protocol server over stdio (JSON-RPC 2.0):
    # an AI client (Claude Desktop / Claude Code) spawns it and queries gori's
    # captured data + drives repeaters. STDOUT is the protocol channel, so EVERYTHING
    # else (logs, the resolved-db banner, errors) goes to STDERR.
    private def self.run_mcp(args : Array(String)) : Nil
      db_path = nil.as(String?)
      project = nil.as(String?)
      insecure_upstream = false
      read_only = false
      use_active_project = false
      no_project = false
      # A LIST, not a single slot: `gori mcp --install-claude-code --install-codex` is what
      # someone who runs two agents types, and the last-one-wins slot this used to be
      # configured Codex alone and said nothing about the client it skipped — the same
      # "accepted, then quietly discarded" failure MCP::Install.build_args documents for the
      # selector flags, spent on a whole client instead of one flag.
      install_targets = [] of String

      parser = OptionParser.new do |p|
        p.banner = "Usage: gori mcp [options]\n\n" \
                   "Start an MCP (Model Context Protocol) server over stdio. An AI client\n" \
                   "spawns this and talks JSON-RPC on stdin/stdout. With no --db/--project,\n" \
                   "a Git workspace is path-bound to its own project. Outside a workspace\n" \
                   "the server starts unbound so the agent can list/create/switch projects.\n" \
                   "Pass --use-active-project to serve the active TUI/MRU project instead."
        p.on("--db=PATH", "Serve this SQLite db (overrides --project)") { |v| db_path = v }
        p.on("--project=NAME", "Serve a named project's db") { |v| project = v }
        p.on("--use-active-project", "Ignore the current Git workspace and serve the active TUI/MRU project") { use_active_project = true }
        p.on("--no-project", "Start unbound even inside a Git workspace (agent picks via list/create/switch)") { no_project = true }
        p.on("--insecure-upstream", "send_request: skip upstream TLS verification") { insecure_upstream = true }
        p.on("--read-only", "Disable action tools (send_request, create/update_issue)") { read_only = true }
        p.on("--install-agy", "Install gori as an MCP server in Antigravity (~/.gemini/antigravity-cli/mcp_config.json)") { install_targets << "agy" }
        p.on("--install-codex", "Install gori as an MCP server in Codex (~/.codex/config.toml)") { install_targets << "codex" }
        p.on("--install-claude", "Install gori as an MCP server in Claude Desktop config") { install_targets << "claude" }
        p.on("--install-claude-code", "Install gori as an MCP server in Claude Code (~/.claude.json)") { install_targets << "claude-code" }
        p.on("--install-grok", "Install gori as an MCP server in Grok (~/.grok/config.toml)") { install_targets << "grok" }
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
      parser.parse(args)

      if use_active_project && (db_path.try(&.presence) || project.try(&.presence))
        abort "gori mcp: --use-active-project cannot be combined with --db/--project"
      end
      if no_project && (db_path.try(&.presence) || project.try(&.presence) || use_active_project)
        abort "gori mcp: --no-project cannot be combined with --db/--project/--use-active-project"
      end

      unless install_targets.empty?
        # Settings.path_override is `--config`, already stripped from argv by CLI.run before
        # dispatch — so run_mcp never sees the flag and can only read it back from here.
        ok = install_mcp_config(install_targets, db_path, project, read_only, insecure_upstream,
          use_active_project, no_project, Settings.path_override)
        exit(ok ? 0 : 1)
      end

      # Logs to STDERR ONLY — STDOUT is reserved for the JSON-RPC stream.
      Log.setup(:info, Log::IOBackend.new(STDERR))
      Settings.load # send_request's repeater engines read the upstream-proxy setting from here

      selection = if no_project
                    MCP::ProjectResolver::Selection.new(nil, nil, nil, "unbound")
                  else
                    resolve_mcp_project(db_path, project,
                      workspace_project: !use_active_project,
                      allow_active_fallback: use_active_project)
                  end
      project_name = selection.project_name
      project_slug = selection.project_slug
      project_id = selection.project_id

      unless selection.bound?
        Log.info { "mcp: unbound (no project); use list_projects / create_project / switch_project (actions=#{!read_only})" }
        server = MCP::Server.new(nil, allow_actions: !read_only, verify_upstream: !insecure_upstream,
          project_name: nil, project_slug: nil, db_path: nil,
          selection_source: selection.source, workspace_root: nil, project_id: nil)
        server.run
        return
      end

      resolved = selection.db_path.not_nil!
      Log.info { "mcp: serving #{resolved}#{" (#{project_name})" if project_name}#{" [#{project_slug}]" if project_slug} source=#{selection.source} (actions=#{!read_only})" }
      if selection.auto_created
        Log.warn { "mcp: created an isolated project for workspace #{selection.workspace_root}; use --project/--db to override" }
      elsif selection.source.in?("active-tui", "mru", "default-db")
        Log.warn { "mcp: no source workspace or explicit selector — defaulting via #{selection.source} to #{resolved}" }
      end

      # Opening a non-SQLite / unreadable file raises deep in the driver; turn that
      # into a clean error instead of an unhandled backtrace (parity with `gori run`).
      store =
        begin
          Store.open(resolved, events: nil, retention_flows: Store::RETENTION_UNLIMITED) # never prune the user's history
        rescue ex : DB::Error | SQLite3::Exception
          abort "gori mcp: cannot open database #{resolved}: #{ex.message.presence || "not a valid SQLite database (or unreadable)"}"
        end
      Log.warn { "mcp: #{resolved} has no captured flows (empty database)" } if store.count.zero?
      begin
        server = MCP::Server.new(store, allow_actions: !read_only, verify_upstream: !insecure_upstream,
          project_name: project_name, project_slug: project_slug, db_path: resolved,
          selection_source: selection.source, workspace_root: selection.workspace_root,
          project_id: project_id)
        server.run # blocks until STDIN EOF (client closed)
      ensure
        store.close
      end
    end

    # Writes the MCP entry into every named client config. Returns false if ANY target
    # failed — reported per target, and never as an abort partway through, which would have
    # made "which clients did gori configure?" depend on the order the flags were typed in.
    private def self.install_mcp_config(targets : Array(String), db_path : String?, project : String?,
                                        read_only : Bool, insecure_upstream : Bool,
                                        use_active_project : Bool, no_project : Bool,
                                        settings_path : String?) : Bool
      exe = MCP::Install.executable_path
      outcomes = MCP::Install.install_all(targets, exe_path: exe, db_path: db_path, project: project,
        read_only: read_only, insecure_upstream: insecure_upstream,
        use_active_project: use_active_project, no_project: no_project,
        settings_path: settings_path)
      outcomes.each do |outcome|
        if path = outcome.path
          puts "Successfully installed gori MCP server configuration to #{path}"
        else
          STDERR.puts "Failed to install MCP config for #{outcome.target}: #{outcome.error}"
        end
      end
      # Once, and read back off an Outcome: the argv is identical for every target, and this
      # is the array the installs actually wrote rather than a second build of it.
      outcomes.first?.try { |first| puts "Command: #{exe} #{first.args.join(" ")}" }
      outcomes.all?(&.ok?)
    rescue ex
      # `executable_path` (gori invoked through a PATH entry that has since moved) and
      # `build_args` (a deleted working directory) both raise before any target is attempted.
      # Neither is a Gori::Error, so CLI.run's narrow rescue lets them out as a backtrace —
      # they were covered by this method's own rescue before it grew a loop, and a setup
      # failure affecting every target still belongs here rather than in an Outcome.
      abort "Failed to install MCP config: #{ex.message.presence || ex.class}"
    end

    private def self.resolve_mcp_project(db : String?, project : String?, *, workspace_project : Bool,
                                         allow_active_fallback : Bool) : MCP::ProjectResolver::Selection
      MCP::ProjectResolver.resolve(db, project, workspace_project: workspace_project,
        allow_active_fallback: allow_active_fallback)
    rescue ex : MCP::ProjectResolver::Error | Gori::Error
      abort "gori mcp: #{ex.message}"
    end

    private def self.run_update(args : Array(String)) : Nil
      exec_pkg = false
      parser = OptionParser.new do |p|
        p.banner = "Usage: gori update [--exec]"
        p.on("--exec", "For Homebrew/Snap: run the upgrade command (default: print only)") { exec_pkg = true }
        p.on("-h", "--help", "Show this help") do
          puts p
          puts ""
          puts "Updates gori based on how it was installed:"
          puts "  • standalone binary  — download the latest GitHub release asset"
          puts "  • Homebrew           — print (or --exec) brew upgrade gori"
          puts "  • Snap               — print (or --exec) snap refresh gori"
          puts "  • pacman/AUR         — print yay/paru/pacman guidance"
          puts "  • deb (dpkg)         — print apt upgrade guidance"
          puts "  • rpm                — print dnf/yum/zypper guidance"
          puts ""
          puts "System paths under /usr/bin are classified by package ownership"
          puts "(pacman -Qo / dpkg-query -S / rpm -qf) and /etc/os-release."
          exit 0
        end
        p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
        # `gori update` takes no positional arguments, and `--exec` is its only
        # flag — so a `--` separator has nothing legitimate to protect. Without
        # this, `gori update -- --exec` parsed clean and silently dropped the
        # flag, and `gori update whatever` ran a full self-update on a typo. Same
        # failure, same guard, as `gori wizard` / `gori tutorial`.
        p.unknown_args { |rest, after| reject_extra_args("update", rest, after, p) }
      end
      parser.parse(args)
      begin
        Update.run(exec_package_commands: exec_pkg)
      rescue ex : Error
        abort "gori update: #{ex.message}"
      end
    end
  end
end
