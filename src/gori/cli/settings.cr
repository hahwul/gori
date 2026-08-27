require "../proxy/tls/fingerprint"
require "../proxy/upstream"

# `gori settings` — inspect, export and import the settings file. Reopens Gori::CLI;
# the argv dispatch that reaches these lives in cli.cr. Export refuses to write over the
# live settings file, and import is section-scoped.
module Gori::CLI
  private def self.run_settings(args : Array(String)) : Nil
    return if dispatch_settings_verb(args)
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
    Settings.load # pick up the persisted editor pref + existing values
    path = Settings.path
    # Lazily materialize with current defaults. `save` REPORTS failure rather than raising (a
    # failed write must not crash the TUI), and discarding that here printed a path to a file
    # that is not there and exited 0 — then `--edit` opened an editor on it, so the operator
    # typed a config into a location gori had already found unwritable and learned about it
    # from `:wq`. Not fatal: the path itself is still the honest answer to `gori settings`,
    # and $EDITOR may yet be able to write where gori's temp+rename could not.
    unless File.exists?(path) || Settings.save
      STDERR.puts "gori settings: could not create #{path} (check the directory's permissions" \
                  " and free space) — the path below is where it would go"
    end

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

  # Run the named sub-verb, if `args` opens with one. Split out of `run_settings` so that
  # command's own flag parsing is not a `case` with a tail hanging off it, and so adding a verb
  # does not push a method that also does the parsing further over its branch budget.
  private def self.dispatch_settings_verb(args : Array(String)) : Bool
    case args[0]?
    when "export"          then run_settings_export(args[1..])
    when "import"          then run_settings_import(args[1..])
    when "sections"        then run_settings_sections(args[1..])
    when "tls-fingerprint" then run_settings_tls_fingerprint(args[1..])
    else                        return false
    end
    true
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
    # Before the note below and before the document is built: a refusal should not arrive
    # underneath a line about what the export was going to contain.
    out.try { |target| refuse_export_over_settings!(target) }
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

  # `-o` aimed at the LIVE settings file is data loss wearing an export's clothes, so refuse
  # it outright.
  #
  # A profile is deliberately NOT a snapshot: `export_document` omits every section sitting at
  # its factory default, and omits SECRET_SECTIONS entirely unless they were named. Writing
  # that back over settings.json therefore DELETES the sections it left out — `env` and its
  # token VALUES, the decoder chains — in place, prints "wrote <path>", and exits 0. Nothing
  # recovers it either: `write_export` is a plain truncate-and-write, not the atomic
  # temp+rename 3-way merge every other writer of this file goes through, so there is no
  # `.corrupt` copy and no concurrent-instance merge to put the section back.
  #
  # `-o "$GORI_CONFIG"` is an easy thing to type when the point of the export is to move a
  # config, and the failure is invisible until the next run comes up without the token.
  private def self.refuse_export_over_settings!(target : String) : Nil
    return unless same_file?(target, Settings.path)
    omitted = Settings::SECRET_SECTIONS.join(" and ")
    abort "gori settings export: -o #{target} is your live settings file (#{Settings.path}).\n" \
          "An export omits every section at its factory default — and #{omitted} unless " \
          "--sections names them — so writing it back would DELETE those sections, not " \
          "update them. Export to a different path."
  end

  # Whether two paths name the same file, with `..`, a relative path and a symlink all
  # resolved — `-o ./settings.json` from inside GORI_HOME, and an `-o` through a symlinked
  # config directory, are the same overwrite as spelling the path out in full.
  #
  # `File.realpath` raises on a path that does not exist yet, which is the ORDINARY case for
  # an export target — so fall back to resolving the parent directory (that does exist) and
  # keeping the basename. A path whose parent is missing too resolves to itself: it cannot
  # collide with a settings file that loaded, and the write is about to fail on its own terms.
  private def self.same_file?(a : String, b : String) : Bool
    canonical_path(a) == canonical_path(b)
  end

  private def self.canonical_path(p : String) : String
    abs = File.expand_path(p)
    begin
      File.realpath(abs)
    rescue
      dir = File.dirname(abs)
      resolved = begin
        File.realpath(dir)
      rescue
        dir
      end
      File.join(resolved, File.basename(abs))
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
        # Best-effort, exactly like Settings.write_private, and exactly what the paragraph
        # above promises: a raising chmod aborted the whole export — AFTER `File.open` had
        # already truncated the target — so the filesystem this was written to tolerate turned
        # a working export into a destroyed file. Swallowing it hides nothing: the mode is
        # read back below, and the WARNING branch there is what tells the operator the file is
        # unprotected.
        (File.chmod(path, perm) rescue nil) unless secrets.empty?
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
    # Same leftovers as every other verb, read as FILENAMES instead of refused — `--` carries
    # its POSIX meaning here. See `stray_args` for both halves of what dropping its run cost.
    rest = stray_args(parser, args)

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

  # `gori settings tls-fingerprint [HOST]` — the JA3/JA4 of the ClientHello gori actually
  # sends, per destination (#822).
  #
  # This exists because the `outbound_tls` fingerprint knobs are otherwise unverifiable: an
  # operator sets `groups` or `preset: "chrome"` and OpenSSL will only ever report what got
  # NEGOTIATED, never the offer it made — and the offer is the thing an anti-bot stack judges.
  # The report is built from the SAME context a dial builds (`Upstream.context_for`), so it
  # cannot drift into describing a handshake gori does not make.
  #
  # TWO legs per policy, and neither is redundant. gori offers `h2` on a tunnelled MITM
  # connection and offers no ALPN at all on a leg it will speak HTTP/1.1 on (the forward-proxy
  # dial, the Repeater, WebSocket), so those legs genuinely carry different ClientHellos — and
  # an operator comparing one JA3 against a browser's would otherwise never learn which of the
  # two they were looking at.
  private def self.run_settings_tls_fingerprint(args : Array(String)) : Nil
    json = false
    parser = OptionParser.new do |p|
      p.banner = "Usage: gori settings tls-fingerprint [HOST] [--json]\n\n" \
                 "  With no HOST, reports every outbound_tls rule plus the no-rule default.\n" \
                 "  With a HOST, reports the single policy that host would actually get."
      p.on("--json", "Emit the report as JSON (includes the decomposed JA3 string and JA4_r)") { json = true }
      p.on("-h", "--help", "Show this help") { puts p; exit 0 }
      p.invalid_option { |flag| abort "unknown option: #{flag}\n#{p}" }
      p.missing_option { |flag| abort "missing value for #{flag}" }
    end
    rest = stray_args(parser, args)
    if rest.size > 1
      abort "gori settings tls-fingerprint: one HOST at a time (got #{rest.join(", ")})\n#{parser}"
    end

    Settings.load
    abort_on_degraded_settings!("tls-fingerprint")
    entries = tls_fingerprint_entries(rest.first?)
    json ? puts(tls_fingerprint_json(entries)) : print_tls_fingerprints(entries)
  end

  # One reported policy: the pattern it is filed under, the rule, and whether the caller
  # asked about a specific host (which changes the heading from "rule" to "this is what that
  # host gets").
  # `configured?` false marks the SYNTHETIC no-rule row. It is not decoration: that row's rule
  # is `DEFAULT_OUTBOUND_TLS`, whose host is `"*"`, so without the flag `--json` would emit
  # `"host": "*"` for a catch-all rule that is not in anyone's settings.json and a consumer
  # keying on `host` could not tell the two apart.
  private record TlsFingerprintEntry,
    label : String,
    rule : Settings::OutboundTlsRule,
    configured : Bool do
    def configured? : Bool
      configured
    end

    # What to call this policy in a message. The pattern for a real rule; the whole label for
    # the synthetic row, where `"*"` would name a rule that does not exist.
    def name : String
      configured ? rule.host : label
    end
  end

  private def self.tls_fingerprint_entries(host : String?) : Array(TlsFingerprintEntry)
    if h = host
      rule = Settings.outbound_tls_for(h)
      matched = Settings.outbound_tls.includes?(rule)
      return [TlsFingerprintEntry.new(
        matched ? "#{h}  (matched rule #{rule.host.inspect})" : "#{h}  (no rule — OpenSSL defaults)",
        rule, matched)]
    end
    entries = [] of TlsFingerprintEntry
    # The no-rule policy is listed only when a dial could actually GET it. A `*` rule is the
    # documented catch-all, so once one exists every host matches a row below and printing the
    # OpenSSL defaults too would invite the operator to read a fingerprint gori never sends.
    unless Settings.outbound_tls.any? { |r| r.host.strip == "*" }
      entries << TlsFingerprintEntry.new("(no matching rule — OpenSSL defaults)",
        Settings::DEFAULT_OUTBOUND_TLS, false)
    end
    Settings.outbound_tls.each { |r| entries << TlsFingerprintEntry.new(r.host, r, true) }
    entries
  end

  # The two legs a policy is reported for. The label is the operator's word for the leg, not
  # the code's: "tunnelled" is the decrypted CONNECT/transparent path, "forced HTTP/1.1" is
  # every dial where gori will speak h1 and therefore must not let an origin pick h2.
  private TLS_FINGERPRINT_LEGS = [{"tunnelled (gori offers h2)", "h2"}, {"forced HTTP/1.1", nil}]

  private def self.print_tls_fingerprints(entries : Array(TlsFingerprintEntry)) : Nil
    puts "Outbound TLS fingerprint — the ClientHello an origin sees when gori dials it."
    entries.each do |entry|
      puts
      puts entry.label
      print_tls_policy_fields(entry.rule)
      TLS_FINGERPRINT_LEGS.each do |(leg, alpn)|
        offer = Proxy::Tls::ClientShape.alpn_offer(alpn, entry.rule.effective_alpn)
        puts "  #{leg} — ALPN #{offer ? offer.join(", ") : "not offered"}"
        report = tls_fingerprint_report(entry, alpn)
        unless report
          puts "    (this OpenSSL produced no ClientHello for that policy)"
          next
        end
        # Digest, then the list it hashes indented under it. The digest is what an operator
        # pastes into a fingerprint database; the raw form underneath is the only way to see
        # WHICH field a setting moved, and a digest with nothing to decompose it is not
        # evidence.
        puts "    JA3  #{report.ja3}"
        puts "         #{report.ja3_text}"
        puts "    JA4  #{report.ja4}"
        puts "         #{report.ja4_r}"
      end
    end
    puts
    puts TLS_FINGERPRINT_NOTE
  end

  private def self.print_tls_policy_fields(rule : Settings::OutboundTlsRule) : Nil
    alpn = rule.effective_alpn
    # An unknown name is kept verbatim by the loader (so the startup warning can name it), so
    # say so here too — every other line below would otherwise read as the preset's doing.
    preset = rule.preset.presence
    preset = "#{preset}  (unknown preset — nothing from it is applied)" if preset && rule.preset_profile.nil?
    puts "  #{"preset".ljust(15)} #{preset || "(none)"}"
    {
      "groups"              => rule.effective_groups.presence,
      "sigalgs"             => rule.effective_sigalgs.presence,
      "ciphers (\u22641.2)" => rule.effective_ciphers.presence,
      "ciphersuites"        => rule.effective_ciphersuites.presence,
    }.each { |name, value| puts "  #{name.ljust(15)} #{value || "(OpenSSL default)"}" }
    # Not "(OpenSSL default)": OpenSSL has no ALPN default. With nothing configured the offer
    # is whatever the CALLING path asked for, which is what the per-leg lines below report.
    puts "  #{"alpn".ljust(15)} #{alpn.empty? ? "(not configured — see the per-leg offer below)" : alpn.join(", ")}"
    puts "  #{"session tickets".ljust(15)} #{rule.effective_session_tickets? ? "on" : "off"}"
    puts "  #{"OCSP stapling".ljust(15)} #{rule.effective_ocsp_stapling? ? "requested" : "not requested"}"
  end

  # P4, stated where it cannot be missed: a preset is an approximation, and the two things it
  # cannot reach are named rather than hinted at. An operator comparing this JA3 against a
  # browser's will find it different, and needs to know that is expected and why.
  private TLS_FINGERPRINT_NOTE =
    "Presets approximate a browser's VALUES — cipher, group and signature-algorithm order, the\n" \
    "TLS 1.3 suites, the ALPN list, and whether session_ticket / status_request appear at all.\n" \
    "They do NOT reproduce a browser's JA3 byte for byte: extension ORDER and GREASE placement\n" \
    "are OpenSSL's own and cannot be set from it. Compare the JA4_r lists, not the digests."

  private def self.tls_fingerprint_report(entry : TlsFingerprintEntry,
                                          alpn : String?) : Proxy::Tls::Fingerprint::Report?
    Proxy::Tls::Fingerprint.of_context(
      Proxy::Upstream.context_for_policy(entry.rule, Settings.verify_upstream?, alpn))
  rescue ex
    # A `groups`/`sigalgs`/`ciphersuites` string this OpenSSL refuses is the one way to get
    # here, and it is exactly what this command is for: say which policy cannot be built,
    # instead of printing a backtrace over the rules that can.
    STDERR.puts "gori settings tls-fingerprint: #{entry.name}: #{ex.message}"
    nil
  end

  private def self.tls_fingerprint_json(entries : Array(TlsFingerprintEntry)) : String
    JSON.build(indent: 2) do |j|
      j.array do
        entries.each do |entry|
          rule = entry.rule
          j.object do
            # null, not `"*"`, for the synthetic no-rule row — see TlsFingerprintEntry.
            j.field "host", entry.configured? ? rule.host : nil
            j.field "configured", entry.configured?
            j.field "label", entry.label
            j.field "preset", rule.preset
            j.field "groups", rule.effective_groups
            j.field "sigalgs", rule.effective_sigalgs
            j.field "ciphers", rule.effective_ciphers
            j.field "ciphersuites", rule.effective_ciphersuites
            j.field "alpn" { j.array { rule.effective_alpn.each { |p| j.string p } } }
            j.field "session_tickets", rule.effective_session_tickets?
            j.field "ocsp_stapling", rule.effective_ocsp_stapling?
            j.field "legs" do
              j.array do
                TLS_FINGERPRINT_LEGS.each do |(leg, leg_alpn)|
                  report = tls_fingerprint_report(entry, leg_alpn)
                  j.object do
                    j.field "leg", leg
                    offer = Proxy::Tls::ClientShape.alpn_offer(leg_alpn, rule.effective_alpn)
                    j.field "alpn_offered" { j.array { (offer || [] of String).each { |p| j.string p } } }
                    if report
                      j.field "ja3", report.ja3
                      j.field "ja3_text", report.ja3_text
                      j.field "ja4", report.ja4
                      j.field "ja4_r", report.ja4_r
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
