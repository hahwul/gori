require "db"
require "sqlite3"
require "../env_migration"
require "../notes"
require "../session_slot"
require "../evidence"
require "../open_lock"
require "../project_registry"

# `gori settings env-syntax <value> --migrate` — the one-shot data half of the grammar switch.
#
# The switch itself only changes how STORED bytes are READ (see `Env::Syntax`), which is the safe
# default and stays the default. This file is the opt-in other half: it walks a project database,
# re-spells every token the grammar being left would have substituted, and says exactly what it
# touched. `EnvMigration` owns the rewrite (and its wire check); everything here is orchestration
# — which projects, which columns, a backup, one transaction, and the table.
#
# The COLUMN LIST is the interesting part of the orchestration, and it is a judgement about each
# column rather than a sweep:
#
#   * REWRITTEN — bytes an operator authored that a send seam expands: a draft Repeater's
#     request/target/sni/name, its WS messages, a Fuzzer template, a Miner and a Sequencer
#     request, a rewrite rule's `replacement`, a session slot's header values, and the display
#     text `Env.mask_secrets` writes a token into (issue titles and notes, note bodies).
#   * SKIPPED, and listed as such — every EVIDENCE row (`flow_id` not null). A capture expands
#     nothing (`Repeater::PlanOptions#evidence?`), so its `$filter` is a byte the origin sent;
#     re-spelling it would edit a capture to no effect on the wire and every effect on the record.
#   * LEFT ALONE, deliberately — project and global env var NAMES (they are table keys, not
#     tokens) and their VALUES (nothing re-expands a var's value), extract-rule names (the same),
#     a rule's `pattern` (a regex/needle, never expanded), a Fuzzer's payload sets (`config`,
#     never expanded), `fuzz_results`/`issue_evidence`/`flows` (sent bytes — evidence), QL views,
#     scope rules, colormarkers and probe rules (no token seam at all).
module Gori::CLI
  # One planned edit, for the report. `note` non-nil marks a row that is NOT written — an
  # evidence row, or one whose bytes have no equivalent spelling in the target grammar.
  record MigrateRow,
    project : String,
    table : String,
    row : String,
    changes : Array(EnvMigration::Change),
    note : String? = nil do
    def skipped? : Bool
      !@note.nil?
    end

    def ambiguous? : Bool
      @changes.any?(&.ambiguous)
    end
  end

  # One `UPDATE`, held until the whole project has been scanned so the write is one transaction.
  record MigrateWrite, sql : String, args : Array(::DB::Any)

  record MigratePlan,
    project : String,
    db_path : String,
    to : Env::Syntax,
    rows : Array(MigrateRow),
    writes : Array(MigrateWrite) do
    def edits : Array(MigrateRow)
      @rows.reject(&.skipped?)
    end

    def skipped : Array(MigrateRow)
      @rows.select(&.skipped?)
    end

    def tokens : Int32
      edits.sum(&.changes.size)
    end
  end

  # What a scan carries from column to column: the grammars, the two name tables, and the
  # accumulators. A struct rather than eight arguments, because every `migrate_field` call site
  # would otherwise repeat them and the one that repeated them wrong would silently rewrite
  # against the wrong table.
  private record MigrateCtx,
    project : String,
    from : Env::Syntax,
    to : Env::Syntax,
    env_names : Set(String),
    bind_names : Set(String),
    prefix : String,
    rows : Array(MigrateRow),
    writes : Array(MigrateWrite)

  # ── the verb's own flags ───────────────────────────────────────────────────

  # `--migrate` re-spells tokens FROM the other grammar INTO the one named, which is why `from`
  # is derived rather than read from the settings: an operator who already ran
  # `gori settings env-syntax namespaced` and only now wants their drafts moved must still get
  # the bare → namespaced rewrite, and asking for it twice is not an error.
  private def self.migrate_source_syntax(to : Env::Syntax) : Env::Syntax
    to.bare? ? Env::Syntax::Namespaced : Env::Syntax::Bare
  end

  # Two answers to "which project" is the one mistake with no repair — a wrapper is fixed by
  # dropping a flag, and there is no equivalent for having migrated the wrong database.
  private def self.migrate_refuse_target_mix!(project_name : String?, db_path : String?,
                                              all : Bool) : Nil
    if msg = Run.two_targets_error(project_name, db_path, "gori settings env-syntax")
      abort msg
    end
    return unless all && (project_name.try(&.presence) || db_path.try(&.presence))
    abort "gori settings env-syntax: --all-projects migrates every project under " \
          "#{Paths.projects_dir}, so it cannot be combined with --project or --db"
  end

  # Which databases to walk. Mirrors `gori run project env`'s resolver — `--db` wins, then
  # `--project`, then the most-recently-active one — with `--all-projects` as the third answer,
  # because a home whose projects were all written under one grammar is the case the migration
  # exists for.
  private def self.migrate_targets(project_name : String?, db_path : String?,
                                   all : Bool) : Array(Project)
    migrate_refuse_target_mix!(project_name, db_path, all)
    if path = db_path.try(&.presence)
      unless File.exists?(path) && !File.directory?(path)
        abort "gori settings env-syntax: --db is not a readable file: #{path}"
      end
      return [Project.new(File.basename(File.dirname(path)), path)]
    end
    registry = ProjectRegistry.new(Paths.projects_dir)
    projects = registry.list
    if name = project_name.try(&.presence)
      if found = registry.find(name)
        return [found]
      end
      abort "gori settings env-syntax: no project matching '#{name}'" \
            "#{projects.empty? ? "" : " (have: #{projects.map(&.name).join(", ")})"}"
    end
    if projects.empty?
      abort "gori settings env-syntax --migrate: no projects yet — there is nothing stored to " \
            "re-spell (pass --db PATH for a database outside #{Paths.projects_dir})"
    end
    return projects if all
    # The same default `gori run` takes, and announced for the same reason: a default nobody
    # typed is invisible until it is the wrong project — and this one WRITES.
    [projects.first]
  end

  # ── the scan ──────────────────────────────────────────────────────────────

  private def self.migrate_scan(project : Project, from : Env::Syntax, to : Env::Syntax) : MigratePlan
    rows = [] of MigrateRow
    writes = [] of MigrateWrite
    store = begin
      Store.open(project.db_path, read_only: true, background_index: false)
    rescue ex : ::DB::Error | ::SQLite3::Exception | Gori::Error
      abort "gori settings env-syntax --migrate: cannot open #{project.db_path}: #{ex.message}"
    end
    begin
      ctx = MigrateCtx.new(project.name, from, to, migrate_env_names(store),
        migrate_bind_names(store), Settings.env_prefix, rows, writes)
      migrate_scan_repeaters(store, ctx)
      migrate_scan_rules(store, ctx)
      migrate_scan_slots(store, ctx)
      migrate_scan_workbenches(store, ctx)
      migrate_scan_issues(store, ctx)
      migrate_scan_notes(store, ctx)
    ensure
      store.close
    end
    MigratePlan.new(project.name, project.db_path, to, rows, writes)
  end

  # The ENV table as the grammar being left resolved it: the global vars merged under this
  # project's own, exactly `Env.effective_vars`' membership — read from the STORE rather than
  # from `Settings.project_env_vars`, because `--all-projects` walks several projects in one
  # process and the global is whichever one was opened last.
  private def self.migrate_env_names(store : Store) : Set(String)
    names = Settings.env_vars.map(&.[0]).to_set
    Env.parse_vars_json(store.setting(Env::PROJECT_VARS_KEY)).each { |(k, _)| names << k }
    names
  end

  # The BIND table, wider than what is bound: every extract rule's name (enabled or not) plus
  # every name a session slot claims. A binding value is memory-only, so "what is bound right
  # now" is empty in this process and would re-spell nothing; what the operator WROTE is the
  # declared name, and a disabled rule's name is still the name they wrote.
  private def self.migrate_bind_names(store : Store) : Set(String)
    names = store.extract_rules.map(&.name).to_set
    SessionSlot.parse_json(store.setting(Store::SESSION_SLOTS_KEY)).each do |slot|
      slot.rules.each { |r| names << r }
    end
    names
  end

  # Rewrite one field. Returns the new bytes when they should be WRITTEN, nil otherwise (no
  # change, an evidence row, or a rewrite whose wire would move).
  #
  # `evidence` is the row's provenance, not a flag about the bytes: a capture is not expanded, so
  # there is no token in it to re-spell — and a row that DOES look like it has one is exactly the
  # row an operator should hear about, which is why it is listed rather than passed over.
  private def self.migrate_field(ctx : MigrateCtx, table : String, row : String, bytes : Bytes,
                                 kind : EnvMigration::Kind,
                                 evidence : String? = nil) : Bytes?
    after, changes = EnvMigration.rewrite(bytes, from: ctx.from, to: ctx.to,
      env_names: ctx.env_names, bind_names: ctx.bind_names, kind: kind, prefix: ctx.prefix)
    if changes.empty?
      # Nothing to RE-SPELL is not the same as nothing to say: text that is inert under the old
      # grammar can be a reference under the new one (`$ENV.id` is three literal bytes and a name
      # to the bare reader, and a token to the namespaced one). The migration cannot fix that —
      # the bytes are already spelled the target's way — so it names the row instead.
      migrate_note_reinterpreted(ctx, table, row, bytes, kind, evidence)
      return nil
    end
    if reason = evidence
      ctx.rows << MigrateRow.new(ctx.project, table, row, changes, note: reason)
      return nil
    end
    # The wire is the invariant (see `EnvMigration`). A text whose bytes the target grammar
    # cannot spell is LEFT, named, and counted — a migration that ships different bytes than the
    # operator's last send is worse than one that says it could not.
    if kind.request? && !EnvMigration.safe?(bytes, after, from: ctx.from, to: ctx.to,
         env_names: ctx.env_names, bind_names: ctx.bind_names, prefix: ctx.prefix)
      ctx.rows << MigrateRow.new(ctx.project, table, row, changes,
        note: "no #{ctx.to.to_s.downcase} spelling sends these bytes unchanged — left as authored")
      return nil
    end
    ctx.rows << MigrateRow.new(ctx.project, table, row, changes)
    after
  end

  # A row whose bytes the two grammars READ differently, with nothing for the rewrite to change.
  # Reported with an empty change list: what matters is the row, and the fix is the operator's
  # (escape it, or rename the var). Only asked of `Kind::Request`, the kind that has a wire.
  private def self.migrate_note_reinterpreted(ctx : MigrateCtx, table : String, row : String,
                                              bytes : Bytes, kind : EnvMigration::Kind,
                                              evidence : String?) : Nil
    return unless kind.request? && evidence.nil?
    return if EnvMigration.safe?(bytes, bytes, from: ctx.from, to: ctx.to,
                env_names: ctx.env_names, bind_names: ctx.bind_names, prefix: ctx.prefix)
    ctx.rows << MigrateRow.new(ctx.project, table, row, [] of EnvMigration::Change,
      note: "already spelled the #{ctx.to.to_s.downcase} way, so it starts resolving after the " \
            "switch — escape it if those bytes are the payload")
  end

  # A String field, for the columns SQLite holds as TEXT.
  private def self.migrate_text(ctx : MigrateCtx, table : String, row : String, text : String,
                                kind : EnvMigration::Kind, evidence : String? = nil) : String?
    return nil if text.empty?
    migrate_field(ctx, table, row, text.to_slice, kind, evidence).try { |b| String.new(b) }
  end

  # Repeater tabs: the request blob, the dial tuple, and the sub-tab label.
  #
  # `request` is `Kind::Request` — the send seam consumes its escape. `target`/`sni` are NOT: a
  # dial tuple runs `Env.expand` once and is never re-scanned, so a `$$` there stays two bytes
  # by design (see `Env::Escape`), which is `Kind::Display`'s rule. `name` is a label.
  private def self.migrate_scan_repeaters(store : Store, ctx : MigrateCtx) : Nil
    store.repeaters.each do |rec|
      label = migrate_row_label(rec.id, rec.name)
      evidence = rec.flow_id.try { |fid| "evidence (flow #{fid}) — a capture expands nothing" }
      if req = migrate_field(ctx, "repeaters.request", label, rec.request,
           EnvMigration::Kind::Request, evidence)
        ctx.writes << migrate_repeater_request_write(rec, req)
      end
      if target = migrate_text(ctx, "repeaters.target", label, rec.target,
           EnvMigration::Kind::Display, evidence)
        ctx.writes << MigrateWrite.new("UPDATE repeaters SET target = ? WHERE id = ?",
          [target.as(::DB::Any), rec.id.as(::DB::Any)])
      end
      if sni = rec.sni.try { |s| migrate_text(ctx, "repeaters.sni", label, s, EnvMigration::Kind::Display, evidence) }
        ctx.writes << MigrateWrite.new("UPDATE repeaters SET sni = ? WHERE id = ?",
          [sni.as(::DB::Any), rec.id.as(::DB::Any)])
      end
      if name = rec.name.try { |s| migrate_text(ctx, "repeaters.name", label, s, EnvMigration::Kind::Display, evidence) }
        ctx.writes << MigrateWrite.new("UPDATE repeaters SET name = ? WHERE id = ?",
          [name.as(::DB::Any), rec.id.as(::DB::Any)])
      end
      migrate_scan_ws(store, ctx, rec, label, evidence)
    end
  end

  # The request write carries the RESPONSE PAIRING DIGEST with it (`response_request_sha256`,
  # Schema V28). That column answers "was this request edited after the response beside it
  # arrived", and it is computed over the SAVED bytes — so leaving it behind would make every
  # migrated tab that has a response report `request_drifted` and refuse to freeze as evidence.
  # The re-spelling changes the spelling and not the exchange (`EnvMigration.safe?` is what
  # proves it), so the digest is recomputed rather than invalidated. A row that never recorded
  # one keeps its NULL: an unknown must not be turned into a claim.
  private def self.migrate_repeater_request_write(rec : Store::RepeaterRecord,
                                                  request : Bytes) : MigrateWrite
    digest = rec.response_request_sha256
    if digest && !digest.empty?
      MigrateWrite.new(
        "UPDATE repeaters SET request = ?, response_request_sha256 = ? WHERE id = ?",
        [request.as(::DB::Any), Evidence.request_digest(request).as(::DB::Any), rec.id.as(::DB::Any)])
    else
      MigrateWrite.new("UPDATE repeaters SET request = ? WHERE id = ?",
        [request.as(::DB::Any), rec.id.as(::DB::Any)])
    end
  end

  # A WS Repeater tab's outbound frames. `direction = 'out'` only (an `in` row is what the origin
  # sent, or one of gori's own `[gori] …` notices), and the PARENT's provenance decides: seeding a
  # WS tab from a capture copies the capture's payloads verbatim, and whether they replay
  # literally is read from the repeater's `flow_id`, not from the frame.
  private def self.migrate_scan_ws(store : Store, ctx : MigrateCtx, rec : Store::RepeaterRecord,
                                   label : String, evidence : String?) : Nil
    store.ws_messages_for_repeater(rec.id).each do |msg|
      next unless msg.direction == "out"
      next if msg.notice?
      if payload = migrate_field(ctx, "ws_messages.payload", "#{label} ##{msg.id}", msg.payload,
           EnvMigration::Kind::Request, evidence)
        ctx.writes << MigrateWrite.new("UPDATE ws_messages SET payload = ? WHERE id = ?",
          [payload.as(::DB::Any), msg.id.as(::DB::Any)])
      end
    end
  end

  # A rewrite rule's replacement text — `Kind::Rule`, because `Rules#substitute` owns `$$` and
  # `$1..$9` in BOTH grammars and only the token spelling follows the syntax. The `pattern` is
  # left alone: it is a needle or a regex, and nothing expands it.
  private def self.migrate_scan_rules(store : Store, ctx : MigrateCtx) : Nil
    store.match_rules.each do |rule|
      next if rule.global? # a global rule lives in settings.json, not in this project
      if repl = migrate_text(ctx, "match_rules.replacement", migrate_row_label(rule.id, rule.name),
           rule.replacement, EnvMigration::Kind::Rule)
        ctx.writes << MigrateWrite.new("UPDATE match_rules SET replacement = ? WHERE id = ?",
          [repl.to_slice.as(::DB::Any), rule.id.as(::DB::Any)])
      end
    end
  end

  # Session-slot header VALUES. `Kind::Request`: the overlay is resolved by
  # `Env.expand_bindings_as` with `Escape::Consume`, so the escape is the send seam's exactly as
  # in a request. Slot NAMES and claimed rule names are table keys and are left alone.
  private def self.migrate_scan_slots(store : Store, ctx : MigrateCtx) : Nil
    raw = store.setting(Store::SESSION_SLOTS_KEY)
    return unless raw
    slots = SessionSlot.parse_json(raw)
    return if slots.empty?
    touched = false
    migrated = slots.map do |slot|
      headers = slot.set_headers.map do |(name, value)|
        after = migrate_text(ctx, "session slots", "#{slot.name} / #{name}", value,
          EnvMigration::Kind::Request)
        next {name, value} unless after
        touched = true
        {name, after}
      end
      SessionSlot.new(slot.name, headers, slot.remove_headers, slot.baseline?, slot.rules)
    end
    return unless touched
    ctx.writes << MigrateWrite.new("UPDATE settings SET value = ? WHERE key = ?",
      [SessionSlot.serialize(migrated).as(::DB::Any), Store::SESSION_SLOTS_KEY.as(::DB::Any)])
  end

  # Fuzzer templates, Miner and Sequencer requests — the same three fields and the same evidence
  # rule as a Repeater tab, because all four workbenches read one `flow_id` for it.
  private def self.migrate_scan_workbenches(store : Store, ctx : MigrateCtx) : Nil
    store.fuzz_sessions.each do |rec|
      label = migrate_row_label(rec.id, rec.name)
      evidence = rec.flow_id.try { |fid| "evidence (flow #{fid}) — a capture expands nothing" }
      if tpl = migrate_text(ctx, "fuzz_sessions.template", label, rec.template,
           EnvMigration::Kind::Request, evidence)
        ctx.writes << MigrateWrite.new("UPDATE fuzz_sessions SET template = ? WHERE id = ?",
          [tpl.to_slice.as(::DB::Any), rec.id.as(::DB::Any)])
      end
      migrate_dial_tuple(ctx, "fuzz_sessions", label, rec.id, rec.target, rec.sni, evidence)
    end
    store.miner_sessions.each do |rec|
      label = migrate_row_label(rec.id, rec.name)
      evidence = rec.flow_id.try { |fid| "evidence (flow #{fid}) — a capture expands nothing" }
      if req = migrate_field(ctx, "miner_sessions.request", label, rec.request,
           EnvMigration::Kind::Request, evidence)
        ctx.writes << MigrateWrite.new("UPDATE miner_sessions SET request = ? WHERE id = ?",
          [req.as(::DB::Any), rec.id.as(::DB::Any)])
      end
      migrate_dial_tuple(ctx, "miner_sessions", label, rec.id, rec.target, rec.sni, evidence)
    end
    store.sequencer_sessions.each do |rec|
      label = migrate_row_label(rec.id, rec.name)
      evidence = rec.flow_id.try { |fid| "evidence (flow #{fid}) — a capture expands nothing" }
      if req = migrate_field(ctx, "sequencer_sessions.request", label, rec.request,
           EnvMigration::Kind::Request, evidence)
        ctx.writes << MigrateWrite.new("UPDATE sequencer_sessions SET request = ? WHERE id = ?",
          [req.as(::DB::Any), rec.id.as(::DB::Any)])
      end
      migrate_dial_tuple(ctx, "sequencer_sessions", label, rec.id, rec.target, rec.sni, evidence)
    end
  end

  private def self.migrate_dial_tuple(ctx : MigrateCtx, table : String, label : String, id : Int64,
                                      target : String, sni : String?, evidence : String?) : Nil
    if after = migrate_text(ctx, "#{table}.target", label, target, EnvMigration::Kind::Display, evidence)
      ctx.writes << MigrateWrite.new("UPDATE #{table} SET target = ? WHERE id = ?",
        [after.as(::DB::Any), id.as(::DB::Any)])
    end
    if s = sni
      if after = migrate_text(ctx, "#{table}.sni", label, s, EnvMigration::Kind::Display, evidence)
        ctx.writes << MigrateWrite.new("UPDATE #{table} SET sni = ? WHERE id = ?",
          [after.as(::DB::Any), id.as(::DB::Any)])
      end
    end
  end

  # Issue titles and bodies. `Kind::Display`: nothing expands them — the token is there because
  # `Env.mask_secrets` put it there instead of a live credential, and its SPELLING still has to
  # follow the grammar or the redaction stops reading as one.
  private def self.migrate_scan_issues(store : Store, ctx : MigrateCtx) : Nil
    store.issues.each do |issue|
      label = migrate_row_label(issue.id, issue.title)
      title = migrate_text(ctx, "issues.title", label, issue.title, EnvMigration::Kind::Display)
      notes = migrate_text(ctx, "issues.notes", label, issue.notes, EnvMigration::Kind::Display)
      next unless title || notes
      ctx.writes << MigrateWrite.new("UPDATE issues SET title = ?, notes = ? WHERE id = ?",
        [(title || issue.title).as(::DB::Any), (notes || issue.notes).as(::DB::Any),
         issue.id.as(::DB::Any)])
    end
  end

  # Note bodies, in both layouts: the note set under `notes.docs` and the pre-multi plain-text
  # `notes` key. The legacy key is rewritten IN PLACE rather than folded into a doc — a migration
  # about token spelling must not also migrate a storage layout.
  private def self.migrate_scan_notes(store : Store, ctx : MigrateCtx) : Nil
    if raw = store.setting(Notes::DOCS_KEY)
      if doc = Notes.parse(raw)
        touched = false
        entries = doc.notes.map do |note|
          after = migrate_text(ctx, "notes", "##{note.id}", note.text, EnvMigration::Kind::Display)
          next note unless after
          touched = true
          Notes::NoteEntry.new(note.id, after)
        end
        if touched
          ctx.writes << MigrateWrite.new("UPDATE settings SET value = ? WHERE key = ?",
            [Notes.serialize(doc.cur, entries, doc.next_id).as(::DB::Any),
             Notes::DOCS_KEY.as(::DB::Any)])
        end
      end
    end
    if legacy = store.setting(Notes::LEGACY_KEY)
      if after = migrate_text(ctx, "notes", "(legacy)", legacy, EnvMigration::Kind::Display)
        ctx.writes << MigrateWrite.new("UPDATE settings SET value = ? WHERE key = ?",
          [after.as(::DB::Any), Notes::LEGACY_KEY.as(::DB::Any)])
      end
    end
  end

  # `12 "login"` — the id the row is addressed by, plus the label an operator recognises it as.
  private def self.migrate_row_label(id : Int64, name : String?) : String
    label = name.try(&.presence)
    label ? "#{id} #{printable(label)}" : id.to_s
  end

  # ── the report ────────────────────────────────────────────────────────────

  # The table, the skips and the totals — pure, so the wording is spec-callable (every guard
  # around it ends in `abort`, which is not catchable).
  private def self.migrate_report_lines(plans : Array(MigratePlan), from : Env::Syntax,
                                        to : Env::Syntax, dry : Bool,
                                        already : Bool = false) : Array(String)
    lines = [] of String
    edits = plans.flat_map(&.edits)
    skips = plans.flat_map(&.skipped)
    verb = dry ? "would re-spell" : "re-spelled"
    lines << migrate_lossy_warning if to.bare?
    lines << migrate_not_idempotent_warning(from, to) if already
    if edits.empty?
      lines << "#{dry ? "nothing to re-spell" : "nothing re-spelled"}: no stored " \
               "#{env_syntax_label(from)} token in #{migrate_project_list(plans)}"
    else
      lines << "#{verb} #{migrate_count(edits.sum(&.changes.size), "token")} in " \
               "#{migrate_count(edits.size, "row")} of #{migrate_project_list(plans)} " \
               "(#{env_syntax_label(from)} → #{env_syntax_label(to)}):"
      lines.concat(migrate_table(edits))
    end
    unless skips.empty?
      lines << "left untouched (#{migrate_count(skips.size, "row")}):"
      lines.concat(migrate_table(skips))
    end
    lines << migrate_unbound_caveat(to) if edits.any? { |r| r.changes.any? { |c| c.ref.try(&.ns.bind?) } }
    lines
  end

  # The one thing the rewrite CANNOT keep byte-exact, said out loud.
  #
  # A binding resolves at SEND time out of a memory-only table, and a name with no value ships
  # LITERALLY (`Env#unbound`). Its literal is its SPELLING, so a run that was sending the four
  # bytes `$FOO` now sends `$BIND.FOO`. There is no migration that avoids it — the grammars spell
  # the token differently, which is the whole feature — and the value on the wire is identical the
  # moment the name is bound, which is the case the rewrite is FOR.
  private def self.migrate_unbound_caveat(to : Env::Syntax) : String
    "note: a binding with no value still ships LITERALLY, and its literal is now the " \
    "#{env_syntax_label(to)} spelling — bind it (`--bind-from`, a send under its slot), or " \
    "escape it if those bytes were the payload."
  end

  # `--migrate` states the grammar its rows are READ as rather than detecting it (nothing in a
  # `$NAME` says which grammar wrote it), so running it twice re-spells its own output: a second
  # `bare --migrate` escapes the `$API` the first one produced. That is only visible to an operator
  # who is told, and the switch itself is the only evidence gori has — so the warning fires exactly
  # when the install is ALREADY the target, which is both the "I switched last week and only now
  # want my drafts moved" case the derivation exists for and the "I already ran this" case.
  private def self.migrate_not_idempotent_warning(from : Env::Syntax, to : Env::Syntax) : String
    "note: this install is already #{env_syntax_label(to)}, so the rows below are being read as " \
    "#{env_syntax_label(from)}. That is right if you have not migrated them yet — but `--migrate` " \
    "is not idempotent (a second run would re-spell its own output), so check the table before " \
    "applying."
  end

  # FIRST, before the table, on the direction that cannot be made safe.
  #
  # bare resolves a name by SHAPE, so going back is not a re-spelling of gori's own bytes: it is a
  # promise about every OTHER place a `$NAME` can come from. The rows in these databases get their
  # escape; a request in a file, a HAR, a body piped into `--request-stdin`, a wordlist, a profile
  # someone exported — gori cannot see those, and the moment the grammar is bare an env var whose
  # name collides with a GraphQL variable resolves into a body nobody wrote it into. That is the
  # collision the namespaces exist to remove, and this is the command that re-opens it.
  private def self.migrate_lossy_warning : String
    "warning: bare is the LOSSY direction. Only what is IN these databases can be escaped — a " \
    "`$NAME` gori cannot see (a request in a file, a HAR, a body piped in, a wordlist, an " \
    "exported profile) starts resolving the moment the grammar is bare, silently, and a GraphQL " \
    "`$id` or a Mongo `$ne` in one of them puts a real credential on the wire."
  end

  private def self.migrate_table(rows : Array(MigrateRow)) : Array(String)
    pw = rows.max_of { |r| column_width(r.project) }
    tw = rows.max_of { |r| column_width(r.table) }
    rw = rows.max_of { |r| column_width(r.row) }
    rows.map do |r|
      tail = r.note ? "  ← #{r.note}" : (r.ambiguous? ? "  ← ambiguous: the name is in both tables" : "")
      "  #{pad(r.project, pw)}  #{pad(r.table, tw)}  #{pad(r.row, rw)}  #{migrate_changes(r)}#{tail}"
    end
  end

  # The tokens only, and at most three of them: the point of the line is WHICH spellings moved,
  # and a request body pasted into a report is not readable at any width.
  private def self.migrate_changes(row : MigrateRow) : String
    return "(no token to re-spell)" if row.changes.empty?
    shown = row.changes.first(3).map { |c| "#{printable(c.before)} → #{printable(c.after)}" }
    rest = row.changes.size - shown.size
    shown.join(", ") + (rest > 0 ? ", +#{rest} more" : "")
  end

  private def self.migrate_project_list(plans : Array(MigratePlan)) : String
    return "no project" if plans.empty?
    return "project #{plans[0].project}" if plans.size == 1
    "#{plans.size} projects (#{plans.map(&.project).join(", ")})"
  end

  private def self.migrate_count(n : Int32, noun : String) : String
    "#{n} #{noun}#{n == 1 ? "" : "s"}"
  end

  # ── the write ─────────────────────────────────────────────────────────────

  # The whole opt-in half: scan, print, and — unless `--dry-run` — back up and apply.
  # Returns false when nothing was written (a dry run, or no change found), so the caller knows
  # whether to talk about backups.
  # `io` is where the table goes and `warn_io` where the "which project" notice goes — injected
  # rather than hardcoded, because every guard in here ends in `abort` and the only thing a spec
  # can assert about the rest is what it printed (`Run.default_project_io`, same reason).
  private def self.migrate_env_syntax(to : Env::Syntax, *, dry : Bool, project_name : String?,
                                      db_path : String?, all : Bool,
                                      io : IO = STDOUT, warn_io : IO? = STDERR) : Bool
    from = migrate_source_syntax(to)
    targets = migrate_targets(project_name, db_path, all)
    if project_name.nil? && db_path.nil? && !all && targets.size == 1
      warn_io.try &.puts "gori settings env-syntax --migrate: using project #{targets[0].name} " \
                         "(most recently active) — name another with --project NAME / --db PATH, " \
                         "or pass --all-projects"
    end
    migrate_refuse_busy!(targets) unless dry
    already = Settings.env_syntax == to
    plans = targets.map { |t| migrate_scan(t, from, to) }
    migrate_report_lines(plans, from, to, dry, already).each { |line| io.puts line }
    if dry
      io.puts "--dry-run wrote nothing. Re-run without it to apply, and to set the grammar to " \
              "#{env_syntax_label(to)}."
      return false
    end
    wrote = false
    plans.each do |plan|
      next if plan.writes.empty?
      wrote = true
      backup = migrate_apply!(plan)
      io.puts "#{plan.project}: #{migrate_count(plan.writes.size, "update")} written — " \
              "backup at #{backup}"
    end
    io.puts "nothing to write — the stored tokens already read as #{env_syntax_label(to)}" unless wrote
    wrote
  end

  # A running gori holds the database open, and its in-memory state (open Repeater tabs, a loaded
  # binding table, the Rewriter's rule snapshot) is what it will write back over this. `OpenLock`
  # is the signal every other destructive path already uses; refuse by name rather than racing it.
  private def self.migrate_refuse_busy!(targets : Array(Project)) : Nil
    busy = targets.select { |t| OpenLock.in_use?(t.db_path) }
    return if busy.empty?
    abort "gori settings env-syntax --migrate: #{busy.size == 1 ? "this project is" : "these projects are"} " \
          "open in another gori (a TUI, a `gori mcp` server, a capture): " \
          "#{busy.map(&.name).join(", ")}. Close #{busy.size == 1 ? "it" : "them"} first — a " \
          "running session would write its own copy of these rows back over the migration. " \
          "`--dry-run` is safe to run now."
  end

  # Back up, then apply every planned `UPDATE` in ONE transaction.
  #
  # Its own connection, not the `Store` writer: the plan is a batch of row updates that must
  # either all land or none, and `Store` exposes no transaction seam (every setter is its own
  # `BEGIN IMMEDIATE`). `OpenLock.try_exclusive` is held across the whole thing, so a gori that
  # starts mid-migration waits rather than reading half of it.
  #
  # The backup is `VACUUM INTO`, not a file copy: the database is WAL, so the committed state is
  # split between `gori.db` and `gori.db-wal` and copying one of them produces a file that is
  # either stale or torn. `VACUUM INTO` writes a single consistent database.
  private def self.migrate_apply!(plan : MigratePlan) : String
    guard = OpenLock.try_exclusive(plan.db_path)
    unless guard
      abort "gori settings env-syntax --migrate: #{plan.project} was opened by another gori " \
            "while this ran — nothing was written to it. Close it and re-run."
    end
    begin
      backup = migrate_backup_path(plan.db_path, plan.to)
      ::DB.open("sqlite3:#{plan.db_path}?busy_timeout=5000") do |db|
        db.using_connection do |conn|
          conn.exec("VACUUM INTO ?", backup)
          File.chmod(backup, 0o600) rescue nil
          conn.exec("BEGIN IMMEDIATE")
          begin
            plan.writes.each { |w| conn.exec(w.sql, args: w.args) }
            conn.exec("COMMIT")
          rescue ex
            conn.exec("ROLLBACK") rescue nil
            raise ex
          end
        end
      end
      backup
    rescue ex : ::DB::Error | ::SQLite3::Exception | File::Error
      abort "gori settings env-syntax --migrate: #{plan.project} was NOT migrated " \
            "(#{ex.message}) — the database is unchanged, and the backup beside it, if one was " \
            "written, is a copy of that same state."
    ensure
      guard.close
    end
  end

  # `gori.db.pre-namespaced-20260913-142530` beside the database. A name that says WHAT it is a
  # copy of the state before, so an operator who finds two of them knows which way each went.
  private def self.migrate_backup_path(db_path : String, to : Env::Syntax) : String
    stamp = Time.local.to_s("%Y%m%d-%H%M%S")
    base = "#{db_path}.pre-#{env_syntax_label(to)}-#{stamp}"
    return base unless File.exists?(base)
    n = 2
    while File.exists?("#{base}.#{n}")
      n += 1
    end
    "#{base}.#{n}"
  end
end
