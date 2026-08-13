# `gori ca` — the root-CA utility surface: show, regenerate, import. Reopens Gori::CLI;
# the argv dispatch that reaches these lives in cli.cr. Two of the three verbs are
# destructive and each confirms before it acts.
module Gori::CLI
  # `gori ca` is the CA utility surface:
  # - bare / flags  → print path (default) or PEM (`--pem`); creates CA on first use
  # - `regenerate`  → replace the root CA (destructive; needs --yes or an interactive confirm)
  # - `import`      → adopt an externally-created root CA (cert + key PEM); destructive
  #
  # A verb is recognised in FIRST position only. Written after a flag it reaches the show
  # path as a leftover positional, where ca_leftover_error names the ordering instead of
  # letting the destructive verb evaporate.
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

  # Every `gori ca` verb. Named here because the leftover check below has to tell a DROPPED
  # verb from ordinary junk, and because the usage error lists them.
  private CA_VERBS = {"regenerate", "import"}

  # The usage error a leftover positional earns, or nil to proceed. None of the three `gori
  # ca` parsers takes a positional, and all three silently DISCARDED one — the same failure
  # `Run.list_leftover_error` exists for, in the same shape (a pure function, so the decision
  # and the wording are spec-able; `abort` is not).
  #
  # The case that matters: `gori ca --ca-dir=DIR regenerate`. `run_ca` only recognises a verb
  # in FIRST position, so with a flag in front of it the verb fell through to the show path,
  # where the parser dropped it — gori printed the CA path and exited 0, having regenerated
  # NOTHING. A destructive command that silently no-ops with a success status is the worst
  # failure mode a scripted surface has, and here it also reads as confirmation (`gori ca`
  # prints exactly the same line on success). `gori ca regenerate --yes stray` and `gori ca
  # import --cert C --key K stray` swallowed their leftovers the same way.
  #
  # Deliberately NOT solved by scanning argv for a verb in any position: `--ca-dir regenerate`
  # (the space form, a directory actually named `regenerate`) would then be read as the verb.
  # By the time OptionParser hands over leftovers it has already consumed every flag VALUE, so
  # a leftover here is unambiguously a positional the operator meant as a word.
  def self.ca_leftover_error(cmd : String, leftover : Array(String)) : String?
    return nil if (first = leftover.first?).nil?
    if cmd == "ca" && CA_VERBS.includes?(first)
      return "gori ca: '#{first}' must come FIRST, before the flags — " \
             "`gori ca #{first} [flags]`, not `gori ca [flags] #{first}` " \
             "(nothing was #{first == "import" ? "imported" : "regenerated"})"
    end
    "gori #{cmd}: unexpected argument #{first.inspect} — `gori #{cmd}` takes no positional " \
    "arguments#{cmd == "ca" ? " (verbs: #{CA_VERBS.join(", ")})" : ""}"
  end

  # Wire the leftover check into a `gori ca` parser. `after` is the run following a `--`
  # separator, which OptionParser strips and hands over separately; it is junk here too, so
  # both halves are checked (mirrors reject_extra_args).
  private def self.reject_ca_leftovers(cmd : String, p : OptionParser) : Nil
    p.unknown_args do |before, after|
      (msg = ca_leftover_error(cmd, before + after)) && abort("#{msg}\n#{p}")
    end
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
      reject_ca_leftovers("ca", p)
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
      # `gori ca` is the CA's diagnostic command, so it is where a pair that LOADS but cannot
      # serve gets named — nothing else ever says it, and the symptom shows up only at the
      # client (see CertAuthority#usability_error). Reported after the answer, on stderr, and
      # non-fatally: the path it printed is still correct, and `gori ca --pem | …` pipelines
      # keep working.
      begin
        if problem = ca.usability_error
          STDERR.puts "gori ca: WARNING — the root CA in #{ca_dir} is unusable: #{problem}. " \
                      "Clients will reject every certificate gori mints. Run " \
                      "`gori ca regenerate` (or `gori ca import`) to install a working pair, " \
                      "then re-trust it."
        end
      rescue
        # Its own guard, or "non-fatally" above would be a lie: this block sits INSIDE the
        # rescue that aborts, so anything raised while merely INSPECTING the CA would turn a
        # `gori ca` that had already printed the right path into exit 1. A diagnostic that
        # cannot run is not a reason to fail the command the operator actually asked for.
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
      reject_ca_leftovers("ca regenerate", p)
    end
    parser.parse(args)

    confirm_ca_regenerate!(ca_dir) unless yes

    begin
      Paths.ensure_dirs
      # regenerate_at, NOT load_or_create + regenerate!: a rotation does not need the old
      # pair, and requiring it made this command unusable in exactly the state it is the
      # documented repair for — a half-present pair, whose own error message says to run
      # `gori ca regenerate`. See CertAuthority.regenerate_at.
      puts Proxy::Tls::CertAuthority.regenerate_at(ca_dir)
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
      reject_ca_leftovers("ca import", p)
    end
    parser.parse(args)

    cert = cert_path
    key = key_path
    abort "gori ca import: --cert and --key are both required\n#{parser}" unless cert && key

    # Validate the pair up front so a bad --cert/--key aborts BEFORE the confirm prompt and
    # before anything is written — the user asked for THEIR cert, not a surprise
    # gori-generated one. import_at validates again on the real read; this pass is what keeps
    # the operator from typing `import` at a prompt for a pair that was never going to work.
    begin
      Proxy::Tls::CertAuthority.validate_pem_pair(cert, key)
    rescue ex
      abort "gori ca import: #{ex.message}"
    end

    confirm_ca_import!(ca_dir) unless yes

    begin
      Paths.ensure_dirs
      # import_at, NOT load_or_create + import!: an import REPLACES the root outright, so
      # loading the old one first only added failure modes — it refused a half-present pair
      # (the state an import is a perfectly good fix for) and, in a fresh dir, minted a gori
      # root just to overwrite it a moment later. See CertAuthority.import_at.
      path, warning = Proxy::Tls::CertAuthority.import_at(ca_dir, cert, key)
      puts path
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
end
