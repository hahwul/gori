require "option_parser"
require "levenshtein"
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

require "./cli/ca"
require "./cli/mcp"
require "./cli/settings"

module Gori
  # Subcommand-based CLI entrypoint.
  #
  # - `gori` or `gori tui [flags]`  → interactive TUI (`gori run capture` for capture-only)
  # - `gori settings [--edit]`      → print (and lazily init) / edit settings.json
  # - `gori ca`                     → print root CA path (or PEM); `ca regenerate` rotates it
  # - `gori run <sub>`              → non-interactive CLI (see Gori::CLI::Run)
  # - `gori mcp`                    → MCP (Model Context Protocol) server over stdio
  # - `gori wizard`                 → interactive first-run setup wizard (bind/theme/companion)
  # - `gori tutorial`               → guided TUI tour (navigation, menu, palette, edit, traffic)
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
        FlowSource.surface = FlowSource::Surface::Tui
        run_tui(subargs)
      when "settings"
        run_settings(subargs)
      when "ca"
        run_ca(subargs)
      when "run"
        # Which surface is acting, for anything that records WHO (the #864 feed). Set at the
        # dispatch and not inside each subcommand: `gori run` has dozens of leaves, and a leaf
        # that forgot would file its writes under whatever ran last.
        FlowSource.surface = FlowSource::Surface::Cli
        run_run(subargs)
      when "wizard"
        run_wizard(subargs)
      when "tutorial"
        run_tutorial(subargs)
      when "mcp"
        FlowSource.surface = FlowSource::Surface::Mcp
        run_mcp(subargs)
      when "update"
        run_update(subargs)
      else
        STDERR.puts "Unknown command: #{subcmd}"
        print_main_help
        exit 1
      end
    rescue ex : IO::Error
      # `gori … | head` (or any reader that closes early) breaks the STDOUT pipe; a
      # well-behaved Unix filter exits quietly on EPIPE rather than dumping a backtrace. Here,
      # once, for every surface — it lived only in `gori run`, so `gori settings | true`,
      # `gori ca --pem | true` and `gori --help | true` backtraced. Anything else re-raises.
      raise ex unless ex.os_error == Errno::EPIPE
      exit 0
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
        # Everything past `--` belongs to someone else (`gori run shell -- CMD …`): a child's own
        # `--config FILE` must reach it untouched, not be eaten as gori's settings path.
        if arg == "--"
          rest.concat(argv[i..])
          break
        elsif arg == "--config"
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
      puts "  wizard    Interactive setup wizard (bind, theme, companion) — also runs on first launch"
      puts "  tutorial  Guided TUI tour with try-it steps (nav, menu, palette, edit, proxy, intercept)"
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
        p.invalid_option { |flag| abort CLI.unknown_option_message("gori tui", flag, p) }
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
                             "       gori settings import FILE [--sections a,b] [--dry-run]\n" \
                             "       gori settings env-syntax [bare|namespaced]\n" \
                             "       gori settings user-agents [--set FILE|- | --reset]\n" \
                             "       gori settings tls-fingerprint [HOST] [--json]"

    private SETTINGS_VERBS = {"export", "import", "sections", "env-syntax", "user-agents", "tls-fingerprint"}

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

    # Everything OptionParser did not claim: the unrecognised words BEFORE a `--` separator, AND
    # the run after it, which OptionParser strips and hands over as a SECOND list.
    #
    # Discarding that second list is a hole this file already closed once — `refuse_leftovers`
    # below carries the same fix for `gori wizard` / `gori tutorial`, and says why. `gori
    # settings` never got it, so a `--` switched every guard here back off, silently, at exit 0:
    # `gori settings -- --edit` printed the path with the flag dropped, `gori settings sections
    # -- foo` ignored the word, and `gori settings export -- team.json` dumped the profile to
    # stdout and created no file — verbatim the failure `reject_stray_args!` exists to stop,
    # reached by adding two characters. `import` needs the same join for the opposite reason:
    # there `--` means "the rest are FILENAMES", and dropping them made
    # `gori settings import -- ./--odd.json` unrunnable while
    # `gori settings import a.json -- b.json` imported one file, discarded the other, and
    # reported success — defeating the very `rest.size > 1` guard written to catch two files.
    #
    # Parses, and RETURNS the leftovers rather than acting on them, because the two callers act
    # on them oppositely (one refuses, one reads them as filenames) — and because the suite can
    # then drive this exact wiring, which is the only way an example can fail if the `after`
    # half is dropped again. Same split, for the same reason, as `parse_sections_value` under
    # `split_sections`: the guard itself ends in `abort`, and `abort` calls `exit`.
    private def self.stray_args(parser : OptionParser, args : Array(String)) : Array(String)
      rest = [] of String
      parser.unknown_args { |before, after| rest = before + after }
      parser.parse(args)
      rest
    end

    # Parse, then refuse any leftover positional. OptionParser silently DROPS unclaimed bare
    # words when no `unknown_args` handler is installed, and every `gori settings` verb but
    # `import` takes none — so `gori settings --edit export` opened the editor and dropped
    # `export`, `gori settings sections --help` printed the section list and never saw `--help`,
    # and `gori settings export team-profile.json` (a forgotten `-o`) dumped the profile to
    # stdout, created no file, and exited 0. `import` parses on its own because it does take a
    # positional; its own `rest.size > 1` guard is the same rule.
    private def self.reject_stray_args!(cmd : String, parser : OptionParser, args : Array(String)) : Nil
      rest = stray_args(parser, args)
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

    # Handler for `gori run` (the non-interactive CLI mode). Named run_run to match
    # the run_<subcommand> dispatch convention; the subcommand suite itself lives in
    # `Gori::CLI::Run` (src/gori/cli/run.cr).
    private def self.run_run(args : Array(String)) : Nil
      Run.dispatch(args)
    end

    # The `gori <cmd>` twin of `Run.parse_args`'s tail: build the parser, let the command
    # register its flags, then add `-h` (so `--help` lists it last) and the two refusals whose
    # OptionParser defaults RAISE past `CLI.run` as a backtrace. Returned unparsed, because the
    # callers parse it their own way (`stray_args`) and several print it as their usage.
    private def self.option_parser(prefix : String, & : OptionParser ->) : OptionParser
      OptionParser.new do |p|
        yield p
        p.on("-h", "--help", "Show this help") { puts p; exit 0 }
        p.invalid_option { |flag| abort CLI.unknown_option_message(prefix, flag, p) }
        p.missing_option { |flag| abort "missing value for #{flag}" }
      end
    end

    # Refuse any leftover with `message`'s text (nil accepts them). Installed as the
    # `unknown_args` handler, which runs BEFORE `invalid_option` (both fire for an undeclared
    # flag), so the message also sees a stray FLAG first. Reads both halves: `after` is the run
    # following a `--` separator, which OptionParser strips and hands over separately, and
    # discarding it left `gori wizard -- --port 9000` launching with the flag silently dropped.
    private def self.refuse_leftovers(p : OptionParser, &message : Array(String) -> String?) : Nil
      p.unknown_args { |before, after| (msg = message.call(before + after)) && abort(msg) }
    end

    # `gori wizard`, `gori tutorial` and `gori update` take no arguments at all. A stray flag
    # and a stray word are named apart so `gori wizard --port 9000` reads as the misplaced
    # `gori tui` flag it actually is.
    private def self.extra_args_error(cmd : String, rest : Array(String), parser : OptionParser) : String?
      return nil if (first = rest.first?).nil?
      return unknown_option_message("gori #{cmd}", first, parser) if first.starts_with?('-')
      "gori #{cmd} takes no arguments (got #{first.inspect})\nRun 'gori #{cmd} --help' for its options."
    end

    # Every `invalid_option` handler's message (#1389): the flag, the nearest one this parser
    # knows when there is one, and where the rest are. It used to be the flag followed by the
    # command's whole usage — dozens of lines to hunt a one-letter typo in, and the same wall on
    # every command. `note` is an extra hint a command owes this refusal (`run shell`'s `--`).
    #
    # The names come from the parser's own handler table (`@handlers`), so the suggestion can
    # only ever be a flag that command really takes. `spec/cli/unknown_option_spec.cr` holds
    # every handler to this helper.
    def self.unknown_option_message(prefix : String, flag : String, parser : OptionParser,
                                    note : String? = nil) : String
      msg = "#{prefix}: unknown option: #{Output.term_safe(flag)}"
      msg += " #{note}" if note
      if near = nearest_flag(flag, parser.@handlers.keys)
        msg += " — did you mean #{near}?"
      end
      "#{msg}\nRun '#{prefix} --help' for its options."
    end

    # The registered flag nearest to `flag` (its `=value` dropped), long flags only: a short one
    # is a single letter, where every other letter is "one edit away".
    def self.nearest_flag(flag : String, names : Array(String)) : String?
      name = flag.partition('=')[0]
      return nil unless name.starts_with?("--") && name.size > 2
      longs = names.select(&.starts_with?("--"))
      Levenshtein.find(name, longs, name.size < 6 ? 1 : 2)
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
    # address → theme → Miss Ring → review). It also runs automatically on first launch
    # (App#run_tui, when settings.json doesn't exist yet); this command re-runs it
    # anytime. Config-only — it edits settings.json + the live theme, so it sets up
    # its own terminal directly instead of going through App (which eagerly loads
    # the CA).
    private def self.run_wizard(args : Array(String)) : Nil
      # A real OptionParser, not a hand-rolled scan for -h: this used to IGNORE everything it
      # didn't recognise, so `gori wizard --port 9000` — which the help text below all but
      # invites, and which belongs to `gori tui` — was a silent no-op. Every other subcommand
      # aborts on an unknown flag; this one now does too.
      parser = option_parser("gori wizard") do |p|
        p.banner = "Usage: gori wizard\n" \
                   "  Interactive setup wizard: global proxy bind (default for projects), TUI theme, Miss Ring.\n" \
                   "  Runs automatically on first launch; use this to re-run it anytime.\n" \
                   "  Bind is the shared default — pin a different address per project in the Project tab;\n" \
                   "  `gori tui --listen/--port` override settings for one run only (not written to disk)."
        refuse_leftovers(p) { |rest| extra_args_error("wizard", rest, p) }
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
      parser = option_parser("gori tutorial") do |p| # same reasoning as run_wizard's: no silent no-ops
        p.banner = "Usage: gori tutorial\n" \
                   "  Interactive tour of gori's TUI on a mock UI: tab/pane navigation,\n" \
                   "  the command palette (^P), the action menu (space), edit mode\n" \
                   "  (READ/INS), the proxy and CA, capture and intercept. Each lesson asks\n" \
                   "  you to try the key; a practice step covers the moves, then help,\n" \
                   "  quitting and a first-session checklist.\n" \
                   "  Also offered at the end of `gori wizard`; safe to re-run anytime."
        refuse_leftovers(p) { |rest| extra_args_error("tutorial", rest, p) }
      end
      parser.parse(args)

      Paths.ensure_dirs
      Settings.load
      Tui::Theme.load_custom           # honour user themes so the mock matches the real UI
      Tui::Theme.apply(Settings.theme) # render the tour in the persisted theme
      term = Tui.open_terminal("run the tutorial directly, not under CI or a detached/background job")
      finished = with_tui_terminal(term) do
        term.enable_enhanced_keyboard # Kitty disambiguation (mirrors the wizard)
        term.enable_mouse             # always on for the tour: Prev/Next buttons + mock clicks
        tour = Tui::Tutorial.new(term)
        tour.run
        tour.finished?
      end
      # Finish drops back to the shell, and a silent prompt reads like a crash (#1382). Only on
      # Finish: esc/^C is someone leaving, not someone asking what comes next.
      puts "next: run `gori` to open a project" if finished
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
          puts "  • Chocolatey         — print choco upgrade gori -y (run it with gori closed)"
          puts "  • pacman/AUR         — print yay/paru/pacman guidance"
          puts "  • deb (dpkg)         — print apt upgrade guidance"
          puts "  • rpm                — print dnf/yum/zypper guidance"
          puts ""
          puts "System paths under /usr/bin are classified by package ownership"
          puts "(pacman -Qo / dpkg-query -S / rpm -qf) and /etc/os-release."
          exit 0
        end
        p.invalid_option { |flag| abort CLI.unknown_option_message("gori update", flag, p) }
        # `gori update` takes no positional arguments, and `--exec` is its only
        # flag — so a `--` separator has nothing legitimate to protect. Without
        # this, `gori update -- --exec` parsed clean and silently dropped the
        # flag, and `gori update whatever` ran a full self-update on a typo. Same
        # failure, same guard, as `gori wizard` / `gori tutorial`.
        refuse_leftovers(p) { |rest| extra_args_error("update", rest, p) }
      end
      parser.parse(args)
      begin
        Settings.load
        Update.run(exec_package_commands: exec_pkg)
      rescue ex : Error
        abort "gori update: #{ex.message}"
      end
    end
  end
end
