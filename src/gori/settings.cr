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
require "./settings/hooks"
require "./settings/colormarker"
require "./settings/saved_views"
require "./settings/miner"
require "./settings/probe"
require "./settings/discover"
require "./settings/update"
require "./settings/fuzzer"

module Gori
  # Global, persisted user settings — the editable runtime CONFIG for one gori
  # process (the `settings:*` command-palette entries control this). Split into the
  # section files required above: network, editor/display, keymap/hotkeys, tabs,
  # tool defaults, rules and integrations. Persisted as JSON at
  # <config_dir>/settings.json.
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

    # A settings file is THERE and `load_raw` could not read a byte of it — EACCES on a file a
    # `sudo gori` left root-owned, a `--config` naming a directory, a transient I/O error. The
    # separate flag exists because that rescue is silent: it sets no `load_warning` (nothing was
    # parsed, so nothing complained) and leaves no `.corrupt` copy (`load_root` writes one where
    # a PARSE fails, and this never got that far), so the only record that the operator's file
    # was never seen is this bool. `load_degraded?` folds it in with two other cases; the one
    # caller that has to tell them apart is `reset_to_factory`.
    @@load_unreadable = false

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
      @@load_unreadable = false
      reset_upstream_route_errors
      # A full load rewrites every section's class properties, including the two
      # `reload_section` folds and caches. Dropping the cache here keeps "we already folded
      # these bytes" from outliving the memory it was an assertion about — a load that ends in
      # `@@load_partial` leaves sections at their factory DEFAULTS, and a stale cache entry
      # would then let the next tick skip the fold that repairs one.
      forget_reloaded_sections
      @@load_warning = nil # cleared here, not in load_root, so a file that is fixed OR removed drops it
      raw = load_raw
      unless raw
        # No file yet (first run — keep defaults, nothing to protect) or one that is there and
        # could not be READ (`@@load_unreadable`: everything below is at a factory default over
        # a file whose contents nobody has seen).
        @@load_unreadable = File.exists?(path)
        return
      end
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
        apply_upstream_proxy(net["upstream_proxy"]?)
        self.verify_upstream = load_bool(net, "verify_upstream", verify_upstream?)
        # The PROXY leg's own trust policy, kept next to (never folded into) verify_upstream —
        # see DEFAULT_UPSTREAM_PROXY_CA for why the two legs do not share a switch.
        self.upstream_proxy_ca = net["upstream_proxy_ca"]?.try(&.as_s?).try(&.strip) || upstream_proxy_ca
        self.upstream_proxy_insecure = load_bool(net, "upstream_proxy_insecure", upstream_proxy_insecure?)
        self.serve_landing = load_bool(net, "serve_landing", serve_landing?)
        int_field(net, "connect_timeout_secs").try { |v| self.connect_timeout_secs = {v, 1}.max }
        int_field(net, "io_timeout_secs").try { |v| self.io_timeout_secs = {v, 1}.max }
        int_field(net, "capture_max_mib").try { |v| self.capture_max_mib = v.clamp(1, MAX_CAPTURE_MAX_MIB) }
        parse_tls_passthrough(net)
        net["http2"]?.try(&.as_s?).try { |v| self.http2 = v if HTTP2_MODES.includes?(v) }
        self.strip_alt_svc = load_bool(net, "strip_alt_svc", strip_alt_svc?)
      end
      self.theme = root["theme"]?.try(&.as_s?) || theme # validated against the known themes by Theme.apply
      self.mouse = load_bool(root, "mouse", mouse)
      root["mouse_drag"]?.try(&.as_s?).try { |v| self.mouse_drag = normalize_mouse_drag(v) }
      self.pretty_bodies_default = load_bool(root, "pretty_bodies", pretty_bodies_default)
      if ed = object_section(root, "editor")
        self.editor = ed["command"]?.try(&.as_s?) || editor
        self.editor_markdown = load_bool(ed, "markdown", editor_markdown)
      end
      parse_hooks(root["hooks"]?)
      apply_upstream_rules(root["upstream_rules"]?)
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
      if sv = object_section(root, "saved_views")
        parse_saved_views(sv)
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

    # Re-read ONE top-level section from the file on disk into the class properties, and re-base
    # the merge on it — leaving every other section, including one this process has edited and
    # not yet saved, exactly as it is. A full `Settings.load` would clobber those, which is why
    # this exists rather than a reload of everything.
    #
    # This is what makes a GLOBAL rewriter/colormarker mutation safe against a peer process, and
    # it is not interchangeable with the merge in `merge_rule_section`. The merge reconciles the
    # two rule LISTS after the fact; only a fresh read can stop the id COLLISION, because those
    # two sections keep `next_rule_id` and the rules it numbers in one section — a process
    # minting from a counter it read minutes ago hands out an id a peer has already used, and a
    # project's `rewriter_overrides` / `colormarker_overrides` are keyed by exactly that id, in a
    # database this process may never open again. An id is not recoverable after the fact.
    #
    # Tolerant in the same direction as `load`: a missing, unreadable or unparseable file, or a
    # section that is not a JSON object, leaves memory exactly as it was and the mutation runs
    # against what this process already believed — the behaviour that shipped, never worse.
    #
    # NOT free when it actually folds: three JSON parses and a full re-serialization of the
    # settings, all of it on the calling fiber. Measured on the TUI's `data_version` tick, which
    # is where the two live callers sit — 1.9 ms at 10 global rules per section, 13 ms at 100,
    # 63 ms at 500. The tick runs ~1.3×/sec for as long as capture is committing flows, and 63 ms
    # of it is a visible stutter in a UI that is also drawing frames and taking keys.
    #
    # Which is why the file's own bytes gate the work. The overwhelmingly common tick is one
    # where nobody touched settings.json at all, and for that one there is nothing to fold: the
    # class properties already hold what the file says. So a repeat of the same bytes costs the
    # read and stops — and a read is what stays, deliberately, rather than an mtime or size
    # check. Both of those miss a same-second rewrite of the same length, which is exactly the
    # shape of a peer toggling a rule's `enabled` flag, and being fast is worth nothing if the
    # answer is stale.
    #
    # Keyed by PATH as well as content: `$GORI_HOME` moves between spec examples (and between a
    # `--db` open and the picker), and two different homes whose settings.json happen to agree
    # byte for byte must not let one seed the other's cache.
    #
    # The cache is only written after a fold that reached the end, so a parse that bailed out
    # halfway is retried on the next tick rather than remembered as done.
    #
    # And the CALLER still owns its compiled view (`Rules#refresh`, `Colormarker#refresh`) —
    # including on the paths where the CRUD answers false, since a reload can have changed the
    # list even when the write did not commit, and including when this returns early: "the file
    # did not move" is not "your snapshot is current", because a project-scope rule lives in the
    # store and never touches this file.
    @@reloaded_from : Hash(String, {String, String}) = {} of String => {String, String}

    protected def self.reload_section(key : String, & : JSON::Any -> Nil) : Nil
      raw = load_raw
      return unless raw
      here = {path, raw}
      return if @@reloaded_from[key]? == here
      root = JSON.parse(raw).as_h?
      return unless root
      node = root[key]?
      return unless node && node.as_h?
      yield node
      rebase_section(key)
      @@reloaded_from[key] = here
    rescue
      nil
    end

    # Forget what `reload_section` last folded, so the next call re-reads whatever the file says.
    #
    # For a caller that changed the class properties BEHIND the file — `load` re-reading
    # everything, and a spec that assigns `rewriter_rules=` directly. Without it the cache would
    # claim those bytes were already folded and skip a fold memory genuinely needs.
    #
    # Public rather than protected because the callers that need it most are outside this module:
    # a spec fixture that hands the globals back on the way out is mutating exactly the state the
    # cache is an assertion about, and it has no other way to say so.
    def self.forget_reloaded_sections : Nil
      @@reloaded_from.clear
    end

    # Re-base the merge on ONE section as it now stands in memory. Called by `reload_section`,
    # because the base's whole job is to answer "did THIS process change this section" and after
    # re-reading a section from disk the honest answer for it is no.
    #
    # Which matters for fidelity, not just tidiness: without it, the mutation that follows looks
    # like a wholesale rewrite of a list that mostly came from the peer, so every entry in it
    # wins the merge — and our re-serialization is LOSSY for anything the parse does not know
    # (a field a newer gori writes, a key a hand edit added). With the re-base those untouched
    # entries compare equal and disk's bytes are the ones kept.
    #
    # Our own SERIALIZATION of the section, never the raw bytes off disk — the invariant
    # `@@loaded_raw` documents at the top of this file, for the reason it gives there.
    private def self.rebase_section(key : String) : Nil
      base = @@loaded_raw
      return unless base
      base_h = JSON.parse(base).as_h?
      return unless base_h
      fresh = JSON.parse(serialize).as_h?
      return unless fresh
      if v = fresh[key]?
        base_h[key] = v
      else
        base_h.delete(key)
      end
      # Same builder settings as `serialize`, and assigning an existing key keeps its position,
      # so the base stays byte-comparable with a file this process wrote (`merge_with_disk`
      # short-circuits on `disk == base`).
      @@loaded_raw = JSON.build(indent: "  ") do |j|
        j.object { base_h.each { |bk, bv| j.field bk, bv } }
      end
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
    #
    # `factory_reset` is passed by `reset_to_factory` alone and only changes how the 3-way
    # merge treats a section this process did not have to touch — see `merge_with_disk`.
    def self.save(factory_reset : Bool = false) : Bool
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
      write_private(path, merge_with_disk(mine, factory_reset))
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
    #
    # A few sections are merged one level DEEPER than that — see RULE_SECTION_LISTS.
    #
    # `factory_reset` turns the section-level rule off, and only a reset may pass it. The rule
    # asks "did I change this section?", and a factory reset is the one write for which that
    # question has no useful answer: it SPEAKS for every section, including the ones it had
    # nothing to change because they were already at their defaults. Left on, a section sitting
    # on disk in a spelling that parses to the factory default is absent from BOTH `mine` and
    # `base` (`serialize` omits a defaulted section), reads as "unchanged", and disk's block is
    # copied straight through the reset — which is how a `decoder.sessions` block full of
    # pasted tokens (a legacy key `serialize` never writes back) survived a reset that had just
    # told the operator it dropped their saved decoder chains. Same for any key gori does not
    # know: a fresh install has none, so a factory reset must not leave one behind.
    #
    # The rule LISTS keep their entry-by-entry merge either way — a reset racing a peer's
    # `create_rule` must still delete the rules it knew about without deleting the one it never
    # saw (see RULE_SECTION_LISTS).
    private def self.merge_with_disk(current : String, factory_reset : Bool = false) : String
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
            chosen = if lists = RULE_SECTION_LISTS[k]?
                       merge_rule_section(cur_v, base_h[k]?, disk_h[k]?, lists,
                         RULE_SECTION_COUNTERS[k]? || RULE_SECTION_COUNTER)
                     elsif factory_reset
                       cur_v # what a fresh install would hold — nil drops the key entirely
                     else
                       pick_changed(cur_v, base_h[k]?, disk_h[k]?)
                     end
            j.field k, chosen if chosen
          end
        end
      end
    rescue
      current # any merge hiccup falls back to the plain write (never worse than before)
    end

    # The section-level rule, and the default for every key that is not a rule list: I changed
    # this section (mine != base) → mine wins; else take disk's, INCLUDING when disk no longer
    # has the key at all.
    #
    # That last clause is the whole point. A `disk || mine` fallback sat here, and it silently
    # undid a concurrent instance's DELETION: sections vanish from `serialize` the moment they
    # are emptied (`env`, `upstream_rules`, `outbound_tls`, `listeners`, `scan_rules`,
    # `oast_providers`, `hostname_overrides`, `tabs`, `hotkeys`, `decoder`, `fuzzer`, `retention`
    # at default, `mine`/`discover` unsaved — nearly every optional one), so "the operator
    # cleared their env vars in the other gori window" reached this line as an absent key, and
    # `|| mine` wrote our stale copy — token VALUES and all — straight back. Their EDITS merged
    # correctly the whole time; only their deletions came back, which is the harder failure to
    # notice.
    #
    # Dropping the fallback is the entire fix, because the remaining case it covered is already
    # handled: if disk lacks the key AND we did not change the section, then `mine == base`, so
    # either base had it (they deleted it → drop, correct) or nobody ever had it (`mine` is nil →
    # dropped anyway, same result).
    private def self.pick_changed(mine : JSON::Any?, base : JSON::Any?, disk : JSON::Any?) : JSON::Any?
      mine != base ? mine : disk
    end

    # One mergeable list inside a rule section: the key that holds it, how an entry's IDENTITY is
    # spelled in it, and whether the serializer OMITS the key when the list is empty (which is
    # what an ABSENT key has to mean — see `index_entries`).
    alias RuleList = NamedTuple(key: String, identity: Symbol, optional: Bool)

    # The sections that CANNOT be merged as a unit, and the lists inside them reconciled entry
    # by entry instead.
    #
    # Every other section is one operator decision, so `pick_changed` loses nothing: whoever
    # wrote it last meant it. `rewriter`, `colormarker` and `saved_views` are not one decision —
    # each holds a whole LIST plus the id counter that numbers it in ONE section, so two
    # processes each adding an entry have both "changed the section" and the section-level rule
    # threw one of the two entries away. Both had also minted from the same counter, so the
    # survivors could share an id — and a project's `rewriter_overrides` /
    # `colormarker_overrides` / `history_view` are keyed by exactly that id (`reload_section` is
    # the half of the fix that stops the collision; this half stops the loss). A project's
    # DB-scoped rows need none of this: SQLite gives them a real transaction and its own id
    # sequence.
    RULE_SECTION_LISTS = {
      "rewriter" => [
        {key: "rules", identity: :id, optional: false},
      ],
      "colormarker" => [
        {key: "rules", identity: :id, optional: false},
        {key: "colors", identity: :color_name, optional: true},
      ],
      "saved_views" => [
        {key: "views", identity: :id, optional: false},
      ],
    }

    # The id counter each of those sections carries, merged by MAX rather than by who changed
    # it. Keyed BY SECTION rather than one shared literal: `saved_views` has no rules, and
    # writing a key named `next_rule_id` into it to satisfy a constant would be a lie the next
    # reader has to un-learn. Sections absent here fall back to the historical name, so a
    # future section that does spell it `next_rule_id` needs no entry.
    RULE_SECTION_COUNTERS = {
      "rewriter"    => "next_rule_id",
      "colormarker" => "next_rule_id",
      "saved_views" => "next_view_id",
    }
    RULE_SECTION_COUNTER = "next_rule_id"

    # Retired keys INSIDE a rule section, subtracted for exactly the reason LEGACY_SECTION_KEYS
    # is subtracted at the top level: nothing serializes one, so the key-by-key rule below would
    # read it as "I did not change this" and copy disk's block forward for good. `parse_rewriter`
    # has already folded `presets` into `rules` in memory, so a save that touches the section is
    # the one place the old block can actually be cleared — which is what it did while the whole
    # section was decided as a unit, and what it has to keep doing now that it is not.
    #
    # One flat list rather than one per section: `presets` was only ever a `rewriter` key, and a
    # name retired from one of these sections is not a name another may start using. Pinned by
    # spec/settings_spec.cr's "adopts legacy rewriter presets as DISABLED global rules", which
    # asserts the saved file no longer mentions them.
    LEGACY_RULE_SECTION_KEYS = ["presets"]

    # Merge one rule section key by key: its lists entry by entry, its counter by high-water
    # mark, anything else by the section-level rule.
    private def self.merge_rule_section(mine : JSON::Any?, base : JSON::Any?, disk : JSON::Any?,
                                        lists : Array(RuleList),
                                        counter_key : String = RULE_SECTION_COUNTER) : JSON::Any?
      mine_h = mine.try(&.as_h?)
      disk_h = disk.try(&.as_h?)
      # One side has no object here at all, so there is no second list to lose — and if disk's
      # is not an object, nothing about it can be trusted to be reconciled with.
      return pick_changed(mine, base, disk) unless mine_h && disk_h
      base_h = base.try(&.as_h?) || {} of String => JSON::Any
      merged = {} of String => JSON::Any
      keys = (mine_h.keys + disk_h.keys).uniq! - LEGACY_RULE_SECTION_KEYS
      keys.each do |k|
        v = if list = lists.find { |l| l[:key] == k }
              merge_entry_list(mine_h[k]?, base_h[k]?, disk_h[k]?, list)
            elsif k == counter_key
              merge_counter(mine_h[k]?, disk_h[k]?)
            else
              pick_changed(mine_h[k]?, base_h[k]?, disk_h[k]?)
            end
        merged[k] = v if v
      end
      JSON::Any.new(merged)
    end

    # The id counter is MONOTONIC and its ids are never reused, so it is the one field here where
    # neither side "wins": the answer is the larger. A peer that minted ids while we held an older
    # snapshot has advanced it, and taking our lower number forward would hand a live rule's id
    # to the next rule created — the very thing `rewriter_next_rule_id` exists to prevent. The
    # base plays no part: there is no edit to detect here, only a high-water mark.
    private def self.merge_counter(mine : JSON::Any?, disk : JSON::Any?) : JSON::Any?
      m = mine.try(&.as_i64?)
      d = disk.try(&.as_i64?)
      return mine || disk unless m && d
      JSON::Any.new({m, d}.max)
    end

    # Reconcile one list of identified entries. Every entry goes through `pick_changed`, the SAME
    # rule the top level applies to a whole section — nothing is being decided differently here,
    # it is being decided at the granularity of a rule instead of a library. Read against an
    # identity, that one expression is all four cases:
    #
    #   * in mine, not in base     → WE added it; ours.
    #   * in base, not in mine     → WE deleted it; it goes, even though disk still has it.
    #   * in neither mine nor base → the PEER added it; theirs, so an add of ours cannot eat it.
    #   * in mine and in base      → ours if we edited it (mine != base), else follow disk —
    #                                including disk having dropped it, which is the peer's delete.
    #
    # One consequence worth naming, because it reads as a surprise until it doesn't: a
    # `reset_to_factory` racing a peer's add clears every rule it KNEW about (they are all in the
    # base) and leaves that one. It is the third case, and the alternative is deleting a rule
    # this process has never seen on the strength of a snapshot taken before it existed.
    #
    # ORDER is meaning in both of these lists (rewriter apply order, colormarker first-match-wins
    # precedence), so it is merged too: if we REORDERED, ours leads and the peer's adds follow;
    # otherwise disk's order stands and our adds append to it, which is where `add` puts them.
    private def self.merge_entry_list(mine : JSON::Any?, base : JSON::Any?, disk : JSON::Any?,
                                      list : RuleList) : JSON::Any?
      mine_ix = index_entries(mine, list)
      disk_ix = index_entries(disk, list)
      return pick_changed(mine, base, disk) unless mine_ix && disk_ix
      # An absent list in the BASE always reads as empty, whatever the serializer does with an
      # empty one: the base is our own writing, so "no key" there means we had nothing to record,
      # never that the shape is unknown. Everything in both lists is then an add, which is exactly
      # right for a peer that created the section while we held a snapshot without it.
      base_ix = base.nil? ? ({} of String => JSON::Any) : index_entries(base, list)
      return pick_changed(mine, base, disk) unless base_ix
      kept = {} of String => JSON::Any
      (mine_ix.keys + disk_ix.keys).uniq!.each do |id|
        chosen = pick_changed(mine_ix[id]?, base_ix[id]?, disk_ix[id]?)
        kept[id] = chosen if chosen
      end
      mine_ids, base_ids, disk_ids = mine_ix.keys, base_ix.keys, disk_ix.keys
      # Compared over the ids the two lists SHARE, so our own add (always appended) is not read
      # as a reorder — it would make every add claim the peer's order as well as its own entry.
      order = if (mine_ids & base_ids) != (base_ids & mine_ids)
                mine_ids + (disk_ids - mine_ids)
              else
                disk_ids + (mine_ids - disk_ids)
              end
      merged = order.compact_map { |id| kept[id]? }
      # An emptied list goes the way the serializer would have written it, so a merge cannot
      # introduce a shape a plain save never produces: `colormarker.colors` is omitted when there
      # is nothing in it ("an install with rules but no customs should not start writing an empty
      # colors array it never had"), while `rules` is always written.
      return nil if merged.empty? && list[:optional]
      JSON::Any.new(merged)
    end

    # `list` as identity → entry, in list order, or nil when it cannot be merged entry by entry
    # and the section-level rule has to stand in.
    #
    # An entry gori itself did not write is what forces that fallback. `claim_id` RENUMBERS an
    # entry whose id is missing, non-positive, at the Int64 ceiling or already taken, so for such
    # a list our in-memory id is not the one on disk — and then "in base, absent from disk" would
    # read as the peer's delete when it is really the same rule under another number, and the
    # entry would be dropped from the operator's own file. Falling back is exactly the behaviour
    # that shipped before this merge existed, so it can only be as good as before, never worse.
    private def self.index_entries(entries : JSON::Any?, list : RuleList) : Hash(String, JSON::Any)?
      # An ABSENT key is an empty list where the serializer omits an empty one:
      # `colormarker.colors` is written only when there is a colour to write, so "no key" is how
      # "no colours" is spelled, and reading it as unmergeable would drop a peer's new colour
      # along with the last one of ours. `rules` is written whenever its section is, so ITS
      # absence means something else wrote this section — the pre-upgrade `rewriter.presets`
      # block, or a hand edit — and the in-memory list came from a migration `pick_changed` has
      # to carry through whole.
      return ({} of String => JSON::Any) if entries.nil? && list[:optional]
      arr = entries.try(&.as_a?)
      return nil unless arr
      by_id = {} of String => JSON::Any
      arr.each do |e|
        id = entry_identity(e, list[:identity])
        return nil unless id
        return nil if by_id.has_key?(id) # a duplicate is ambiguous by id, exactly as `claim_id` says
        by_id[id] = e
      end
      by_id
    end

    # How this entry is identified across the three documents, or nil when it is not in the form
    # the parse would keep VERBATIM — which is the same question `index_entries` needs answered,
    # so both normalisations below are the parser's own (`usable_id?`, `normalize_color_name`,
    # `normalize_hex`) rather than a second spelling of them here.
    private def self.entry_identity(entry : JSON::Any, identity : Symbol) : String?
      o = entry.as_h?
      return nil unless o
      case identity
      when :id
        id = o["id"]?.try(&.as_i64?)
        id && usable_id?(id) ? id.to_s : nil
      when :color_name
        # A custom colour's NAME is its identity (there is no numeric id), and both of its fields
        # are normalised on the way in, so an entry spelled any other way is one the parse would
        # rewrite or drop.
        name = o["name"]?.try(&.as_s?)
        hex = o["hex"]?.try(&.as_s?)
        return nil unless name && hex
        normalize_color_name(name) == name && normalize_hex(hex) == hex ? name : nil
      end
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
    #
    # THIS LIST IS ONE AXIS, AND THERE ARE TWO. Every sentence above reasons about SECRECY —
    # what a profile would leak outward if it were committed or shared. Since #818 a section
    # can also carry an ARGV, and what that leaks is inward: importing it arms a command gori
    # forks with the receiving operator's privileges. `decoder` is on both axes and is here for
    # the first one only; `rewriter` and `scan_rules` are on the second and are deliberately
    # NOT here. The execution axis is `COMMAND_SECTIONS` below, and it is handled by REPORTING
    # rather than by exclusion — see `command_rules` for that argument in full. Adding an
    # exportable section means asking both questions, not this one.
    SECRET_SECTIONS = ["env", "decoder"]

    # Sections that can carry a COMMAND — the second axis. Every settings value gori hands to
    # `Process.new`/`Process.run` lives in one of these, and the list is what both ends of a
    # profile report from. `spec/settings/profile_commands_spec.cr` walks the tree's spawn
    # sites and fails when one is reachable from a section that is not here.
    #
    #   rewriter    a rule with `op: "pipe"`      — argv, no shell (`Gori::ProcessHook`, #818)
    #   scan_rules  an entry with `kind: "exec"`  — argv, no shell
    #   decoder     a `chains` spec with `exec:`  — argv, no shell
    #   statusline  `command`                     — /bin/sh -c, on a TIMER (see below)
    #   editor      `command`                     — argv, on `--edit` / the TUI's ^E
    #
    # The last two were the hole this list was nearly shipped with, and `statusline` is the
    # sharpest thing on it: it is a FULL SHELL rather than ProcessHook's no-shell exec, it
    # carries its own `enabled` in the same section so it self-arms, and it fires on an
    # interval with no proxied traffic needed. Scoping this to "the #818 hook seams" would
    # have gated the three guarded shapes and waved through the unguarded one.
    #
    # NOT an exclusion list: `gori settings sections` marks these, `gori settings export`
    # counts what it wrote, and `gori settings import` lists them and refuses without
    # `--allow-commands`.
    COMMAND_SECTIONS = ["rewriter", "scan_rules", "decoder", "statusline", "editor"]

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
    # The `document_keys - SECTION_KEYS` guard in spec/settings/profile_spec.cr catches a
    # rename, and catches an addition as soon as any example populates the new section.
    SECTION_KEYS = %w[
      theme mouse mouse_drag pretty_bodies layout statusline display companion notifications general update
      network upstream_rules outbound_tls retention listeners editor tabs hostname_overrides
      env scan_rules oast_providers hotkeys mine fuzzer probe discover decoder rewriter
      hooks colormarker saved_views
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

    # One thing inside a PROFILE that runs an external command (#842).
    #
    # Flat and section-agnostic on purpose. Five shapes can carry a command — a Match&Replace
    # `pipe` op, a Probe `exec` scan rule, a Decoder `exec:` chain step, the statusline's
    # `command`, the editor's `command` — and the operator at the receiving end needs the same
    # four facts about each: where it lands, how it runs, what it is called, and the command
    # itself. The surfaces render this; they do not each re-derive it.
    record CommandEntry,
      section : String, # the top-level key it lands under — also what `--sections` selects on
      kind : String,    # HOW it runs: "pipe" | "exec" (argv, no shell) | "sh -c" (a shell)
      name : String,    # the rule's label, or the field name for a scalar section
      command : String, # the command, VERBATIM as the profile spells it (`$KEY` unexpanded)
      enabled : Bool    # false = carried, but inert until someone arms it

    # Every command-carrying entry in `root`, over the sections `only` selects (nil = every one
    # present in the document).
    #
    # ONE reader for both doors. `export` runs it over the document it is about to write and
    # `import` over the document it is about to apply, so the count an operator sees when they
    # ship a profile is the count the next operator sees when they receive it. #818 built this
    # alarm and wired it to one door — a PEER's `pipe` rule (`PeerNotices`, `RuleSetChange`) —
    # on the argument that adopting one means this process will fork and exec a command with
    # the operator's privileges and none of that is visible in any pane. Every word of that
    # applies to an imported profile; this is the second door.
    #
    # Built on the SAME tolerant parsers `apply_sections` uses, never on a walk of the raw
    # JSON. An entry those parsers DROP (a rewriter rule with no pattern, a header op on a body
    # part, a scan rule with no title) never reaches the settings and must not be reported as
    # armed; an entry they CLAMP (`"op": "PIPE"`, `"op": "nonsense"`) has to be reported the
    # way the import will read it rather than the way the file spells it. A hand-rolled walk
    # would be a second description of the parse, free to drift from it — and the drift would
    # be silent in the direction that matters.
    #
    # A command that could never RUN is not reported: an empty argv is refused by
    # `Rules.pipe_argv_error` and fails a Decoder step with "no command", so counting one
    # toward the import refusal would block an import over an entry that arms nothing.
    #
    # WHY THIS REPORTS RATHER THAN EXCLUDES, i.e. why these sections are not in
    # SECRET_SECTIONS. Secrecy is a property of a SECTION: `env` holds token values however it
    # is filled in, so a section-granular default-off is the right shape for it. Execution is a
    # property of a VALUE. A `rewriter` section is usually a handful of ordinary header
    # rewrites and an `editor` is usually `nvim`, so excluding those sections would drop them
    # from every profile that has no hook in it at all in order to catch the one that does —
    # and drop them with no message, since `export_document` says nothing about what it omits.
    # A profile that quietly loses what it was made to carry is its own failure. So the section
    # ships whole, and both ends say what is in it.
    def self.command_entries(root : JSON::Any, only : Array(String)? = nil) : Array(CommandEntry)
      acc = [] of CommandEntry
      if doc = root.as_h?
        COMMAND_SECTIONS.each do |section|
          next unless only.nil? || only.includes?(section)
          next unless node = doc[section]?
          case section
          when "rewriter"   then rewriter_command_entries(node, acc)
          when "scan_rules" then scan_command_entries(node, acc)
          when "decoder"    then decoder_command_entries(node, acc)
          when "statusline" then statusline_command_entries(node, acc)
          when "editor"     then editor_command_entries(node, acc)
          end
        end
      end
      acc
    end

    # `rewriter`: the same `rules`-else-legacy-`presets` branch `parse_rewriter` takes, so a
    # profile carrying a pre-upgrade preset block is read the way the import will read it.
    #
    # A node of the wrong SHAPE is skipped rather than parsed, and that is not pedantry:
    # `parse_rewriter_rules` answers a non-array with THIS INSTALL'S current global rules, so
    # handing it one would report the operator's own hooks as though the profile carried them —
    # and, at the import gate, refuse an import over rules that are already on disk.
    private def self.rewriter_command_entries(node : JSON::Any, acc : Array(CommandEntry)) : Nil
      return unless node.as_h?
      rules =
        if raw = node["rules"]?
          return unless raw.as_a?
          parse_rewriter_rules(raw)
        else
          legacy = node["presets"]?
          return unless legacy && legacy.as_a?
          # Adopted DISABLED by `parse_legacy_presets`, and reported anyway: the profile is
          # still carrying the command, and `enabled` says which of the two it is.
          parse_legacy_presets(legacy)
        end
      rules.each do |r|
        cmd = r.command.presence
        acc << CommandEntry.new("rewriter", r.op, r.name, cmd, r.enabled) if cmd
      end
    end

    # `scan_rules`: the section IS the array — there is no wrapper object.
    private def self.scan_command_entries(node : JSON::Any, acc : Array(CommandEntry)) : Nil
      return unless node.as_a?
      parse_scan_rules(node).each do |r|
        cmd = r.command.presence
        acc << CommandEntry.new("scan_rules", r.kind, r.title, cmd, r.enabled) if cmd
      end
    end

    # `decoder`: one entry per `exec:` STEP, named by the chain that holds it.
    #
    # Only the steps a spec spells out directly. A chain that reaches a command through ANOTHER
    # saved chain (`myenc > url-encode`) adds no command this listing does not already carry —
    # `decoder.chains` replaces the library wholesale, so the chain it calls is in this same
    # profile and is reported on its own line. `Decoder.chain_runs_commands?` is the predicate
    # for the other question ("may I run this spec at all"), which does need the registry.
    #
    # `enabled: true` for every one: a saved chain has no enabled flag — it is callable by name
    # the moment it lands.
    private def self.decoder_command_entries(node : JSON::Any, acc : Array(CommandEntry)) : Nil
      return unless node.as_h?
      chains = node["chains"]?
      return unless chains && chains.as_a?
      parse_decoder_chains(chains).each do |(name, spec)|
        # `.scrub` BEFORE the split, because the split is a PCRE2 regex and this string came
        # out of someone else's file. Crystal's JSON parser rejects a lone surrogate but passes
        # a raw `0xff` through untouched, so an otherwise-valid profile could put a byte in a
        # chain spec that made `parse_spec` raise `ArgumentError` — out of a CLI that rescues
        # only `Gori::Error`, i.e. a Crystal backtrace at the operator instead of the listing
        # they ran the command for, and no gate at all. The other sections are safe by
        # construction (their parses run no regex); this is the only one that does.
        Decoder.parse_spec(spec.scrub).each do |token|
          argv = Decoder.exec_spec(token).try(&.presence)
          # "exec", i.e. `Decoder::EXEC_PREFIX` without the colon that makes it a marker: the
          # `kind` column is a vocabulary the operator reads, and within `decoder` there is
          # only one thing it can mean.
          acc << CommandEntry.new("decoder", "exec", name, argv, true) if argv
        end
      end
    end

    # `statusline`: the sharpest entry on the list, and the reason `kind` names the mechanism
    # rather than the section.
    #
    # `Tui::Statusline.run` spawns `/bin/sh -c <command>` — a FULL SHELL, not `ProcessHook`'s
    # argv exec — every `interval` seconds, with no proxied traffic needed to trigger it. The
    # section carries its own `enabled`, so a profile arms it without touching anything else.
    #
    # ENABLED is only false when the profile SAYS so. `parse_statusline` reads an absent
    # `enabled` as "keep the current value", so whether a hand-written profile that omits it
    # ends up live depends on the receiving install — and for a shell on a timer the honest
    # default is to leave the row unmarked rather than to promise it is inert. An export always
    # writes the key (`serialize_statusline`), so this only bites on a hand-written profile.
    private def self.statusline_command_entries(node : JSON::Any, acc : Array(CommandEntry)) : Nil
      return unless o = node.as_h?
      cmd = o["command"]?.try(&.as_s?).try(&.presence)
      return unless cmd
      acc << CommandEntry.new("statusline", "sh -c", "command", cmd,
        o["enabled"]?.try(&.as_bool?) != false)
    end

    # `editor`: `Settings.editor_command` whitespace-splits this and `Process.run`s it — from
    # `gori settings --edit` and from the TUI's ^E — so an imported value silently redefines
    # what "my editor" means.
    #
    # Only a NON-EMPTY one. `serialize_editor` writes the section unconditionally, so every
    # profile ever exported carries an `editor` block; reporting the empty default would put a
    # note on every export and a flag on every import, which is how a loud line stops being
    # read. Empty means gori falls through to `$VISUAL`/`$EDITOR`/`vi` — the receiving
    # operator's own environment, not the profile's.
    private def self.editor_command_entries(node : JSON::Any, acc : Array(CommandEntry)) : Nil
      return unless o = node.as_h?
      cmd = o["command"]?.try(&.as_s?).try(&.presence)
      acc << CommandEntry.new("editor", "exec", "command", cmd, true) if cmd
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

    # Factory reset: every persisted setting back to the value a fresh install ships with,
    # then written to disk. The reverse of `serialize` — and deliberately built as its
    # mirror, one `reset_*` per `serialize_*` in the same order, because "what a factory
    # reset covers" and "what gets written" have to be the SAME list or the reset quietly
    # leaves a section behind. spec/settings/reset_spec.cr greps the two dispatchers below
    # and fails when they diverge.
    #
    # This drops operator DATA as well as preferences — global env var VALUES, the hostname
    # map, OAST provider tokens, saved decoder chains, rewriter/colormarker rules. That is
    # what a factory reset means here (every one of those lives in settings.json, and the
    # only alternative is a reset that lies about its scope), so the surfaces offering it
    # name them in the confirm.
    #
    # NOT covered, because `serialize` does not write them: project overrides
    # (`project_bind_*`, `project_env_vars`) and the `cli_*` invocation overlay. Those belong
    # to the open project and to this process's argv — a settings reset does not speak for
    # either, and clearing them would silently move a pinned listener.
    # What a factory reset actually achieved. Three outcomes, not two, because the two
    # failures are opposites and a caller has to tell them apart: `Refused` touched NOTHING
    # (so re-applying settings live, or saying "reset" at all, would be a lie), while
    # `Applied` cleared memory and only the write failed.
    enum ResetResult
      Saved   # in memory and on disk
      Applied # in memory; the write failed
      Refused # nothing touched at all
    end

    def self.reset_to_factory : ResetResult
      # `save` refuses outright when the last load only got half the file in
      # (see @@load_partial). Clearing memory first and only then discovering the write is
      # refused would leave the session running on defaults while the file still holds
      # everything — i.e. a "factory reset" that undoes itself at the next start. Ask before
      # the side effect, not after it.
      #
      # …and the same ask covers the OTHER way this session can be sitting on defaults over a
      # file that still holds everything: `load_raw`'s blanket rescue swallows every READ
      # failure — EACCES on a settings.json a `sudo gori` left root-owned, a `--config`
      # pointing at a directory, a transient I/O error — and leaves no trace at all. A reset
      # from there is not a reset: nothing of the operator's file was ever read, so `serialize`
      # writes the same factory document with or without them, and the merge has no base to
      # protect them with. If the DIRECTORY is writable (the root-owned-file case exactly),
      # `DurableFile`'s rename lands on top of a file gori never opened — and unlike the
      # unparseable path there is no `.corrupt` copy, because that one is written where a parse
      # fails, not where a read does. Deliberately NOT `load_degraded?`, whose third case (a
      # `serialize` that raised AFTER every section applied) leaves memory whole and a reset
      # perfectly safe.
      return ResetResult::Refused if @@load_partial || @@load_unreadable
      reset_sections
      save(factory_reset: true) ? ResetResult::Saved : ResetResult::Applied
    end

    # Restore the in-memory state, section by section. Mirrors `serialize` below — same
    # helpers, same order, same file for each one.
    private def self.reset_sections : Nil
      reset_appearance
      reset_layout
      reset_statusline
      reset_display
      reset_companion
      reset_notifications
      reset_general
      reset_update
      reset_network
      reset_upstream_rules
      reset_outbound_tls
      reset_retention
      reset_listeners
      reset_editor
      reset_tabs
      reset_hostname_overrides
      reset_env
      reset_scan_rules
      reset_oast_providers
      reset_hotkeys
      reset_mine
      reset_fuzzer
      reset_probe
      reset_discover
      reset_decoder
      reset_rewriter
      reset_hooks
      reset_colormarker
      reset_saved_views
      # `$KEY` highlighting is cached against this revision, exactly as apply_sections does
      # after a load — the env block just changed underneath every editor showing it.
      Env.bump_highlight_rev
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
          serialize_hooks(j)
          serialize_colormarker(j)
          serialize_saved_views(j)
        end
      end
    end
  end
end

require "./env"
