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
      when "info"
        run_ca_info(args[1..])
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
    io.puts "       gori ca info [--json] [--ca-dir=DIR]"
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
    io.puts "  --der          Write the certificate DER instead (Android, Windows, MDM installers)"
    io.puts "  -o, --out=FILE With --pem or --der: write to FILE (gori ca --der -o gori-ca.crt)"
    io.puts "  -h, --help     Show this help"
    io.puts ""
    io.puts "Info options:"
    io.puts "  --json         Emit subject, validity, SHA-256, SPKI pin and Android hash as JSON"
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
  # Each verb and the past tense of what it did, for "nothing was …" below.
  private CA_VERBS = {"regenerate" => "regenerated", "import" => "imported", "info" => "printed"}

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
    if cmd == "ca" && CA_VERBS.has_key?(first)
      return "gori ca: '#{first}' must come FIRST, before the flags — " \
             "`gori ca #{first} [flags]`, not `gori ca [flags] #{first}` " \
             "(nothing was #{CA_VERBS[first]})"
    end
    "gori #{cmd}: unexpected argument #{first.inspect} — `gori #{cmd}` takes no positional " \
    "arguments#{cmd == "ca" ? " (verbs: #{CA_VERBS.keys.join(", ")})" : ""}"
  end

  # Wire the leftover check into a `gori ca` parser, both halves (see `refuse_leftovers`).
  private def self.reject_ca_leftovers(cmd : String, p : OptionParser) : Nil
    refuse_leftovers(p) { |rest| ca_leftover_error(cmd, rest).try { |msg| "#{msg}\n#{p}" } }
  end

  # Path / PEM / DER print path (the default `gori ca` action).
  private def self.run_ca_show(args : Array(String)) : Nil
    ca_dir = Paths.default_ca_dir
    pem = false
    der = false
    out_path = nil.as(String?)
    parser = OptionParser.new do |p|
      p.banner = "Usage: gori ca [options]\n       gori ca info [--json] [--ca-dir=DIR]\n       gori ca regenerate [--yes] [--ca-dir=DIR]\n       gori ca import --cert FILE --key FILE [--yes] [--ca-dir=DIR]"
      p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
      p.on("--pem", "Print the certificate PEM to stdout instead of the path") { pem = true }
      p.on("--der", "Write the certificate DER instead of the path (with -o FILE, or to a redirected stdout)") { der = true }
      p.on("-o FILE", "--out=FILE", "With --pem or --der: write the certificate to FILE instead of stdout") { |v| out_path = v }
      p.on("-h", "--help", "Show this help") { print_ca_usage(STDOUT); exit 0 }
      p.invalid_option { |flag| abort CLI.unknown_option_message("gori ca", flag, p) }
      p.missing_option { |flag| abort "missing value for #{flag}" }
      reject_ca_leftovers("ca", p)
    end
    parser.parse(args)
    # Before the load, so a first `gori ca --der` does not create a CA only to refuse to print it.
    ca_show_flag_error(pem, der, out_path, STDOUT.tty?).try { |msg| abort msg }
    emit_ca_cert(load_ca_with_diagnosis(ca_dir), pem, der, out_path)
  end

  # Why `gori ca`'s output flags cannot run together, or nil. Binary on a terminal is noise at
  # best and an escape sequence at worst; `-o`, not `>`, is the advice because PowerShell before
  # 7.4 re-encodes a native command's redirected bytes as text, which corrupts a DER file.
  def self.ca_show_flag_error(pem : Bool, der : Bool, out_path : String?, stdout_tty : Bool) : String?
    return "gori ca: --pem and --der are two encodings of one certificate; pick one" if pem && der
    return "gori ca: -o needs --pem or --der to say which encoding to write" if out_path && !pem && !der
    "gori ca --der: stdout is a terminal; write it to a file (gori ca --der -o gori-ca.crt)" if der && !out_path && stdout_tty
  end

  # Outside the diagnosis's rescue: a closed stdout is not a CA that could not be read.
  private def self.emit_ca_cert(ca : Proxy::Tls::CertAuthority, pem : Bool, der : Bool, out_path : String?) : Nil
    if path = out_path
      begin
        File.write(path, der ? ca.ca_cert_der : ca.ca_cert_pem.to_slice)
      rescue ex : IO::Error
        abort "gori ca: could not write #{path}: #{ex.message}"
      end
      STDERR.puts "gori ca: wrote #{der ? "DER" : "PEM"} certificate to #{path}"
    elsif pem
      # PEM files usually already end with a newline; don't double them.
      print ca.ca_cert_pem
      STDOUT.flush
    elsif der
      STDOUT.write(ca.ca_cert_der)
      STDOUT.flush
    else
      puts ca.ca_cert_path
    end
  end

  # What a trust store or a device shows about the root, so the operator can tell it is the
  # one gori signs with: subject, validity, the SHA-256 the OS viewers print, Chromium's SPKI
  # pin, and the hash-named file Android's system store wants.
  private def self.run_ca_info(args : Array(String)) : Nil
    ca_dir = Paths.default_ca_dir
    json = false
    parser = option_parser("gori ca info") do |p|
      p.banner = "Usage: gori ca info [--json] [--ca-dir=DIR]"
      p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
      p.on("--json", "Emit the details as JSON") { json = true }
      reject_ca_leftovers("ca info", p)
    end
    parser.parse(args)

    # Never minted here: `info` is how an operator confirms which root they trusted, and a fresh
    # one in a mistyped --ca-dir would answer with a fingerprint nobody has ever trusted.
    unless File.exists?(File.join(ca_dir, Proxy::Tls::CertAuthority::CA_CERT_FILE)) ||
           File.exists?(File.join(ca_dir, Proxy::Tls::CertAuthority::CA_KEY_FILE))
      abort "gori ca info: no root CA in #{ca_dir} — `gori ca` creates one there"
    end
    ca = load_ca_with_diagnosis(ca_dir)
    cert = ca.cert
    info = ca_info(ca.ca_cert_path, cert.subject, cert.not_before, cert.not_after,
      cert.sha256_fingerprint, ca.spki_sha256_base64, "#{cert.subject_hash_old}.0")
    json ? puts(info.to_json) : print_ca_info(STDOUT, info)
  end

  # The fields `gori ca info` reports, split from the cert so the shape is testable on plain
  # values. `days_left` counts whole days toward zero (2.5 left and 2.5 ago are both 2), going
  # negative once the root has expired; a root whose notBefore is still ahead (clock skew, or
  # an imported root dated forward) is `not_yet_valid`, which clients reject just the same.
  def self.ca_info(path : String, subject : String, not_before : Time, not_after : Time,
                   sha256 : String, spki : String, android : String, now : Time = Time.utc)
    {path: path, subject: subject,
     not_before: not_before.to_rfc3339, not_after: not_after.to_rfc3339,
     expired: not_after <= now, not_yet_valid: not_before > now,
     days_left: (not_after - now).total_days.to_i,
     sha256: sha256, spki_sha256: spki, android_file: android}
  end

  def self.print_ca_info(io : IO, info) : Nil
    left = info[:days_left]
    validity = if info[:expired]
                 "EXPIRED #{left.zero? ? "less than a day" : "#{-left} day(s)"} ago — `gori ca regenerate` or `gori ca import` a new root"
               elsif info[:not_yet_valid]
                 "NOT YET VALID — clients reject it until then; check this machine's clock"
               else
                 "#{left} day(s) left"
               end
    io.puts "path         #{info[:path]}"
    # term_safe: OpenSSL escapes C0 controls but passes C1 (U+009B is a one-character CSI) and
    # the bidi overrides, and an imported root's subject is someone else's text.
    io.puts "subject      #{Output.term_safe(info[:subject])}"
    io.puts "valid        #{info[:not_before]} → #{info[:not_after]} (#{validity})"
    io.puts "sha256       #{info[:sha256]}"
    io.puts "spki-sha256  #{info[:spki_sha256]}"
    io.puts "android      #{info[:android_file]} (system store file name)"
  end

  # Load (creating on first use) the CA, then name a pair that LOADS but cannot serve. `gori
  # ca` is the CA's diagnostic command, so it is where that gets said — nothing else ever says
  # it, and the symptom shows up only at the client (see CertAuthority#usability_error). On
  # stderr, non-fatally, and BEFORE the answer: a closed stdout ends the process at the print,
  # and must not swallow it.
  private def self.load_ca_with_diagnosis(ca_dir : String) : Proxy::Tls::CertAuthority
    begin
      Paths.ensure_dirs
      ca = Proxy::Tls::CertAuthority.load_or_create(ca_dir)
    rescue ex
      abort "gori ca: could not create/read the CA in #{ca_dir}: #{ex.message}"
    end
    begin
      if problem = ca.usability_error
        STDERR.puts "gori ca: WARNING — the root CA in #{ca_dir} is unusable: #{problem}. " \
                    "Clients will reject every certificate gori mints. Run " \
                    "`gori ca regenerate` (or `gori ca import`) to install a working pair, " \
                    "then re-trust it."
      elsif (gaps = ca.strict_verify_gaps).present?
        STDERR.puts "gori ca: note — #{Proxy::Tls::CertAuthority.strict_verify_warning(gaps)}. " \
                    "Run `gori ca regenerate` to mint a root that has them, then re-trust it."
      end
    rescue
      # A diagnostic that cannot run is not a reason to fail the command the operator
      # actually asked for.
    end
    ca
  end

  # Replace the on-disk root CA. Destructive: voids every prior client trust entry.
  # A *running* gori process keeps the old CA in memory until restart — warn on stderr.
  # Confirmation mirrors the TUI (type "regenerate", or pass --yes for scripts/CI).
  private def self.run_ca_regenerate(args : Array(String)) : Nil
    ca_dir = Paths.default_ca_dir
    yes = false
    parser = option_parser("gori ca regenerate") do |p|
      p.banner = "Usage: gori ca regenerate [--yes] [--ca-dir=DIR]"
      p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
      p.on("-y", "--yes", "Skip the interactive confirm") { yes = true }
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
      path = Proxy::Tls::CertAuthority.regenerate_at(ca_dir)
    rescue ex
      abort "gori ca regenerate: could not replace the CA in #{ca_dir}: #{ex.message}"
    end
    # Reported OUTSIDE the rescue: the CA is already replaced, and a closed stdout (`| true`)
    # used to read as "could not replace", inviting a script to rotate it again. The stderr
    # note goes first so a closed stdout cannot swallow it.
    STDERR.puts "gori ca: regenerated — re-trust clients; restart any running gori"
    puts path
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
    parser = option_parser("gori ca import") do |p|
      p.banner = "Usage: gori ca import --cert FILE --key FILE [--yes] [--ca-dir=DIR]"
      p.on("--cert FILE", "Root CA certificate PEM to adopt") { |v| cert_path = v }
      p.on("--key FILE", "Matching private key PEM") { |v| key_path = v }
      p.on("--ca-dir=DIR", "Directory for the root CA") { |v| ca_dir = v }
      p.on("-y", "--yes", "Skip the interactive confirm") { yes = true }
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
    rescue ex
      abort "gori ca import: could not install the CA in #{ca_dir}: #{ex.message}"
    end
    # Outside the rescue and stderr first, as in regenerate: the import has already happened.
    STDERR.puts "gori ca: WARNING — #{warning}" if warning
    STDERR.puts "gori ca: imported — re-trust the imported cert; restart any running gori"
    puts path
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
