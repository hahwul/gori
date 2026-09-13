require "db"
require "sqlite3"
require "../env_migration"
require "./globals"
require "../notes"
require "../session_slot"
require "../evidence"
require "../config_log"
require "../flow_source"
require "../store"

module Gori
  module EnvMigration
    # A PROJECT DATABASE reconciled with this install's token grammar, the first time the project
    # is opened after the grammar moved.
    #
    # Namespaced is the grammar for everyone, so an existing project is full of bare `$KEY` drafts,
    # rule replacements and slot headers that the new reader would hand to the wire as literal
    # text. Nothing asks the operator: the project says which grammar its own bytes are spelled in
    # (the MARKER below), the install says which one it reads, and when the two disagree gori
    # re-spells the rows and says what it did.
    #
    # The COLUMN LIST is the interesting part, and it is a judgement about each column rather than
    # a sweep:
    #
    #   * REWRITTEN — bytes an operator authored that a send seam expands: a draft Repeater's
    #     request/target/sni/name, its WS messages, a Fuzzer template, a Miner and a Sequencer
    #     request, a rewrite rule's `replacement`, a session slot's header values, and the display
    #     text `Env.mask_secrets` writes a token into (issue titles and notes, note bodies).
    #   * SKIPPED — every EVIDENCE row (`flow_id` not null). A capture expands nothing
    #     (`Repeater::PlanOptions#evidence?`), so its `$filter` is a byte the origin sent;
    #     re-spelling it would edit a capture to no effect on the wire and every effect on the
    #     record.
    #   * LEFT ALONE, deliberately — project and global env var NAMES (they are table keys, not
    #     tokens) and their VALUES (nothing re-expands a var's value), extract-rule names (the
    #     same), a rule's `pattern` (a regex/needle, never expanded), a Fuzzer's payload sets
    #     (`config`, never expanded), `fuzz_results`/`issue_evidence`/`flows` (sent bytes —
    #     evidence), QL views, scope rules, colormarkers and probe rules (no token seam at all).

    # The per-project marker: WHICH grammar the tokens in this database are spelled in. Lives in
    # the project's own settings KV, next to `env.vars` (`Env::PROJECT_VARS_KEY`) — the same table
    # the project's env vars, slots and views use, so it travels with the database it describes and
    # never with the install.
    #
    # ABSENT means bare, and that is the whole upgrade path: every database written before
    # namespaces existed carries no marker, which is exactly true of its bytes.
    MARKER_KEY = Env::PROJECT_SYNTAX_KEY

    # The grammar `store`'s tokens are spelled in. An unreadable value is treated as the ABSENT
    # value rather than guessed at, because bare is the answer that cannot lose data: re-spelling
    # bare→namespaced is representable, and a wrong guess in that direction leaves the text alone
    # (a name in neither table is a literal in both grammars).
    def self.stored_syntax(store : Store) : Env::Syntax
      raw = store.setting(MARKER_KEY)
      return Env::Syntax::Bare unless raw
      Env::Syntax.parse?(raw.strip) || Env::Syntax::Bare
    rescue
      Env::Syntax::Bare
    end

    # What a reconcile did to one project. `tokens`/`rows` are what moved, `left` the rows whose
    # bytes have no equivalent spelling in the target grammar (named rather than shipped
    # differently), `backup` the copy written before the first write — nil when there was nothing
    # to write, which is the fresh-database case.
    record StoreReport,
      project : String,
      from : Env::Syntax,
      to : Env::Syntax,
      tokens : Int32,
      rows : Int32,
      left : Int32,
      backup : String?,
      global_hint : String? = nil,
      error : String? = nil,
      bare_hints : Array(String) = [] of String do
      # Nothing moved and nothing needs saying: a database that had no token in the old grammar
      # got its marker and no backup. The surfaces use this to stay quiet on a fresh project.
      def quiet? : Bool
        tokens.zero? && left.zero? && global_hint.nil? && error.nil? && bare_hints.empty?
      end

      # THE line, on every surface. One sentence per project, counters first, the way back last.
      def line : String
        if err = error
          return "project #{project}: could not re-spell the stored #{from.to_s.downcase} tokens " \
                 "(#{err}) — they are read as #{EnvMigration.spelling(to)} until it succeeds, so " \
                 "a `#{Env.spell("KEY", Env::Namespace::Env, from)}` in a draft is literal text for now"
        end
        parts = [] of String
        parts << "project #{project}: #{EnvMigration.counted(tokens, "token")} re-spelled to " \
                 "#{EnvMigration.spelling(to)} in #{EnvMigration.counted(rows, "row")}"
        parts << "#{EnvMigration.counted(left, "row")} left as authored (no #{to.to_s.downcase} " \
                 "spelling sends the same bytes)" if left > 0
        line = parts.join(", ")
        line += " — backup at #{backup}" if backup
        line
      end

      # The line plus, when there is one, the global-rule line — they belong to the same event: the
      # grammar moved, the rows were re-spelled, and a rule in settings.json was not. Named
      # `notices` rather than `lines` so it cannot be misread (by a human or by ameba) as
      # `String#lines`.
      def notices : Array(String)
        out = [] of String
        out << line unless tokens.zero? && left.zero? && error.nil?
        out << bare_hint_line unless bare_hints.empty?
        global_hint.try { |h| out << h }
        out
      end

      # The one thing a re-spelling can neither fix nor ignore. A dial tuple is expanded once, with
      # `Escape::Preserve`, and nothing unescapes it — so a literal `$id` in a target has no escaped
      # spelling (`$$id` would reach the resolver as `$$id`). Going to bare, that `$id` starts
      # resolving, and the honest answer is to name it rather than change the bytes or stay quiet.
      def bare_hint_line : String
        "project #{project}: #{EnvMigration.counted(bare_hints.size, "literal")} in a target or SNI " \
        "(#{bare_hints.join(", ")}) now names a #{to.to_s.downcase} variable and will be " \
        "substituted on the next dial — a dial tuple has no escape, so change the name or the " \
        "variable if that is not what you meant"
      end
    end

    # ── the reconcile ─────────────────────────────────────────────────────────

    # Bring `store`'s tokens into this install's grammar, or return nil when there is nothing to
    # do. Called by every surface that opens a project to WORK in it — the TUI's `Session.open`,
    # the CLI's `open_store`, and the MCP server's bind — so the answer is the same wherever the
    # operator opened it from.
    #
    # `store` is used for READING only (it may be a read-only handle); the writes go through this
    # module's own connection to `db_path`, so a `gori run history list` migrates exactly as a TUI
    # does. Never raises: a project whose tokens could not be re-spelled must still open, with the
    # failure said out loud (`StoreReport#error`) rather than an aborted command.
    def self.reconcile(store : Store, db_path : String, project : String) : StoreReport?
      # A grammar gori had to GUESS may not rewrite anything — an unreadable settings.json, a
      # half-applied one, a typo where the value should be. See `Settings.env_syntax_stated?`.
      return nil unless Settings.env_syntax_stated?
      to = Settings.env_syntax
      from = stored_syntax(store)
      return nil if from == to
      plan = Plan.new(project, from, to, env_names(store), bind_names(store),
        enabled_bind_names(store), Settings.env_prefix)
      begin
        scan(store, plan)
      rescue ex
        # A row gori could not even READ. Nothing has been written yet, so the marker stays where it
        # is and the next open tries again — but the operator hears about it now, because until it
        # succeeds their drafts are spelled in a grammar this install does not read.
        return StoreReport.new(project, from, to, 0, 0, 0, nil,
          error: ex.message.presence || ex.class.name)
      end
      apply(plan, db_path)
    end

    # The ENV table as the grammar being LEFT resolved it: the global vars merged under this
    # project's own, exactly `Env.effective_vars`' membership — read from the STORE rather than
    # from `Settings.project_env_vars`, because the reconcile runs BEFORE `Env.load_project` has
    # published this project's layer (and because one process opens several projects).
    def self.env_names(store : Store) : Set(String)
      names = Settings.env_vars.map(&.[0]).to_set
      Env.parse_vars_json(store.setting(Env::PROJECT_VARS_KEY)).each { |(k, _)| names << k }
      names
    end

    # The BIND table, wider than what is bound: every extract rule's name (enabled or not) plus
    # every name a session slot claims. A binding value is memory-only, so "what is bound right
    # now" is empty at open time and would re-spell nothing; what the operator WROTE is the
    # declared name, and a disabled rule's name is still the name they wrote.
    def self.bind_names(store : Store) : Set(String)
      names = store.extract_rules.map(&.name).to_set
      SessionSlot.parse_json(store.setting(Store::SESSION_SLOTS_KEY)).each do |slot|
        slot.rules.each { |r| names << r }
      end
      names
    end

    # The half of `bind_names` that ever RESOLVED: the names an ENABLED extract rule declares.
    #
    # Both halves of the live binding table filter on `enabled?` (`Bindings#values`,
    # `Bindings#declared`), so a switched-off rule's name was an ordinary unknown key under bare —
    # it resolved in no pass and in no merged table. Which matters most for a RULE replacement,
    # whose bare table layered the bindings OVER the env vars: without this set, a name that is
    # both an env var and a disabled extract rule was re-spelled `$BIND.name`, and the rule then
    # injected its own spelling into live traffic instead of the env value bare had put there.
    def self.enabled_bind_names(store : Store) : Set(String)
      store.extract_rules.select(&.enabled?).map(&.name).to_set
    end

    # One `UPDATE`, held until the whole project has been scanned so the write is one transaction.
    record Write, sql : String, args : Array(::DB::Any)

    # The scan's accumulator: the grammars, the two name tables, the pending writes and the
    # counters. A class rather than a record because the counters move as the columns are walked,
    # and a struct copied per call site is how one of them silently stops counting.
    class Plan
      getter project : String
      getter from : Env::Syntax
      getter to : Env::Syntax
      getter env_names : Set(String)
      getter bind_names : Set(String)
      # The ENABLED subset of `bind_names` — see `EnvMigration.enabled_bind_names`.
      getter enabled_bind_names : Set(String)
      getter prefix : String
      getter writes = [] of Write
      property tokens = 0
      property rows = 0
      property left = 0
      # Spellings a DIAL row carries that the target grammar will start resolving and no escape can
      # protect (`EnvMigration::Kind#bare_resolution_hint?`). Not a counter and not a `left` row:
      # the bytes are correct after the re-spelling, and this is the sentence about what they will
      # now mean.
      getter hints = [] of String

      def initialize(@project, @from, @to, @env_names, @bind_names, @enabled_bind_names, @prefix)
      end
    end

    private def self.scan(store : Store, plan : Plan) : Nil
      scan_repeaters(store, plan)
      scan_rules(store, plan)
      scan_slots(store, plan)
      scan_workbenches(store, plan)
      scan_issues(store, plan)
      scan_notes(store, plan)
    end

    # Rewrite one field. Returns the new bytes when they should be WRITTEN, nil otherwise (no
    # change, an evidence row, or a rewrite whose wire would move).
    #
    # `evidence` is the row's provenance, not a flag about the bytes: a capture is not expanded, so
    # there is no token in it to re-spell.
    private def self.field(plan : Plan, bytes : Bytes, kind : Kind,
                           evidence : Bool = false) : Bytes?
      # An EVIDENCE row is not scanned at all. The hint channel is the reason that matters now: a
      # capture expands nothing, so a `$id` in one is neither re-spelled nor something to warn
      # about, and collecting it would put a capture's bytes in a report about drafts.
      return nil if evidence
      after, changes = rewrite(bytes, from: plan.from, to: plan.to,
        env_names: plan.env_names, bind_names: plan.bind_names,
        enabled_bind_names: plan.enabled_bind_names, kind: kind, prefix: plan.prefix,
        hints: plan.hints)
      return nil if changes.empty?
      # The wire is the invariant (see `EnvMigration`). A text whose bytes the target grammar
      # cannot spell is LEFT and counted — a migration that ships different bytes than the
      # operator's last send is worse than one that says it could not. Asked of every kind that HAS
      # a wire, each against its own pass list: a slot header value is seen by the binding seam
      # alone, a dial tuple by the env pass alone, and a rule replacement by `Rules#substitute`'s
      # own grammar (`EnvMigration.rule_wire`).
      if kind.has_wire? && !safe?(bytes, after, from: plan.from, to: plan.to,
           env_names: plan.env_names, bind_names: plan.bind_names,
           enabled_bind_names: plan.enabled_bind_names, kind: kind, prefix: plan.prefix)
        plan.left += 1
        return nil
      end
      plan.rows += 1
      plan.tokens += changes.size
      after
    end

    # A String field, for the columns SQLite holds as TEXT.
    private def self.text(plan : Plan, text : String, kind : Kind,
                          evidence : Bool = false) : String?
      return nil if text.empty?
      field(plan, text.to_slice, kind, evidence).try { |b| String.new(b) }
    end

    # Repeater tabs: the request blob, the dial tuple, and the sub-tab label.
    #
    # `request` is `Kind::Request` — the send seam consumes its escape. `target`/`sni` are
    # `Kind::Dial`: a dial tuple runs `Env.expand` ONCE, with `Escape::Preserve`, and is never
    # re-scanned — so the ENV table is the only one that resolves there and nothing consumes a `$$`.
    # `name` is `Kind::Display`: a label nothing ever expands.
    private def self.scan_repeaters(store : Store, plan : Plan) : Nil
      store.repeaters.each do |rec|
        evidence = !rec.flow_id.nil?
        if req = field(plan, rec.request, Kind::Request, evidence)
          plan.writes << repeater_request_write(rec, req)
        end
        if target = text(plan, rec.target, Kind::Dial, evidence)
          plan.writes << Write.new("UPDATE repeaters SET target = ? WHERE id = ?",
            [target.as(::DB::Any), rec.id.as(::DB::Any)])
        end
        if sni = rec.sni.try { |s| text(plan, s, Kind::Dial, evidence) }
          plan.writes << Write.new("UPDATE repeaters SET sni = ? WHERE id = ?",
            [sni.as(::DB::Any), rec.id.as(::DB::Any)])
        end
        if name = rec.name.try { |s| text(plan, s, Kind::Display, evidence) }
          plan.writes << Write.new("UPDATE repeaters SET name = ? WHERE id = ?",
            [name.as(::DB::Any), rec.id.as(::DB::Any)])
        end
        scan_ws(store, plan, rec, evidence)
      end
    end

    # The request write carries the RESPONSE PAIRING DIGEST with it (`response_request_sha256`,
    # Schema V28). That column answers "was this request edited after the response beside it
    # arrived", and it is computed over the SAVED bytes — so leaving it behind would make every
    # migrated tab that has a response report `request_drifted` and refuse to freeze as evidence.
    # The re-spelling changes the spelling and not the exchange (`safe?` is what proves it), so the
    # digest is recomputed rather than invalidated. A row that never recorded one keeps its NULL:
    # an unknown must not be turned into a claim.
    private def self.repeater_request_write(rec : Store::RepeaterRecord, request : Bytes) : Write
      digest = rec.response_request_sha256
      if digest && !digest.empty?
        Write.new(
          "UPDATE repeaters SET request = ?, response_request_sha256 = ? WHERE id = ?",
          [request.as(::DB::Any), Evidence.request_digest(request).as(::DB::Any), rec.id.as(::DB::Any)])
      else
        Write.new("UPDATE repeaters SET request = ? WHERE id = ?",
          [request.as(::DB::Any), rec.id.as(::DB::Any)])
      end
    end

    # A WS Repeater tab's outbound frames. `direction = 'out'` only (an `in` row is what the origin
    # sent, or one of gori's own `[gori] …` notices), and the PARENT's provenance decides: seeding a
    # WS tab from a capture copies the capture's payloads verbatim, and whether they replay
    # literally is read from the repeater's `flow_id`, not from the frame.
    private def self.scan_ws(store : Store, plan : Plan, rec : Store::RepeaterRecord,
                             evidence : Bool) : Nil
      store.ws_messages_for_repeater(rec.id).each do |msg|
        next unless msg.direction == "out"
        next if msg.notice?
        if payload = field(plan, msg.payload, Kind::Request, evidence)
          plan.writes << Write.new("UPDATE ws_messages SET payload = ? WHERE id = ?",
            [payload.as(::DB::Any), msg.id.as(::DB::Any)])
        end
      end
    end

    # A rewrite rule's replacement text — `Kind::Rule`, because `Rules#substitute` owns `$$` and
    # `$1..$9` in BOTH grammars and only the token spelling follows the syntax. The `pattern` is
    # left alone: it is a needle or a regex, and nothing expands it.
    private def self.scan_rules(store : Store, plan : Plan) : Nil
      store.match_rules.each do |rule|
        next if rule.global? # a global rule lives in settings.json — see `migrate_global_rules`
        if repl = text(plan, rule.replacement, Kind::Rule)
          plan.writes << Write.new("UPDATE match_rules SET replacement = ? WHERE id = ?",
            [repl.to_slice.as(::DB::Any), rule.id.as(::DB::Any)])
        end
      end
    end

    # Session-slot header VALUES. `Kind::Slot`: the escape is the send seam's exactly as in a
    # request (`Env.expand_bindings_as`, `Escape::Consume`) — but that seam is the ONLY pass over
    # these bytes and it resolves BIND alone, so an env-var name here was never a reference. Reading
    # it as one re-spelled a literal `$API` into a `$ENV.API` that looks live and resolves in no
    # pass this value ever sees. Slot NAMES and claimed rule names are table keys and are left
    # alone.
    private def self.scan_slots(store : Store, plan : Plan) : Nil
      raw = store.setting(Store::SESSION_SLOTS_KEY)
      return unless raw
      slots = SessionSlot.parse_json(raw)
      return if slots.empty?
      touched = false
      migrated = slots.map do |slot|
        headers = slot.set_headers.map do |(name, value)|
          after = text(plan, value, Kind::Slot)
          next {name, value} unless after
          touched = true
          {name, after}
        end
        SessionSlot.new(slot.name, headers, slot.remove_headers, slot.baseline?, slot.rules)
      end
      return unless touched
      plan.writes << Write.new("UPDATE settings SET value = ? WHERE key = ?",
        [SessionSlot.serialize(migrated).as(::DB::Any), Store::SESSION_SLOTS_KEY.as(::DB::Any)])
    end

    # Fuzzer templates, Miner and Sequencer requests — the same three fields and the same evidence
    # rule as a Repeater tab, because all four workbenches read one `flow_id` for it.
    private def self.scan_workbenches(store : Store, plan : Plan) : Nil
      store.fuzz_sessions.each do |rec|
        evidence = !rec.flow_id.nil?
        if tpl = text(plan, rec.template, Kind::Request, evidence)
          plan.writes << Write.new("UPDATE fuzz_sessions SET template = ? WHERE id = ?",
            [tpl.to_slice.as(::DB::Any), rec.id.as(::DB::Any)])
        end
        scan_dial_tuple(plan, "fuzz_sessions", rec.id, rec.target, rec.sni, evidence)
      end
      store.miner_sessions.each do |rec|
        evidence = !rec.flow_id.nil?
        if req = field(plan, rec.request, Kind::Request, evidence)
          plan.writes << Write.new("UPDATE miner_sessions SET request = ? WHERE id = ?",
            [req.as(::DB::Any), rec.id.as(::DB::Any)])
        end
        scan_dial_tuple(plan, "miner_sessions", rec.id, rec.target, rec.sni, evidence)
      end
      store.sequencer_sessions.each do |rec|
        evidence = !rec.flow_id.nil?
        if req = field(plan, rec.request, Kind::Request, evidence)
          plan.writes << Write.new("UPDATE sequencer_sessions SET request = ? WHERE id = ?",
            [req.as(::DB::Any), rec.id.as(::DB::Any)])
        end
        scan_dial_tuple(plan, "sequencer_sessions", rec.id, rec.target, rec.sni, evidence)
      end
    end

    private def self.scan_dial_tuple(plan : Plan, table : String, id : Int64, target : String,
                                     sni : String?, evidence : Bool) : Nil
      if after = text(plan, target, Kind::Dial, evidence)
        plan.writes << Write.new("UPDATE #{table} SET target = ? WHERE id = ?",
          [after.as(::DB::Any), id.as(::DB::Any)])
      end
      if s = sni
        if after = text(plan, s, Kind::Dial, evidence)
          plan.writes << Write.new("UPDATE #{table} SET sni = ? WHERE id = ?",
            [after.as(::DB::Any), id.as(::DB::Any)])
        end
      end
    end

    # Issue titles and bodies. `Kind::Display`: nothing expands them — the token is there because
    # `Env.mask_secrets` put it there instead of a live credential, and its SPELLING still has to
    # follow the grammar or the redaction stops reading as one.
    private def self.scan_issues(store : Store, plan : Plan) : Nil
      store.issues.each do |issue|
        title = text(plan, issue.title, Kind::Display)
        notes = text(plan, issue.notes, Kind::Display)
        next unless title || notes
        plan.writes << Write.new("UPDATE issues SET title = ?, notes = ? WHERE id = ?",
          [(title || issue.title).as(::DB::Any), (notes || issue.notes).as(::DB::Any),
           issue.id.as(::DB::Any)])
      end
    end

    # Note bodies, in both layouts: the note set under `notes.docs` and the pre-multi plain-text
    # `notes` key. The legacy key is rewritten IN PLACE rather than folded into a doc — a migration
    # about token spelling must not also migrate a storage layout.
    private def self.scan_notes(store : Store, plan : Plan) : Nil
      if raw = store.setting(Notes::DOCS_KEY)
        if doc = Notes.parse(raw)
          touched = false
          entries = doc.notes.map do |note|
            after = text(plan, note.text, Kind::Display)
            next note unless after
            touched = true
            Notes::NoteEntry.new(note.id, after)
          end
          if touched
            plan.writes << Write.new("UPDATE settings SET value = ? WHERE key = ?",
              [Notes.serialize(doc.cur, entries, doc.next_id).as(::DB::Any),
               Notes::DOCS_KEY.as(::DB::Any)])
          end
        end
      end
      if legacy = store.setting(Notes::LEGACY_KEY)
        if after = text(plan, legacy, Kind::Display)
          plan.writes << Write.new("UPDATE settings SET value = ? WHERE key = ?",
            [after.as(::DB::Any), Notes::LEGACY_KEY.as(::DB::Any)])
        end
      end
    end

    # ── the write ─────────────────────────────────────────────────────────────

    # Back up (only if there is a row to change), then apply every planned `UPDATE` and the marker
    # in ONE transaction.
    #
    # Its own connection, not the caller's `Store`: the plan must either all land or none, the
    # caller's handle may be read-only, and `Store` exposes no transaction seam (every setter is
    # its own `BEGIN IMMEDIATE`).
    #
    # The marker is re-read INSIDE the transaction. Two surfaces open the same project at the same
    # time all the time (a TUI and a `gori mcp` server on one engagement), and `BEGIN IMMEDIATE`
    # plus that re-read is what makes the second one find the work done instead of re-spelling
    # already-re-spelled bytes. No `OpenLock`: this process is holding the SHARED open lock on this
    # very database (`Store.open`), so asking for the exclusive one would be waiting for itself.
    #
    # The backup is `VACUUM INTO`, not a file copy: the database is WAL, so the committed state is
    # split between `gori.db` and `gori.db-wal` and copying one of them produces a file that is
    # either stale or torn. `VACUUM INTO` writes a single consistent database — and it cannot run
    # inside a transaction, which is why it happens first and is deleted again if the marker check
    # says a peer got there.
    private def self.apply(plan : Plan, db_path : String) : StoreReport?
      backup = plan.writes.empty? ? nil : vacuum_into(db_path, plan.to)
      # The project half of the report, known before the write: the counters are the scan's, and the
      # backup is already on disk. Built here because the ACTIVITY row below is written on THIS
      # connection and needs the same sentence the surfaces print.
      report = StoreReport.new(plan.project, plan.from, plan.to, plan.tokens, plan.rows, plan.left,
        backup, bare_hints: plan.hints.uniq)
      applied = false
      ::DB.open("sqlite3:#{db_path}?busy_timeout=5000") do |db|
        db.using_connection do |conn|
          conn.exec("BEGIN IMMEDIATE")
          begin
            if marker_syntax(conn) == plan.to
              conn.exec("ROLLBACK")
            else
              plan.writes.each { |w| conn.exec(w.sql, args: w.args) }
              conn.exec("INSERT INTO settings (key, value) VALUES (?, ?) " \
                        "ON CONFLICT(key) DO UPDATE SET value = ?",
                MARKER_KEY, plan.to.to_s.downcase, plan.to.to_s.downcase)
              # The ACTIVITY feed, in the same transaction and on the same connection — NOT through
              # `ConfigLog.record(store, …)`. The caller's handle is read-only on every read-only
              # `gori run`, and an event written through it is dropped without a word: the one
              # surface whose whole question is "what happened to this project" would have been the
              # one place this never showed up.
              log_migration(conn, report) unless report.quiet?
              conn.exec("COMMIT")
              applied = true
            end
          rescue ex
            conn.exec("ROLLBACK") rescue nil
            raise ex
          end
        end
      end
      unless applied
        # A peer opener committed the same migration while this one was scanning. Its backup is the
        # one that describes the pre-migration state; ours is a copy of bytes nobody changed.
        backup.try { |b| File.delete?(b) }
        return nil
      end
      report.copy_with(global_hint: global_rule_hint(plan))
    rescue ex : ::DB::Error | ::SQLite3::Exception | File::Error
      StoreReport.new(plan.project, plan.from, plan.to, 0, 0, 0, nil,
        error: ex.message.presence || ex.class.name)
    end

    # One `config` row in the event feed, written the way `ConfigLog.record` writes one (same
    # `source`, same `actor` question) but on the migration's own connection.
    private def self.log_migration(conn : ::DB::Connection, report : StoreReport) : Nil
      conn.exec("INSERT INTO events (created_at, source, kind, level, message, actor) " \
                "VALUES (?,?,?,?,?,?)",
        (Time.utc - Time::UNIX_EPOCH).total_microseconds.to_i64,
        ConfigLog::SOURCE, "env", "info", report.line, FlowSource.surface.try(&.token))
    end

    # The GLOBAL rewrite rules, NAMED and never rewritten from here.
    #
    # They live in settings.json, so `Settings.load` (and the CLI verb) re-spell them when the
    # install's grammar moves — with only the GLOBAL env var names to go on, because no project is
    # open at that point. A rule that names a PROJECT var or an extract rule is therefore still
    # spelled the old way, and this is where gori can finally see that: the project whose tables
    # give those names meaning is open.
    #
    # Reported rather than rewritten, and that is not squeamishness — it is the one place a rewrite
    # would not be idempotent. The project marker says which grammar the ROWS are in; nothing says
    # which grammar the RULES are in, so a second project opening after the same switch would
    # re-spell an already-re-spelled replacement (namespaced → bare escapes `$token` into
    # `$$token`, and the rule then inserts four literal bytes into live traffic).
    #
    # Only a change that carries a `ref` counts: an ESCAPE-only change means the rule is already
    # spelled the target's way and merely holds a sigil the target grammar pairs differently, which
    # is not something for an operator to go and fix.
    private def self.global_rule_hint(plan : Plan) : String?
      names = [] of String
      Settings.rewriter_rules.each do |rule|
        next if rule.replacement.empty?
        _, changes = rewrite(rule.replacement.to_slice, from: plan.from, to: plan.to,
          env_names: plan.env_names, bind_names: plan.bind_names,
          enabled_bind_names: plan.enabled_bind_names, kind: Kind::Rule, prefix: plan.prefix)
        next unless changes.any?(&.ref)
        names << (rule.name.presence || "##{rule.id}")
      end
      return nil if names.empty?
      "global rewrite rules: #{counted(names.size, "rule")} (#{names.join(", ")}) still spell a " \
      "token the #{plan.from.to_s.downcase} way and rewrite traffic in EVERY project — a global " \
      "rule lives in settings.json, not in this database, so re-spell it in Settings → Match & " \
      "Replace or with `gori run rewriter`"
    end

    # The marker as this CONNECTION sees it, inside the transaction. Raw SQL rather than
    # `Store#setting`: the point of the re-read is that it happens on the connection holding the
    # write lock, and the caller's store is a different connection (possibly read-only).
    private def self.marker_syntax(conn : ::DB::Connection) : Env::Syntax
      raw = conn.query_one?("SELECT value FROM settings WHERE key = ?", MARKER_KEY, as: String)
      return Env::Syntax::Bare unless raw
      Env::Syntax.parse?(raw.strip) || Env::Syntax::Bare
    end

    # `gori.db.pre-namespaced-20260913-142530` beside the database. A name that says what it is a
    # copy of the state before, so an operator who finds two of them knows which way each went.
    private def self.vacuum_into(db_path : String, to : Env::Syntax) : String
      dest = unique_path("#{db_path}.pre-#{to.to_s.downcase}-#{stamp}")
      ::DB.open("sqlite3:#{db_path}?busy_timeout=5000") do |db|
        db.using_connection(&.exec("VACUUM INTO ?", dest))
      end
      File.chmod(dest, 0o600) rescue nil
      dest
    end
  end
end
