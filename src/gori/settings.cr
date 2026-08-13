require "json"
require "./paths"
require "./settings/network"
require "./settings/upstream_rules"
require "./settings/outbound_tls"
require "./settings/retention"
require "./settings/listeners"
require "./settings/env"
require "./settings/scan_rules"
require "./settings/oast_providers"
require "./settings/display"
require "./settings/companion"
require "./settings/tabs"
require "./settings/keymap"
require "./settings/decoder"
require "./settings/rewriter"
require "./settings/colormarker"
require "./settings/miner"
require "./settings/probe"
require "./settings/discover"
require "./settings/update"
require "./settings/fuzzer"

module Gori
  # Global, persisted user settings — the editable runtime CONFIG for one gori
  # process (the `settings:*` command-palette entries control this). Currently the
  # NETWORK section (proxy bind + upstream proxy), the EDITOR (external ^E editor),
  # and the TUI THEME. Hotkeys are TODO. Persisted as JSON at <config_dir>/settings.json.
  #
  # Loaded once at startup (CLI flags then override the bind in memory); the
  # Settings UI edits these class properties and calls `save`. `upstream_proxy` is
  # read live by Upstream.dial, so changing it applies immediately; `bind_host`/
  # `bind_port` are applied by App on the next project open (the live proxy keeps
  # its current bind).
  #
  # The module body is split across src/gori/settings/*.cr, each reopening
  # `module Gori::Settings` with one section's class_property declarations plus its
  # parse_*/serialize_*/save_* helpers (see each file's header comment for its
  # section). This file keeps only the orchestration shared by every section: path
  # resolution, load, save, the 3-way merge-with-disk, the top-level serialize
  # dispatcher, and the couple of generic JSON-parsing helpers (load_bool/
  # load_bool_h/normalize_os) reused across sections.
  module Settings
    # THIS process's own serialization of the state it last read from (or wrote to) disk;
    # nil = never loaded. It's the 3-way-merge BASE at save time: a top-level section this
    # process didn't change (in-memory == base) yields to whatever is on disk now, so a
    # concurrent writer's unrelated edit isn't clobbered by this process persisting one
    # unrelated field.
    #
    # SERIALIZATION, not the raw file text, and that distinction is the whole guarantee.
    # `mine` is always gori's canonical form, so basing on the operator's raw text makes the
    # test "is my form of this section byte-identical to how they happened to write it?" —
    # which is false for every section written in a valid but non-canonical spelling
    # (`listeners` entries omitting the defaulted `"mode"`, a key gori does not know, a
    # `target_port: 0` gori drops). Such a section then reads as "this process changed it",
    # so gori WINS the merge and a hand edit made in between is silently deleted. That is
    # exactly the clobber `listener_error`'s `among:` comment (settings/listeners.cr) and
    # #508 are written around, reached through the base rather than through a write-back.
    @@loaded_raw : String? = nil

    # `load` read a file but could not finish applying it: some section raised and every
    # section BELOW it is sitting at its factory default. While this is set, `save` refuses —
    # a document assembled from half the operator's file and half the factory defaults must
    # never be written back over the real one, whatever the merge would do with it.
    #
    # A separate flag rather than a nil base, because the base protects nothing here: with
    # base = the raw text, an abandoned section is either absent from `serialize` (chosen nil
    # → dropped) or holds a default (!= base → "mine wins"), so the 3-way merge deletes the
    # same sections it would delete with no base at all. The only safe answer is not to write.
    # Contrast the unparseable-file path (`load_root`), where nothing was applied from disk at
    # all and the next save is a deliberate clean write.
    @@load_partial = false

    # An explicit settings file for THIS process (`gori --config PATH`), overriding both
    # $GORI_CONFIG and the default under GORI_HOME. Set once from CLI.run before any
    # subcommand dispatch, so every surface — TUI, `gori run`, `gori mcp` — reads the same
    # file. Orthogonal to GORI_HOME on purpose: pointing at a different config must not also
    # relocate the CA, the project databases, the themes and the wordlists, which is the only
    # thing GORI_HOME could do before this.
    @@path_override : String? = nil

    def self.path_override=(p : String?) : String?
      @@path_override = p.try(&.presence)
    end

    # The `--config PATH` this process was started with, or nil. Distinct from `path`, which
    # answers where settings live after every fallback: a surface that has to REPRODUCE the
    # invocation (`gori mcp --install-*` writing the argv a client will spawn) must carry only
    # what was explicitly asked for, not bake in a default that should stay a default.
    def self.path_override : String?
      @@path_override
    end

    def self.path : String
      @@path_override || ENV["GORI_CONFIG"]?.presence || File.join(Paths.home_dir, "settings.json")
    end

    # Load persisted values into the class properties. Tolerant: a missing or
    # malformed file leaves the defaults (or CLI-provided values) in place.
    def self.load : Nil
      @@loaded_raw = nil
      @@load_partial = false
      @@load_warning = nil # cleared here, not in load_root, so a file that is fixed OR removed drops it
      raw = load_raw
      return unless raw # no file yet / unreadable — first run, keep defaults
      root = load_root(raw)
      return unless root # present but unparseable — kept a .corrupt copy, keep defaults
      begin
        apply_sections(root)
      rescue
        # A malformed individual section — keep whatever loaded so far, and remember that this
        # is only HALF the operator's file: every section below the raising line is at its
        # factory default now, so `save` must not write this state back (see `@@load_partial`).
        # Say so as well, on the same channel `load_root` uses: the silent version of this was
        # the #594 data loss, where `gori settings import` reported success while replacing a
        # live config with defaults.
        #
        # Scoped to `apply_sections` ALONE, not to the whole method. `serialize` and
        # `migrate_legacy_sections` below run only after every section applied, so a raise
        # there leaves nothing at a default — latching the flag for those would refuse every
        # save for the rest of the process over a file that was read in full.
        @@load_partial = true
        note_load_warning("settings: #{path} could not be read in full — the sections gori did " \
                          "not reach are at their factory defaults, so this run will not overwrite that file")
        return
      end
      # Re-base on our OWN serialization of what we just read, the same rule `save` applies
      # to `mine`. See `@@loaded_raw` for why the raw text cannot be the base.
      @@loaded_raw = serialize
      # Renamed sections, read here and NOT in `apply_sections`, so an import keeps telling the
      # truth: `import_document` drops a key outside SECTION_KEYS before it ever reaches the
      # parsers, and a legacy name accepted there would be reported "unrecognised … ignored"
      # and then applied anyway — the exact failure SECTION_KEYS exists to prevent. A file on
      # disk has no such contract: it is this install's own older state, so it migrates.
      #
      # AFTER the re-base, deliberately. The base is what DISK says, and disk says it under the
      # old name; migrating first would leave the migrated section identical to the base, the
      # merge would read that as "this process did not touch it" and take disk's — which has no
      # such key — so the value the migration just recovered would be dropped by the very next
      # save. Migrating after makes it a genuine change, which is what it is.
      migrate_legacy_sections(root)
    rescue
      # `serialize` or `migrate_legacy_sections` raised. Every section from disk is already
      # applied by here, so the in-memory state is whole and `save` stays allowed — a
      # re-base that could not be computed only costs the merge its base, which is the same
      # position a first run is in. Swallowed, as it was before the partial-load guard
      # existed; `@@loaded_raw` staying nil already reports it through `load_degraded?`.
      nil
    end

    # Read each top-level section of a parsed settings document into the class properties.
    # Split out of load so load stays a small read → parse → apply flow.
    # Not private: import_document reuses it, so a profile import runs the SAME per-section
    # readers as a normal load rather than a parallel implementation that could drift.
    # An Int32 field that cannot raise. `JSON::Any#as_i?` is `as?(Int).try(&.to_i)`, and
    # `to_i` on an Int64 outside Int32 raises OverflowError — so a value in the
    # Int32::MAX < |v| <= Int64::MAX band (larger fails in JSON.parse and takes the
    # documented .corrupt path) aborted apply_sections partway. Everything after the
    # raising line then kept its factory default, and the next `save` wrote those defaults
    # over the operator's file: `merge_with_disk` short-circuits on `disk == base` and
    # returns `mine`, so the 3-way merge never gets a chance to preserve the lost sections.
    # Out-of-range reads as absent, which is what every caller's `|| default` already means.
    protected def self.int_field(node : JSON::Any, key : String) : Int32?
      node[key]?.try(&.as_i?)
    rescue OverflowError
      nil
    end

    # Same guard for the sections that have already unwrapped their node to a Hash.
    protected def self.int_field(node : Hash(String, JSON::Any), key : String) : Int32?
      node[key]?.try(&.as_i?)
    rescue OverflowError
      nil
    end

    # The section node at `key`, but ONLY when it is a JSON OBJECT — nil for a scalar, an array
    # or null. `JSON::Any#[]?(String)` RAISES on a non-object ("Expected Hash for
    # #[]?(key : String), not String"), and a raise inside `apply_sections` abandons every
    # section BELOW it: `Settings.load`'s blanket rescue then returns with `env` (vars AND their
    # token VALUES), `hostname_overrides`, `scan_rules`, `oast_providers`, `hotkeys`, `listeners`,
    # `retention` and the rest at factory defaults, and the first later `save` writes those
    # defaults OVER the operator's file. That is the shipped failure #594 fixed, reached through a
    # different coercion: one `"editor": "nvim"` — or a `gori settings import` of a profile with
    # one, since `CLI` validates only that the TOP level is an object — was enough.
    #
    # Returns `JSON::Any` rather than the unwrapped Hash so the section bodies and their
    # `load_bool` / `parse_tls_passthrough` helpers keep their existing signatures. The sections
    # whose parse helper already begins `node.try(&.as_h?)` were never exposed; these four
    # dereferenced the node directly.
    private def self.object_section(root : JSON::Any, key : String) : JSON::Any?
      node = root[key]?
      node && node.as_h? ? node : nil
    end

    protected def self.apply_sections(root : JSON::Any) : Nil
      # All four of these dereference their node directly — see `object_section`.
      if net = object_section(root, "network")
        self.bind_host = net["bind_host"]?.try(&.as_s?) || bind_host
        self.bind_port = int_field(net, "bind_port") || bind_port
        self.upstream_proxy = net["upstream_proxy"]?.try(&.as_s?) || upstream_proxy
        self.verify_upstream = load_bool(net, "verify_upstream", verify_upstream?)
        self.serve_landing = load_bool(net, "serve_landing", serve_landing?)
        int_field(net, "connect_timeout_secs").try { |v| self.connect_timeout_secs = {v, 1}.max }
        int_field(net, "io_timeout_secs").try { |v| self.io_timeout_secs = {v, 1}.max }
        int_field(net, "capture_max_mib").try { |v| self.capture_max_mib = v.clamp(1, MAX_CAPTURE_MAX_MIB) }
        parse_tls_passthrough(net)
        net["http2"]?.try(&.as_s?).try { |v| self.http2 = v if HTTP2_MODES.includes?(v) }
      end
      self.theme = root["theme"]?.try(&.as_s?) || theme # validated against the known themes by Theme.apply
      self.mouse = load_bool(root, "mouse", mouse)
      self.pretty_bodies_default = load_bool(root, "pretty_bodies", pretty_bodies_default)
      if ed = object_section(root, "editor")
        self.editor = ed["command"]?.try(&.as_s?) || editor
        self.editor_markdown = load_bool(ed, "markdown", editor_markdown)
      end
      self.upstream_rules = parse_upstream_rules(root["upstream_rules"]?)
      self.outbound_tls = parse_outbound_tls(root["outbound_tls"]?)
      parse_retention(root["retention"]?)
      self.listeners = parse_listeners(root["listeners"]?)
      self.tab_prefs = parse_tab_prefs(root["tabs"]?)
      self.hostname_overrides = parse_hostname_overrides(root["hostname_overrides"]?)
      parse_env(root["env"]?)
      self.scan_rules = parse_scan_rules(root["scan_rules"]?)
      self.oast_providers = parse_oast_providers(root["oast_providers"]?)
      parse_hotkeys(root["hotkeys"]?)
      if cv = object_section(root, "decoder")
        self.decoder_sessions = parse_decoder_sessions(cv["sessions"]?)
        self.decoder_chains = parse_decoder_chains(cv["chains"]?)
      end
      if rw = object_section(root, "rewriter")
        parse_rewriter(rw)
      end
      if cm = object_section(root, "colormarker")
        parse_colormarker(cm)
      end
      parse_mine_prefs(root["mine"]?)
      parse_fuzzer_prefs(root["fuzzer"]?)
      if pr = root["probe"]?.try(&.as_h?)
        pr["active_notify"]?.try(&.as_s?).try { |s| self.probe_active_notify = s }
      end
      parse_discover_prefs(root["discover"]?)
      parse_layout(root["layout"]?)
      parse_statusline(root["statusline"]?)
      parse_display(root["display"]?)
      parse_companion(root["companion"]?)
      parse_notifications(root["notifications"]?)
      parse_general(root["general"]?)
      parse_update(root["update"]?)
      Env.bump_highlight_rev
    end

    # Top-level keys written by an OLDER gori, mapped to the key that replaced them. Read on
    # load (see `migrate_legacy_sections`) and dropped from the file by the next `save`, so a
    # rename costs the operator nothing and leaves nothing behind.
    LEGACY_SECTION_KEYS = {
      # v0.1.x wrote the Miss Ring prefs under "pet".
      "pet" => "companion",
    }

    # Apply a legacy section ONLY when the current name is absent — an install that has already
    # been through one save carries both keys for the moment between the migration and that
    # save, and the new one is the one that was last written.
    private def self.migrate_legacy_sections(root : JSON::Any) : Nil
      LEGACY_SECTION_KEYS.each do |old, new|
        next if root[new]?
        next unless node = object_section(root, old)
        case old
        when "pet" then parse_companion(node)
        end
      end
    end

    # Read the settings file; nil on missing/unreadable (a first run keeps defaults).
    private def self.load_raw : String?
      File.read(path)
    rescue
      nil
    end

    # A settings file EXISTS but this process could not use it, so sections are sitting at their
    # factory defaults — meaning an export writes those defaults out under the operator's name.
    # Only meaningful after a `load`.
    #
    # Two ways in, and the PARTIAL one is the newer: a section that raised leaves everything
    # below it at defaults while `load_raw` and `load_root` both succeeded, so the file-shaped
    # test below answers false for it (see `@@load_partial`).
    #
    # Deliberately NOT `load_warning != nil`. That covers one of the other ways in: `load_root`'s
    # rescue (present but unparseable) sets the warning, but `load_raw`'s rescue above sets
    # nothing and swallows every READ failure — EACCES on a settings.json left root-owned by a
    # `sudo gori`, a `--config` pointing at a directory, a transient I/O error. A guard keyed on
    # the warning therefore misses exactly the cases that leave no trace at all, which is how
    # `gori settings import` still replaced a live config with defaults and reported success.
    def self.load_degraded? : Bool
      @@load_partial || (@@loaded_raw.nil? && File.exists?(path))
    end

    # Why the last load fell back to defaults, or nil when it did not. Read by the TUI to
    # put it on the project picker; every headless surface has already had it on STDERR
    # (see load_root). Cleared by a load that parses, so it never outlives the problem.
    class_getter load_warning : String? = nil

    # Guards the warning LINE, not the state: Settings.load runs once per surface but many
    # times per process (~10 sites in cli.cr alone), and repeating the same warning down
    # the terminal for one bad file is noise.
    @@load_warning_emitted = false

    # Where that line goes. STDERR is safe on every surface — `gori mcp`'s purity invariant
    # is about STDOUT — but it is injectable rather than hardcoded so the suite can capture
    # and ASSERT the line instead of printing a scary "not valid JSON" into its own output
    # and leaving the emission itself untested. nil silences it.
    class_property warning_io : IO? = STDERR

    # Test seam: the once-per-process guard is what makes the line hard to assert, since
    # whichever example runs first spends it. Resetting is only meaningful for a suite
    # driving several corrupt files through one process.
    def self.reset_load_warning_guard : Nil
      @@load_warning_emitted = false
    end

    # Parse the settings JSON. On a PRESENT-but-unparseable file, preserve a recoverable
    # copy at "<path>.corrupt" FIRST — otherwise the next save() overwrites the file with
    # an all-defaults document (merge_with_disk gives up on an unparseable base), silently
    # and permanently losing the user's real settings — then return nil so load keeps the
    # in-memory defaults and leaves @@loaded_raw nil (the next save is a clean write, not a
    # merge against corrupt bytes).
    #
    # And SAY SO. Falling back to defaults is not a quiet event for this file: it carries
    # the bind address, the upstream connection rules and the TLS pass-through list, so a
    # hand-edited comma can drop a pass-through host into the MITM path and look like
    # nothing happened. The .corrupt copy is a recovery route only for someone who already
    # knows to look for it. STDERR is safe on every surface — `gori mcp`'s purity invariant
    # is about STDOUT — and the TUI, which would lose it under the alt screen, reads
    # `load_warning` instead.
    private def self.load_root(raw : String) : JSON::Any?
      JSON.parse(raw)
    rescue
      # 0600 like the file it is a copy of — it carries the same secrets verbatim. Whether
      # it landed decides the wording: pointing at a copy that isn't there is worse than
      # not mentioning one (write_private returns Nil, so track it with a flag).
      kept = false
      if raw.presence
        begin
          write_private("#{path}.corrupt", raw)
          kept = true
        rescue
          # unwritable dir / full disk — the warning still goes out, minus the recovery hint
        end
      end
      warning = String.build do |s|
        s << "settings: #{path} is not valid JSON — using defaults for this run"
        s << "; your file is preserved at #{path}.corrupt" if kept
      end
      note_load_warning(warning)
      nil
    end

    # Record the reason and put it on the warning io at most once — shared with `load`'s rescue
    # so a PARTIAL read is announced on exactly the channel an unparseable file already was,
    # rather than being the one degraded outcome that says nothing.
    private def self.note_load_warning(warning : String) : Nil
      @@load_warning = warning
      return if @@load_warning_emitted
      @@load_warning_emitted = true
      @@warning_io.try(&.puts(warning))
    end

    # load_bool over a Hash (the layout object), same false-preserving semantics as load_bool.
    private def self.load_bool_h(h : Hash(String, JSON::Any), key : String, current : Bool) : Bool
      (v = h[key]?) && !(b = v.as_bool?).nil? ? b : current
    end

    private def self.normalize_os(raw : String?) : String
      down = raw.try(&.downcase)
      %w[darwin linux windows].includes?(down) ? down.not_nil! : "auto"
    end

    # Read a boolean field, keeping `current` when it's absent or non-bool. A plain
    # `|| current` would wrongly resurrect a stored `false` (false is falsy), so we
    # assign only when a real bool is present.
    private def self.load_bool(node : JSON::Any, key : String, current : Bool) : Bool
      (v = node[key]?) && !(b = v.as_bool?).nil? ? b : current
    end

    # Persist the current values. Never raises into the caller (a failed write must
    # not crash the TUI); returns whether it succeeded.
    def self.save : Bool
      # The last load only got HALF this file in, so what is in memory is the operator's
      # sections down to the raise and factory defaults after it. Writing that back is the
      # #594 loss with a different door: the merge cannot recover a section it never read
      # (see `@@load_partial`), so refuse instead — reported like any other failed write,
      # which the callers already handle.
      return false if @@load_partial
      Paths.ensure_dirs
      # With --config / $GORI_CONFIG the file can live outside GORI_HOME, whose directory
      # ensure_dirs above does not create. The temp+rename below would fail on a missing
      # parent, so make it first — but `tighten: false`, because that parent is a directory
      # the OPERATOR named and gori does not own (see Paths.ensure_dir). What actually
      # protects the env values and decoder sessions is the file's own 0600, below.
      Paths.ensure_dir(File.dirname(path), tighten: false)
      # Durable write: a torn File.write (crash / two instances / disk-full) would leave a
      # half-written settings.json that load()'s blanket rescue silently resets to factory
      # defaults — losing theme, hotkeys, hostname overrides, tab prefs, decoder sessions.
      # `DurableFile` stages to a randomly-named sibling and fsyncs before the rename, which
      # is what makes those three threats actually survivable: the fixed `"#{path}.tmp"` this
      # used to stage through was shared with every peer process AND with
      # `drop_legacy_decoder_sessions`, so "two instances" raced on one temp file, and
      # without the fsync the rename could still land ahead of the bytes.
      #
      # `mine` = THIS process's serialization of its OWN in-memory state. Base the next
      # merge on it, NOT on a re-read of the file we just wrote: that file also carries a
      # concurrent peer's values for sections WE didn't change (we merged them through). If
      # the base held a peer's value for an unchanged section, our next save would see
      # current != base for it and wrongly "win", silently clobbering the peer's edit back.
      # Basing on `mine` keeps "did I change this section?" honest, so an unchanged section
      # always yields to disk on every subsequent save.
      mine = serialize
      write_private(path, merge_with_disk(mine))
      @@loaded_raw = mine
      true
    rescue
      false
    end

    # Durably replace the settings file, owner-only. Inside GORI_HOME the 0700 tree already
    # covers it, but `--config` can put this file anywhere — a shared checkout, /tmp, a home
    # directory at 0755 — and it carries `env` token VALUES and saved decoder sessions
    # (SECRET_SECTIONS below names both). `CLI.write_export` already does exactly this for
    # the EXPORTED copy; the live file holds the same secrets and was the one still landing
    # at the umask default.
    #
    # `inherit: false` because 0600 is DICTATED here rather than preserved: a copy found at
    # 0644 (an older gori wrote it under the umask) must be tightened on the way past, not
    # carried forward. `--config` is also why the symlink resolution inside `DurableFile`
    # matters here more than anywhere else — pointing gori at a path under a dotfiles repo
    # is the advertised way to use that flag, and a rename over the link would detach it on
    # the first save.
    private def self.write_private(dest : String, doc : String) : Nil
      DurableFile.write(dest, doc, perm: File::Permissions.new(0o600), inherit: false)
    end

    # 3-way merge (base = what we loaded, mine = `current` serialization, theirs = the
    # file on disk now) over the top-level sections, so persisting one field doesn't
    # discard a concurrent writer's edit to an unrelated one: a section this process
    # left unchanged (mine == base) yields to disk; a section it changed wins.
    private def self.merge_with_disk(current : String) : String
      base = @@loaded_raw
      return current unless base && File.exists?(path)
      disk = File.read(path)
      return current if disk == base # nobody else wrote since we loaded — nothing to merge
      cur_h = (JSON.parse(current).as_h? rescue nil)
      base_h = (JSON.parse(base).as_h? rescue nil)
      disk_h = (JSON.parse(disk).as_h? rescue nil)
      return current unless cur_h && base_h && disk_h
      # Retired names are subtracted here: one is never in `cur_h` (nothing serializes it), so
      # the rule below would read it as "I did not change this section" and copy disk's block
      # forward for good. `load` has already folded its value into the section that replaced
      # it, so this is the one place the old block can actually be cleared.
      keys = (cur_h.keys + disk_h.keys).uniq! - LEGACY_SECTION_KEYS.keys
      JSON.build(indent: "  ") do |j|
        j.object do
          keys.each do |k|
            cur_v = cur_h[k]?
            # I changed this section (mine != base) → mine wins; else take disk's, INCLUDING
            # when disk no longer has the key at all.
            #
            # That last clause is the whole point. A `disk_h[k]? || cur_v` fallback sat here,
            # and it silently undid a concurrent instance's DELETION: sections vanish from
            # `serialize` the moment they are emptied (`env`, `upstream_rules`, `outbound_tls`,
            # `listeners`, `scan_rules`, `oast_providers`, `hostname_overrides`, `tabs`,
            # `hotkeys`, `decoder`, `fuzzer`, `retention` at default, `mine`/`discover` unsaved
            # — nearly every optional one), so "the operator cleared their env vars in the other
            # gori window" reached this line as an absent key, and `|| cur_v` wrote our stale
            # copy — token VALUES and all — straight back. Their EDITS merged correctly the
            # whole time; only their deletions came back, which is the harder failure to notice.
            #
            # Dropping the fallback is the entire fix, because the remaining case it covered is
            # already handled: if disk lacks the key AND we did not change the section, then
            # `cur_v == base_h[k]?`, so either base had it (they deleted it → drop, correct) or
            # nobody ever had it (`cur_v` is nil → dropped anyway, same result).
            chosen = cur_v != base_h[k]? ? cur_v : disk_h[k]?
            j.field k, chosen if chosen
          end
        end
      end
    rescue
      current # any merge hiccup falls back to the plain write (never worse than before)
    end

    # --- profiles: export / import a settings subset (`gori settings export|import`) -------
    #
    # The unit is the TOP-LEVEL JSON KEY, and the list of keys is derived from the current
    # serialization rather than hand-maintained: a new section becomes exportable the moment
    # it is written, with no second list to keep in step.
    #
    # Sections holding SECRETS or machine-local scratch, excluded from an export unless the
    # operator names them explicitly. `env` carries token VALUES; `decoder` now carries only
    # the named chain SPECS (the open sub-tabs moved to each project's store), but a spec can
    # still describe how an engagement's tokens are unwrapped — and the point of an export is
    # that it can be committed or shared, so it stays opt-in.
    # Note `upstream_rules` is deliberately NOT here — it stores only a username and an
    # environment-variable NAME, never a password (see settings/upstream_rules.cr).
    SECRET_SECTIONS = ["env", "decoder"]

    # Every top-level key gori KNOWS, whether or not this install currently has a value for one.
    #
    # `document_keys` cannot answer that question and must not be used to: it is derived from
    # `serialize`, and every optional section's `serialize_*` omits itself at its factory
    # default. Using it as the VALIDITY oracle made a section's NAME valid or invalid depending
    # on the machine — `gori settings export --sections network,scan_rules` (verbatim the
    # example in docs/reference/cli.md) aborted with "unknown section(s): scan_rules" on any
    # install where scan_rules was untouched, and `gori settings import` reported a perfectly
    # well-known section as "unrecognised … ignored" and then applied it anyway. The `env` case
    # was the sharp one: on a fresh config `env` is empty, so importing a profile carrying
    # `env` printed "ignored: env" / "imported 0 section(s)" while writing the token VALUES to
    # disk — the tool telling the operator a credential section had been ignored when it had not.
    #
    # Hand-maintained, deliberately: this is the set of keys the `serialize` dispatcher at the
    # bottom of this file can emit and `apply_sections` can read, and no runtime expression
    # produces it without a fully-populated settings object. Add a section → add its key here.
    # The `document_keys - SECTION_KEYS` guard in spec/settings_profile_spec.cr catches a
    # rename, and catches an addition as soon as any example populates the new section.
    SECTION_KEYS = %w[
      theme mouse pretty_bodies layout statusline display companion notifications general update
      network upstream_rules outbound_tls retention listeners editor tabs hostname_overrides
      env scan_rules oast_providers hotkeys mine fuzzer probe discover decoder rewriter
      colormarker
    ]

    # Every top-level key the current settings would write — i.e. which sections this install
    # actually has a value for. NOT the list of valid names (see SECTION_KEYS): a section
    # sitting at its factory default is absent from here on purpose.
    def self.document_keys : Array(String)
      (JSON.parse(serialize).as_h?.try(&.keys) || [] of String)
    end

    # The current settings as a JSON document. `only` narrows it to those keys (an unknown key
    # is simply absent — the caller validates and reports). With `only` nil, everything except
    # SECRET_SECTIONS is written; naming a secret section explicitly IS the consent to include
    # it, so no separate flag is needed to leak one by accident.
    # The secret-bearing sections `export_document(only)` would actually emit — the caller
    # named them AND this install has something in them. Drives the export file's 0600 and the
    # notice that names it, so neither fires on an `env`-named export of an empty env block
    # (which would train the operator to ignore the notice on the export that matters).
    # Returns the sections rather than a Bool so the notice can name what is in the file
    # instead of reciting SECRET_SECTIONS at the operator.
    def self.exported_secret_sections(only : Array(String)? = nil) : Array(String)
      return [] of String unless list = only
      present = JSON.parse(serialize).as_h.keys
      SECRET_SECTIONS.select { |s| list.includes?(s) && present.includes?(s) }
    end

    def self.export_document(only : Array(String)? = nil) : String
      doc = JSON.parse(serialize).as_h
      keep = only || (doc.keys - SECRET_SECTIONS)
      JSON.build(indent: "  ") do |j|
        j.object do
          doc.each { |k, v| j.field k, v if keep.includes?(k) }
        end
      end
    end

    # What `import_document` would do with `raw`, as three lists: the sections it would APPLY
    # (selected ∩ recognised), the subset of those whose value differs from the current
    # settings, and the keys gori does not recognise. `--dry-run` prints this before anything
    # is written.
    #
    # The first list exists because the caller must be able to report the SAME set the real run
    # reports. Printing only the differing subset made `--dry-run` and the actual import
    # disagree on the count for identical input — "would apply 1 section(s)", then "imported 6"
    # — and the count is the one thing `--dry-run` is run to learn.
    #
    # "Recognised" is decided by SECTION_KEYS, not by `document_keys` — see SECTION_KEYS for
    # what using the latter cost. An unrecognised key is reported and then genuinely skipped by
    # `import_document`, so the two halves of this tuple no longer overlap.
    #
    # The first half is an OVER-approximation, and the caller's wording ("would apply") is
    # chosen to match: a section whose value differs wholesale is compared as a unit, but
    # `apply_sections` merges the object-of-scalars sections key by key, so a profile pinning
    # `network.upstream_proxy` to the value already in effect still shows up here. Erring this
    # way is the safe direction — a section listed here might turn out to be a no-op, but one
    # NOT listed is guaranteed to be, which is what "no changes" has to mean to be worth
    # anything. Narrowing it further would need per-section merge semantics restated here (they
    # differ: `network` preserves an omitted key, `hotkeys` and `env` reset one), i.e. a second
    # description of `apply_sections` that could silently drift out of step with it.
    def self.import_preview(raw : String, only : Array(String)? = nil) : {Array(String), Array(String), Array(String)}
      incoming = JSON.parse(raw).as_h
      current = JSON.parse(serialize).as_h
      selected = incoming.keys.select { |k| only.nil? || only.includes?(k) }
      applicable, unknown = selected.partition { |k| SECTION_KEYS.includes?(k) }
      {applicable, applicable.select { |k| current[k]? != incoming[k] }, unknown}
    end

    # Apply the selected sections of `raw` to the live settings and persist. Returns the keys
    # applied.
    #
    # WHAT "SECTION" MEANS HERE, precisely — this was documented as a whole-section REPLACE,
    # which is only true of the table-shaped sections:
    #
    #   * A section ABSENT from the profile (or not selected) is untouched. This is the real
    #     guarantee, and the one an operator is choosing between when they pass --sections.
    #   * A LIST/TABLE section present in the profile replaces wholesale — upstream_rules,
    #     outbound_tls, listeners, scan_rules, hostname_overrides, tabs, … A profile carrying
    #     `"upstream_rules": []` therefore clears the table, which is how "no rules" is said.
    #   * An OBJECT-of-scalars section (network, editor, probe) applies KEY BY KEY: a key the
    #     profile omits keeps its current value. That is deliberate — a team profile pinning
    #     `network.upstream_proxy` must not also reset everyone's bind_port to the factory
    #     default it never mentioned — but it does mean such a section is merged, not replaced.
    #
    # The second consequence to know: `export_document` omits a section sitting at its factory
    # default (serialize_* skip it), so exporting from a machine where a value is default and
    # importing onto one where it is not will NOT reset it. A profile is a set of values to
    # apply, not a snapshot of a whole configuration.
    #
    # Reuses `apply_sections`, the same reader `load` uses, so every section's tolerant parse
    # (unknown enum → safe fallback, junk entry dropped) applies here identically. Persisting
    # goes through `save`, NOT a raw write: that keeps the atomic temp+rename and the 3-way
    # merge, so an import cannot clobber a concurrent instance's edit to a section it did not
    # touch.
    # A key gori does not recognise is dropped here rather than passed through to
    # `apply_sections` (which would ignore it anyway) — so the "unrecognised section(s) ignored"
    # `import_preview` reports is TRUE. The caller printed a summary derived by subtracting one
    # list from the other, which was wrong in both directions once `document_keys` decided what
    # "recognised" meant.
    #
    # Returns the sections HANDED to `apply_sections`, which is not quite the same as the ones
    # that took effect: the per-section parsers are tolerant by design, so a section whose value
    # is the wrong shape (`"editor": "nvim"` — the #594 guard) is a no-op and still appears here.
    # Narrowing this to "actually changed something" is not available cheaply: re-serializing
    # around the apply cannot tell a rejected section from one imported with the value already
    # in effect, and would report the second as skipped.
    def self.import_document(raw : String, only : Array(String)? = nil) : Array(String)
      incoming = JSON.parse(raw).as_h
      selected = incoming.keys.select do |k|
        (only.nil? || only.includes?(k)) && SECTION_KEYS.includes?(k)
      end
      filtered = JSON.build { |j| j.object { selected.each { |k| j.field k, incoming[k] } } }
      apply_sections(JSON.parse(filtered))
      # `save` REPORTS failure rather than raising, because a failed write must not crash the
      # TUI. Discarding that here meant a full disk, a read-only filesystem or an unwritable
      # config directory printed "imported N section(s)" and exited 0 with nothing persisted —
      # the silent-success shape `gori settings` was just fixed to stop producing elsewhere.
      # There is no TUI on this path; Gori::Error is the CLI's expected-error type and CLI.run
      # turns it into a clean abort.
      unless save
        raise Error.new("settings were applied in memory but could not be written to #{path}")
      end
      selected
    end

    # Builds the full settings.json document by dispatching to each section's
    # serialize_* helper (defined alongside that section's class_property/parse_*
    # in src/gori/settings/*.cr), in the SAME ORDER the monolithic serialize used to
    # write these keys. JSON object key order is not semantically significant (load
    # reads by key), so this ordering is cosmetic/historical, kept only to make a
    # settings.json diff before/after this split a no-op.
    private def self.serialize : String
      JSON.build(indent: "  ") do |j|
        j.object do
          serialize_appearance(j)
          serialize_layout(j)
          serialize_statusline(j)
          serialize_display(j)
          serialize_companion(j)
          serialize_notifications(j)
          serialize_general(j)
          serialize_update(j)
          serialize_network(j)
          serialize_upstream_rules(j)
          serialize_outbound_tls(j)
          serialize_retention(j)
          serialize_listeners(j)
          serialize_editor(j)
          serialize_tabs(j)
          serialize_hostname_overrides(j)
          serialize_env(j)
          serialize_scan_rules(j)
          serialize_oast_providers(j)
          serialize_hotkeys(j)
          serialize_mine(j)
          serialize_fuzzer(j)
          serialize_probe(j)
          serialize_discover(j)
          serialize_decoder(j)
          serialize_rewriter(j)
          serialize_colormarker(j)
        end
      end
    end
  end
end

require "./env"
