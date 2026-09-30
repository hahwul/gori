require "db"
require "./scope_match" # V31's backfill calls gori_static_asset; `migrate!` installs it

module Gori
  class Store
    # Tiny `PRAGMA user_version` migration runner. Each entry in MIGRATIONS is a
    # list of statements taking the DB from version N to N+1. V1 is the v0.1.0
    # baseline schema; every later change to a released schema arrives as a NEW
    # entry appended to MIGRATIONS (never an edit to an existing one).
    module Schema
      VERSION = MIGRATIONS.size

      V1 = [
        # ── Capture ──────────────────────────────────────────────────────────────
        # The flow firehose. `request_size`/`response_size` keep the TRUE wire size;
        # the stored body BLOBs may be truncated to a ceiling so a huge transfer can't
        # OOM the proxy or bloat one row, and the *_body_truncated flags mark the cut.
        # h2_conn_id/h2_stream_id link a decoded h2 projection back to its raw frame log.
        <<-SQL,
          CREATE TABLE flows (
            id                      INTEGER PRIMARY KEY,
            created_at              INTEGER NOT NULL,
            scheme                  TEXT    NOT NULL,
            host                    TEXT    NOT NULL,
            port                    INTEGER NOT NULL,
            method                  TEXT    NOT NULL,
            target                  TEXT    NOT NULL,
            http_version            TEXT    NOT NULL,
            sni                     TEXT,
            alpn                    TEXT,
            tls_version             TEXT,
            request_head            BLOB    NOT NULL,
            request_body            BLOB,
            response_head           BLOB,
            response_body           BLOB,
            status                  INTEGER,
            reason                  TEXT,
            content_type            TEXT,
            request_size            INTEGER NOT NULL DEFAULT 0,
            response_size           INTEGER,
            state                   INTEGER NOT NULL,
            ttfb_us                 INTEGER,
            duration_us             INTEGER,
            error                   TEXT,
            h2_conn_id              INTEGER,
            h2_stream_id            INTEGER,
            request_body_truncated  INTEGER NOT NULL DEFAULT 0,
            response_body_truncated INTEGER NOT NULL DEFAULT 0
          )
          SQL
        "CREATE INDEX idx_flows_created_at ON flows (created_at)",
        # The one projection filter with useful cardinality + range queries.
        "CREATE INDEX idx_flows_status ON flows (status)",
        # So the retention sweep's orphan-h2 cleanup doesn't full-scan flows.
        "CREATE INDEX idx_flows_h2_conn ON flows (h2_conn_id)",
        # `SELECT DISTINCT host, method, target ... ORDER BY host, target` is the Sitemap
        # tab's query (re-run on tab-enter AND the live poll). Without an index it
        # full-scans + sorts every flow — ~25ms at 100k rows. This covering index lets
        # SQLite walk it in order and emit distinct endpoints directly (~1.8ms at 100k).
        "CREATE INDEX idx_flows_sitemap ON flows (host, target, method)",
        # Covering index over the two byte-size columns so the Project tab's `total_size`
        # (SUM(request_size + COALESCE(response_size,0))) and `size:`/`reqsize:`/`respsize:`
        # range filters are answered from a compact index scan instead of a full-table scan.
        # The `flows` rows carry the multi-MB req/resp BLOBs inline, so a plain SUM scan
        # pages through the ENTIRE table (~170ms / 100k flows, measured); this narrow index
        # is a few MB and scans in ~2ms.
        "CREATE INDEX idx_flows_sizes ON flows (request_size, response_size)",

        # A compact full-text index over body text so `body:` doesn't CAST+scan every BLOB.
        # The FTS rowid is flows.id; the indexed text per side is capped (Store::FTS_INDEX_MAX)
        # so a big body can't bloat the index. host/path stay substring LIKE (unindexable) but
        # are bounded by retention.
        #
        # trigram tokenizer => case-insensitive SUBSTRING matching (like a body: LIKE), just
        # indexed. Query terms must be >=3 chars; below that QL scans the stored bytes with
        # the same literal REGEXP its index-free `body:` uses (see ql.cr's `body_cond`).
        #
        # CONTENTLESS (content='') because we already store the raw bodies in
        # flows.{request,response}_body — the default FTS5 shadow %_content copy would be pure
        # duplication (~half the FTS footprint, measured), and we only ever `MATCH` for rowids,
        # never read columns back. contentless_delete=1 (SQLite >= 3.43; ours is 3.51) keeps
        # prune's `DELETE ... WHERE rowid <= ?` and the response-side re-index working.
        # Contentless forbids UPDATE, so the writer does DELETE + re-INSERT (see update_one).
        "CREATE VIRTUAL TABLE flows_fts USING fts5(req, resp, content='', contentless_delete=1, tokenize='trigram')",

        # WebSocket message log. `repeater_id` is set for messages sent from a WS Repeater tab.
        <<-SQL,
          CREATE TABLE ws_messages (
            id          INTEGER PRIMARY KEY,
            flow_id     INTEGER NOT NULL,
            created_at  INTEGER NOT NULL,
            direction   TEXT    NOT NULL,
            opcode      INTEGER NOT NULL,
            payload     BLOB    NOT NULL,
            repeater_id INTEGER
          )
          SQL
        "CREATE INDEX idx_ws_messages_flow ON ws_messages (flow_id)",
        "CREATE INDEX idx_ws_messages_repeater ON ws_messages (repeater_id)",

        # HTTP/2: the raw frame log per connection (the truth, P7). DATA (type 0) payloads are
        # stored EMPTY — the same bytes already live in flows.request_body/response_body, and
        # the frame-log detail view only ever renders the `length` column (see
        # Store#insert_h2_frame_one).
        <<-SQL,
          CREATE TABLE h2_connections (
            id         INTEGER PRIMARY KEY,
            created_at INTEGER NOT NULL,
            host       TEXT    NOT NULL,
            port       INTEGER NOT NULL,
            alpn       TEXT    NOT NULL
          )
          SQL
        <<-SQL,
          CREATE TABLE h2_frames (
            id         INTEGER PRIMARY KEY,
            conn_id    INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            direction  TEXT    NOT NULL,
            stream_id  INTEGER NOT NULL,
            type       INTEGER NOT NULL,
            flags      INTEGER NOT NULL,
            length     INTEGER NOT NULL,
            payload    BLOB    NOT NULL
          )
          SQL
        "CREATE INDEX idx_h2_frames_conn ON h2_frames (conn_id)",
        # So the retention prune's orphan-connection reap (`SELECT conn_id FROM h2_frames
        # WHERE created_at >= ?`) is answered index-only instead of full-scanning the frame
        # log. That scan runs inside the writer's own transaction, so on an h2-heavy project
        # it would stall ALL capture writes each sweep. (created_at, conn_id) is covering.
        "CREATE INDEX idx_h2_frames_created ON h2_frames (created_at, conn_id)",

        # ── Project state ────────────────────────────────────────────────────────
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",

        # Scope: a real include/exclude lens with host-glob, substring & regex matching.
        # UNIQUE sits on the (kind, match_type, pattern) triple, so the same pattern can be
        # both an include and an exclude, or a host rule and a string rule.
        <<-SQL,
          CREATE TABLE scope_rules (
            id         INTEGER PRIMARY KEY,
            kind       TEXT NOT NULL DEFAULT 'include',
            match_type TEXT NOT NULL DEFAULT 'host',
            pattern    TEXT NOT NULL,
            UNIQUE(kind, match_type, pattern)
          )
          SQL

        # Issues: human-confirmed vuln records, with a triage STATUS axis (open / confirmed /
        # false-positive / resolved) separate from severity, so a false positive is a
        # reversible state instead of a delete. NOTE: distinct from probe_issues below
        # (machine-found scan results).
        <<-SQL,
          CREATE TABLE issues (
            id         INTEGER PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            title      TEXT    NOT NULL,
            severity   INTEGER NOT NULL,
            host       TEXT,
            flow_id    INTEGER,
            notes      TEXT    NOT NULL DEFAULT '',
            status     INTEGER NOT NULL DEFAULT 0
          )
          SQL
        "CREATE INDEX idx_issues_severity ON issues (severity)",

        # Cross-entity links: attach History/Repeater/Fuzzer/Miner refs to an Issue or Note.
        <<-SQL,
          CREATE TABLE entity_links (
            id         INTEGER PRIMARY KEY,
            owner_kind TEXT    NOT NULL,
            owner_id   INTEGER NOT NULL,
            ref_kind   TEXT    NOT NULL,
            ref_id     INTEGER NOT NULL,
            created_at INTEGER NOT NULL,
            UNIQUE(owner_kind, owner_id, ref_kind, ref_id)
          )
          SQL
        "CREATE INDEX idx_entity_links_owner ON entity_links (owner_kind, owner_id)",

        # Sitemap path tags: a free-text memo pinned to a (host, path) node in the Sitemap
        # tree ("payment flow", "admin area"). Per-project, so it syncs across sessions
        # sharing the DB (reconciled on the data_version poll like issues). UNIQUE(host, path)
        # makes the write an upsert; an empty tag deletes the row.
        <<-SQL,
          CREATE TABLE sitemap_tags (
            id   INTEGER PRIMARY KEY,
            host TEXT NOT NULL,
            path TEXT NOT NULL,
            tag  TEXT NOT NULL,
            UNIQUE(host, path)
          )
          SQL

        # Project-level hostname overrides (a per-project /etc/hosts): map a host to the IP the
        # proxy should DIAL for it, while SNI/cert/Host header keep the original host. `host` is
        # stored lowercased and UNIQUE (one IP per host — re-adding the same host is rejected;
        # edit the row to change its IP). Read on the proxy hot path (Upstream.dial) via the
        # Mutex-guarded HostOverrides model.
        <<-SQL,
          CREATE TABLE host_overrides (
            id   INTEGER PRIMARY KEY,
            host TEXT NOT NULL UNIQUE,
            ip   TEXT NOT NULL
          )
          SQL

        # ── Rewriter (Match & Replace) ───────────────────────────────────────────
        # A rule rewrites either the message HEAD (request/status line + headers) or its BODY
        # (buffer + re-frame in flight). Four further axes: an OPERATION (replace / add-header /
        # set-header / remove-header), a MATCH KIND (literal / regex, for replace), an optional
        # NAME, and an optional HOST glob ('' = all hosts) that scopes the rule.
        <<-SQL,
          CREATE TABLE match_rules (
            id          INTEGER PRIMARY KEY,
            enabled     INTEGER NOT NULL DEFAULT 1,
            target      TEXT    NOT NULL,
            pattern     TEXT    NOT NULL,
            replacement TEXT    NOT NULL DEFAULT '',
            position    INTEGER NOT NULL DEFAULT 0,
            part        TEXT    NOT NULL DEFAULT 'head',
            op          TEXT    NOT NULL DEFAULT 'replace',
            match_kind  TEXT    NOT NULL DEFAULT 'literal',
            name        TEXT    NOT NULL DEFAULT '',
            host        TEXT    NOT NULL DEFAULT ''
          )
          SQL

        # ── Workbenches ──────────────────────────────────────────────────────────
        # Repeater tabs, persisted so they survive a reopen AND sync across sessions sharing
        # the project (the TUI reconciles by `id` on the data_version poll). `flow_id` is the
        # source History flow for a `^R`-opened tab (NULL for a hand-authored `^N`). `name`
        # NULL = derive the sub-tab label from the request line. `sni` NULL = present the
        # target host; set it to decouple the TLS ClientHello name from the dialed host
        # (domain fronting / vhost confusion / IP-direct sends). `tags` is a space-joined set
        # of free-text labels for filtering the sub-tab strip; NULL = untagged. The response_*
        # columns persist the LAST send result (full bytes, like the captured-flow BLOBs) so
        # restore() can rebuild the Replay::Result faithfully — including an errored send.
        # All NULL until the first send. Scroll/focus/diff-baseline stay transient.
        <<-SQL,
          CREATE TABLE repeaters (
            id                   INTEGER PRIMARY KEY,
            created_at           INTEGER NOT NULL,
            updated_at           INTEGER NOT NULL,
            target               TEXT    NOT NULL,
            request              TEXT    NOT NULL,
            http2                INTEGER NOT NULL DEFAULT 0,
            auto_content_length  INTEGER NOT NULL DEFAULT 1,
            flow_id              INTEGER,
            position             INTEGER NOT NULL DEFAULT 0,
            response_head        BLOB,
            response_body        BLOB,
            response_error       TEXT,
            response_duration_us INTEGER,
            name                 TEXT,
            sni                  TEXT,
            tags                 TEXT
          )
          SQL
        "CREATE INDEX idx_repeaters_position ON repeaters (position, id)",

        # Fuzzer / Intruder persistence:
        #  - fuzz_sessions: a saved template + opaque config JSON (the TUI manages its shape),
        #    mirroring `repeaters` so a Fuzzer tab survives reopen and syncs across sessions.
        #  - fuzz_runs: one sweep's metadata (live counters + status), linked to a session.
        #  - fuzz_results: per-request rows (metrics + optional captured bytes). V1 had no
        #    production writer; V24 adds complete explicit run saves while ordinary fuzz runs
        #    remain ephemeral.
        <<-SQL,
          CREATE TABLE fuzz_sessions (
            id         INTEGER PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            target     TEXT    NOT NULL,
            template   TEXT    NOT NULL,
            http2      INTEGER NOT NULL DEFAULT 0,
            sni        TEXT,
            config     TEXT    NOT NULL DEFAULT '',
            flow_id    INTEGER,
            position   INTEGER NOT NULL DEFAULT 0,
            name       TEXT
          )
          SQL
        "CREATE INDEX idx_fuzz_sessions_position ON fuzz_sessions (position, id)",
        <<-SQL,
          CREATE TABLE fuzz_runs (
            id          INTEGER PRIMARY KEY,
            session_id  INTEGER,
            created_at  INTEGER NOT NULL,
            finished_at INTEGER,
            target      TEXT    NOT NULL,
            mode        TEXT    NOT NULL,
            total       INTEGER,
            sent        INTEGER NOT NULL DEFAULT 0,
            matched     INTEGER NOT NULL DEFAULT 0,
            errors      INTEGER NOT NULL DEFAULT 0,
            status      TEXT    NOT NULL DEFAULT 'running'
          )
          SQL
        "CREATE INDEX idx_fuzz_runs_session ON fuzz_runs (session_id, id)",
        <<-SQL,
          CREATE TABLE fuzz_results (
            id            INTEGER PRIMARY KEY,
            run_id        INTEGER NOT NULL,
            idx           INTEGER NOT NULL,
            payloads      TEXT    NOT NULL,
            status        INTEGER,
            length        INTEGER NOT NULL DEFAULT 0,
            words         INTEGER NOT NULL DEFAULT 0,
            lines         INTEGER NOT NULL DEFAULT 0,
            duration_us   INTEGER NOT NULL DEFAULT 0,
            error         TEXT,
            matched       INTEGER NOT NULL DEFAULT 0,
            extracted     TEXT,
            request       BLOB,
            response_head BLOB,
            response_body BLOB
          )
          SQL
        "CREATE INDEX idx_fuzz_results_run ON fuzz_results (run_id, idx)",

        # Param-miner sessions. Mirrors fuzz_sessions, but stores the byte-exact `request`
        # (BLOB) to re-run rather than an editable template, and there is no runs/results
        # table — mining results stay in-memory per session. `config` is opaque JSON managed
        # by the frontend (locations, bucket sizes, concurrency, …).
        <<-SQL,
          CREATE TABLE miner_sessions (
            id         INTEGER PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            target     TEXT    NOT NULL,
            request    BLOB    NOT NULL,
            http2      INTEGER NOT NULL DEFAULT 0,
            sni        TEXT,
            config     TEXT    NOT NULL DEFAULT '',
            flow_id    INTEGER,
            position   INTEGER NOT NULL DEFAULT 0,
            name       TEXT
          )
          SQL
        "CREATE INDEX idx_miner_sessions_position ON miner_sessions (position, id)",

        # Sequencer sessions: token-randomness collection. Structurally identical to
        # miner_sessions. Collected tokens are live secrets, so like the miner there is NO
        # results table: samples and the computed report stay in-memory and never hit disk.
        <<-SQL,
          CREATE TABLE sequencer_sessions (
            id         INTEGER PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            target     TEXT    NOT NULL,
            request    BLOB    NOT NULL,
            http2      INTEGER NOT NULL DEFAULT 0,
            sni        TEXT,
            config     TEXT    NOT NULL DEFAULT '',
            flow_id    INTEGER,
            position   INTEGER NOT NULL DEFAULT 0,
            name       TEXT
          )
          SQL
        "CREATE INDEX idx_sequencer_sessions_position ON sequencer_sessions (position, id)",

        # ── Probe (passive/active scanner) ───────────────────────────────────────
        # Issues GROUPED by (code, host): one row per distinct issue type per host, with the
        # affected URLs accumulated in `affected` (JSON, capped) and `hit_count` counting every
        # observation. `category` is the lens used by both the Probe filter and the
        # project-level technology summary (category='tech'). sample_repeater_id is the
        # first-seen Repeater evidence link when there is no parent flow (or as a secondary).
        # The Probe MODE itself lives in the generic `settings` table (key "probe_mode").
        <<-SQL,
          CREATE TABLE probe_issues (
            id                 INTEGER PRIMARY KEY,
            code               TEXT    NOT NULL,
            category           TEXT    NOT NULL,
            host               TEXT    NOT NULL,
            title              TEXT    NOT NULL,
            severity           INTEGER NOT NULL,
            status             INTEGER NOT NULL DEFAULT 0,
            hit_count          INTEGER NOT NULL DEFAULT 1,
            affected           TEXT    NOT NULL DEFAULT '[]',
            sample_flow_id     INTEGER,
            sample_repeater_id INTEGER,
            evidence           TEXT,
            first_seen         INTEGER NOT NULL,
            last_seen          INTEGER NOT NULL,
            UNIQUE(code, host)
          )
          SQL
        "CREATE INDEX idx_probe_issues_cat ON probe_issues (category, host)",

        # Hard-deleted Probe issues must stay gone across Project leave/re-open: without a
        # durable record, Active backfill on the next Session re-probes History and re-inserts
        # the same (code, host). Checked by Store#upsert_probe_issue and reloaded into the
        # analyzer on start. Clear-all removes both issues and suppressions so a full rescan
        # is still possible.
        <<-SQL,
          CREATE TABLE probe_suppressions (
            code       TEXT    NOT NULL,
            host       TEXT    NOT NULL,
            created_at INTEGER NOT NULL,
            PRIMARY KEY (code, host)
          )
          SQL

        # Per-project user-defined Probe match rules (the Rules sub-tab's project-scope custom
        # rules). Global-scope rules live in settings.json instead. `severity` is the lowercase
        # Store::Severity label; side/region/kind are validated in the store layer before insert.
        <<-SQL,
          CREATE TABLE probe_custom_rules (
            id          INTEGER PRIMARY KEY,
            title       TEXT    NOT NULL,
            description TEXT    NOT NULL DEFAULT '',
            side        TEXT    NOT NULL,
            region      TEXT    NOT NULL,
            kind        TEXT    NOT NULL,
            pattern     TEXT    NOT NULL,
            severity    TEXT    NOT NULL,
            enabled     INTEGER NOT NULL DEFAULT 1
          )
          SQL

        # ── AI seam (MCP) ────────────────────────────────────────────────────────
        # The AI-facing event feed: an append-only log of job lifecycle (miner/fuzzer/probe)
        # and agent actions that the MCP process tails via a forward `id > cursor` cursor
        # (list_events). Flows stay the flow firehose (list_history since:) — this table NEVER
        # duplicates flow rows; `flow_id` is only an optional cross-ref. AUTOINCREMENT is
        # mandatory (not a bare rowid): a never-reused id guarantees a since_id watermark
        # consumer can't silently skip a row even if a future retention sweep deletes rows.
        # created_at is unix micros for display only — the cursor key is always `id`.
        <<-SQL,
          CREATE TABLE events (
            id              INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at      INTEGER NOT NULL,
            source          TEXT    NOT NULL,
            kind            TEXT    NOT NULL,
            level           TEXT    NOT NULL,
            message         TEXT    NOT NULL,
            goto_tab        TEXT,
            goto_session_id INTEGER,
            flow_id         INTEGER,
            payload         TEXT
          )
          SQL

        # The cross-process live-intercept bridge. The MCP process (Store only, no live
        # Interceptor) drives hold/forward/drop/edit through the DB: the capturing TUI
        # publishes a MIRROR of the currently-held queue into intercept_held, and the MCP
        # process appends decisions to the intercept_commands queue which the TUI drains +
        # applies. intercept_held is keyed by (session_token, item_id) — a snapshot mirror,
        # NOT a cursor log, so the id-reuse hazard doesn't apply. intercept_commands IS a
        # forward-cursored queue, so its id MUST be AUTOINCREMENT (a recycled rowid would let
        # the TUI's drain watermark silently skip a row). session_token defeats cross-session
        # reuse of the interceptor's per-session item ids.
        <<-SQL,
          CREATE TABLE intercept_held (
            session_token TEXT    NOT NULL,
            item_id       INTEGER NOT NULL,
            kind          TEXT    NOT NULL,
            method        TEXT    NOT NULL,
            host          TEXT    NOT NULL,
            port          INTEGER NOT NULL,
            scheme        TEXT    NOT NULL,
            target        TEXT    NOT NULL,
            flow_id       INTEGER,
            raw           BLOB    NOT NULL,
            held_at_ms    INTEGER NOT NULL,
            edited        INTEGER NOT NULL DEFAULT 0,
            viewed_ms     INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (session_token, item_id)
          )
          SQL
        <<-SQL,
          CREATE TABLE intercept_commands (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at    INTEGER NOT NULL,
            session_token TEXT,
            verb          TEXT    NOT NULL,
            item_id       INTEGER,
            bytes         BLOB,
            arg           TEXT,
            status        TEXT    NOT NULL DEFAULT 'pending',
            applied_at    INTEGER,
            result        TEXT,
            origin        TEXT
          )
          SQL

        # ── OAST (out-of-band) ───────────────────────────────────────────────────
        # Configured providers, listening sessions, and the durable callback history.
        # Providers are config (name/kind/host/token). Sessions hold the secrets needed to
        # poll + decrypt (the interactsh RSA private key PEM lives here — the DB is already
        # 0600 and holds captured credentials; never logged). Callbacks are
        # append-only/immutable; UNIQUE(session_id, provider_uid) + INSERT OR IGNORE dedups.
        <<-SQL,
          CREATE TABLE oast_providers (
            id         INTEGER PRIMARY KEY,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            name       TEXT    NOT NULL,
            kind       TEXT    NOT NULL,
            host       TEXT    NOT NULL,
            token      TEXT,
            enabled    INTEGER NOT NULL DEFAULT 1,
            position   INTEGER NOT NULL DEFAULT 0
          )
          SQL
        <<-SQL,
          CREATE TABLE oast_sessions (
            id              INTEGER PRIMARY KEY,
            created_at      INTEGER NOT NULL,
            provider_id     INTEGER,
            kind            TEXT    NOT NULL,
            server_url      TEXT    NOT NULL,
            correlation_id  TEXT    NOT NULL,
            secret          TEXT    NOT NULL DEFAULT '',
            private_key_pem TEXT,
            token           TEXT,
            last_poll_at    INTEGER
          )
          SQL
        <<-SQL,
          CREATE TABLE oast_callbacks (
            id           INTEGER PRIMARY KEY,
            session_id   INTEGER NOT NULL,
            created_at   INTEGER NOT NULL,
            provider_uid TEXT    NOT NULL,
            protocol     TEXT    NOT NULL,
            method       TEXT,
            source_ip    TEXT,
            full_id      TEXT    NOT NULL,
            raw_request  BLOB    NOT NULL,
            raw_response BLOB,
            UNIQUE(session_id, provider_uid)
          )
          SQL
        "CREATE INDEX idx_oast_callbacks_session ON oast_callbacks (session_id, id)",
      ]

      # V2: `repeaters.request` was always written as a bound Crystal String — SQLite
      # stores the exact bytes (sqlite3_bind_text takes an explicit byte count, not a
      # NUL-terminated length), so no data was ever lost on write. But the crystal-sqlite3
      # driver reads a TEXT-storage-class column via sqlite3_column_text + a single-arg
      # `String.new(ptr)`, which stops at the first embedded NUL — so any repeater request
      # containing a raw 0x00 byte (a binary body, or a hex-edited byte) silently truncated
      # on every read after the one write, corrupting/emptying the request in Repeater.
      #
      # `CAST(x AS BLOB)` reinterprets a TEXT value's existing bytes as-is (no reparse, no
      # NUL truncation — verified against the actual crystal-sqlite3 driver: a 31-byte value
      # with two embedded NULs round-trips byte-for-byte after this UPDATE, vs. truncating to
      # 5 bytes before it). This is a data-only migration — no column type change, since
      # SQLite's TEXT affinity never coerces a BLOB-storage-class value back to TEXT, so the
      # fix holds permanently once `insert_repeater`/`update_repeater` bind `Bytes` instead
      # of `String` (see Store#insert_repeater). Recovers EXISTING users' truncation-prone
      # rows losslessly; a no-op for rows that never contained a NUL.
      V2 = [
        "UPDATE repeaters SET request = CAST(request AS BLOB)",
      ]

      # `unsent` marks a flow row that will NEVER receive a response because it was never sent —
      # an `import --urls`/`--oas` reference placeholder (Import::Builder.pending_request stores
      # it Pending with a nil response ON PURPOSE). abandon_pending! finalises Pending rows to
      # Error on session start/stop ("nothing else will ever resolve them"), which was FALSE for
      # these — a capture (or just opening the project) corrupted every imported reference into a
      # fabricated network error (#408). The gate excludes `unsent = 1`. Existing rows default to
      # 0: only new imports are marked, so this prevents future corruption without guessing which
      # already-stored Pending rows were imports.
      V3 = [
        "ALTER TABLE flows ADD COLUMN unsent INTEGER NOT NULL DEFAULT 0",
      ]

      # `fts_dirty` marks a flow whose `flows_fts` entry is missing or stale, so trigram
      # tokenization can move OFF the capture commit (see Store#index_pending_batch). It was
      # the dominant capture cost: ~30µs per indexed KiB inside the writer's transaction, which
      # is where a 64 KiB text response cost ~2ms and collapsed end-to-end capture of text/html
      # to a few hundred req/s — while the proxy + HTTP/1.1 codec add only ~25µs per request.
      #
      # Durability is the reason this is a COLUMN and not an in-memory queue: a killed process
      # (or a batch dropped under saturation) would otherwise leave those flows permanently
      # unsearchable with nothing to detect it. The flag persists, so the next open — or the
      # next idle moment — finishes the job, and `Store#fts_backlog` can SAY how far behind
      # search is instead of silently under-reporting a `body:` query.
      #
      # Existing rows default to 0 (= index current): every already-stored flow WAS indexed by
      # the old synchronous path, so defaulting to 0 avoids re-indexing whole histories on
      # upgrade. Only rows written from here on are marked dirty. The partial index keeps the
      # backlog probe O(backlog) rather than O(table) — it holds nothing at all once drained.
      V4 = [
        "ALTER TABLE flows ADD COLUMN fts_dirty INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX idx_flows_fts_dirty ON flows (id) WHERE fts_dirty = 1",
      ]

      # The short-circuit rule op (#511): a Match&Replace rule that ANSWERS a request instead
      # of rewriting one, so `Upstream.dial` is never reached.
      #
      # `match_rules.body_file` is the second body source. The stub's status line and headers
      # live in the existing `replacement` (a raw response head), but an inline body cannot
      # carry a large or binary stub — a PNG, a multi-MiB JSON — without pasting it into the
      # rule row. A path keeps those on disk and editable outside gori; empty (the default,
      # and every pre-#511 row) means the inline body is the source, so no existing rule
      # changes meaning.
      #
      # `flows.short_circuited` marks a flow gori ANSWERED ITSELF. It has to be stored rather
      # than derived: nothing in the recorded bytes distinguishes a stub from a real response
      # — that is the point of a stub — so after a restart History would present a fabricated
      # 200 as a finding about the origin. It is a separate column, not a `FlowState` member,
      # because state is a lifecycle position (a short-circuited flow is still `Complete` on
      # that axis) and not an attribute. Existing rows default to 0: gori could not
      # short-circuit before this migration, so 0 is the truth for every one of them.
      V5 = [
        "ALTER TABLE match_rules ADD COLUMN body_file TEXT NOT NULL DEFAULT ''",
        "ALTER TABLE flows ADD COLUMN short_circuited INTEGER NOT NULL DEFAULT 0",
      ]

      # Session bindings (#501), the READ half. An extract rule observes a response and
      # writes one named value into an IN-MEMORY table; the write half is an ordinary
      # `match_rules` row whose `replacement` says `$NAME`, which is why this migration adds
      # no column there and no second ordered list.
      #
      # `name` is UNIQUE and that is load-bearing, not hygiene: a binding is keyed by NAME
      # ALONE (the host constraint lives on the rule), so two rules writing `$SESSION` would
      # force every reader to answer "which one?" — the question the design refuses to
      # create. `Bindings#validate` refuses it first with a message; this is the backstop.
      #
      # No `position` column: extraction transforms nothing, so extract rules cannot compose
      # and have no meaningful order. No column for the VALUE either — see `ExtractRule`.
      V6 = [
        <<-SQL,
          CREATE TABLE extract_rules (
            id           INTEGER PRIMARY KEY,
            enabled      INTEGER NOT NULL DEFAULT 1,
            name         TEXT    NOT NULL UNIQUE,
            match_filter TEXT    NOT NULL DEFAULT '',
            kind         TEXT    NOT NULL,
            selector     TEXT    NOT NULL DEFAULT '',
            pos_start    INTEGER NOT NULL DEFAULT 0,
            pos_end      INTEGER NOT NULL DEFAULT 0,
            host         TEXT    NOT NULL DEFAULT ''
          )
          SQL
      ]

      # WebSocket frame SHAPE, on both halves of `ws_messages` — the capture rows and the
      # repeater-session rows that share the table.
      #
      # `ws_messages(direction, opcode, payload)` recorded a message's bytes and nothing about
      # the frames that carried them, and the relay never called the sink for a control frame
      # at all. Between them that lost the two most diagnostic facts a WebSocket test produces:
      # the CLOSE code and reason (why did the socket go away — the repeater engine reports
      # `close_code`, so the two surfaces disagreed about the same protocol), and the RSV bits
      # (a `permessage-deflate` frame and a plain one were the same row). Fragmentation was
      # invisible too: `TEXT fin=0 "frag1|"` + `CONT fin=1 "frag2"` is one row that looks
      # exactly like one frame carrying "frag1|frag2".
      #
      # Column by column, and what each says on a row that came off the wire:
      #   * `fin` — the LAST frame's FIN. 0 means the message never got one (a §5.4 violation,
      #     or a teardown mid-fragment). Every message gori has ever captured complete is 1,
      #     hence the default.
      #   * `rsv` — the FIRST frame's RSV1..3 nibble (§5.2 puts an extension's flags there).
      #   * `masked`/`mask_key` — the first frame's. NULLABLE on purpose: a pre-V7 row does
      #     not know, and that is a different statement from "the wire said unmasked". This is
      #     what makes an UNMASKED client frame (§5.1 violation) visible at all.
      #   * `frames` — how many frames the message spanned. The only way to tell a reassembly
      #     from the single frame it otherwise reads as.
      #   * `declared_len` — the one field that is SEND-only. A frame whose length header
      #     disagrees with its payload cannot be read back off a wire (the reader believes the
      #     header), so it can only be authored, and therefore has to be stored rather than
      #     derived from `LENGTH(payload)`.
      #
      # Existing rows default to `fin=1, rsv=0, frames=1` and NULL for the rest, which is
      # exactly what gori assumed about them before — so no stored message changes meaning and
      # no replay changes bytes.
      #
      # `repeaters.ws_keep_key` is the `Sec-WebSocket-Key` opt-in. `WsEngine.build_handshake`
      # drops the operator's key line and appends a fresh one, deliberately (a fresh key
      # avoids a server's repeater guard) — but that also means an absent, short, duplicated
      # or non-base64 key cannot be sent, and those are the handshake tests. Off by default:
      # regeneration stays the behaviour for every session that does not ask.
      V7 = [
        "ALTER TABLE ws_messages ADD COLUMN fin INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE ws_messages ADD COLUMN rsv INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE ws_messages ADD COLUMN masked INTEGER",
        "ALTER TABLE ws_messages ADD COLUMN mask_key BLOB",
        "ALTER TABLE ws_messages ADD COLUMN frames INTEGER NOT NULL DEFAULT 1",
        "ALTER TABLE ws_messages ADD COLUMN declared_len INTEGER",
        "ALTER TABLE repeaters ADD COLUMN ws_keep_key INTEGER NOT NULL DEFAULT 0",
      ]

      # Two facts gori knew and could not SAY as data.
      #
      # `flows.advisory` — see `Store::FlowRow#advisory` for what it is and why it is a
      # column rather than a rows table. It gives an HTTP flow what a WebSocket flow has had
      # since #518 (the `[gori] …` rows `WS::Relay` writes into `ws_messages`): somewhere to
      # record what gori did to a message that the message's own bytes cannot show. Its two
      # first tenants both used to escape as a log line or a fabricated header — a
      # Match&Replace head rule that structurally could not run on an h2 message with no
      # HTTP/1.1 text form (a WARN on `gori run capture`'s STDERR, correlated with no flow),
      # and a server PUSH_PROMISE (a synthesized `X-Gori-Pushed` line readable only by
      # someone already looking at the head text). NULL on every existing row, which is the
      # truth for them: gori recorded no advisory before this migration.
      #
      # `intercept_held.edit_refusal` / `.head_only` mirror the two facts
      # `Interceptor::Item` has carried since #517/R3-F1 across the #123 bridge, so the MCP
      # process and `gori run intercept get`/`list` can say "edits cannot be applied to this
      # message: …" BEFORE the operator writes one. `intercept_held` is a per-session
      # snapshot mirror that `clear_intercept_state!` wipes, so nothing has to be
      # back-filled — but it is a released table, so the columns still arrive as a
      # migration. `head_only` defaults 0: an h1 hold covers head+body, and every row a
      # pre-V8 gori wrote came from a build whose h2 gate had not been written yet.
      V8 = [
        "ALTER TABLE flows ADD COLUMN advisory TEXT",
        "ALTER TABLE intercept_held ADD COLUMN edit_refusal TEXT",
        "ALTER TABLE intercept_held ADD COLUMN head_only INTEGER NOT NULL DEFAULT 0",
      ]

      # `intercept_held.binary` mirrors `Interceptor::Item#binary?` (opcode == OP_BIN) across
      # the #123 bridge — a fact known at hold time that neither `intercept_edit_bytes` (MCP)
      # nor `cmd_intercept_edit` (CLI) could see before this column existed, so a WebSocket
      # BINARY frame edited through the TEXT `raw` channel (a JSON string / an argv string,
      # both of which force-reencode any byte above 0x7F) was silently rewritten rather than
      # refused — while the TUI, on the same `binary?`, routes the operator to a byte channel
      # (its hex editor) instead. Same 0-default rationale as `head_only`: a per-session
      # snapshot mirror that `clear_intercept_state!` wipes at the next capture start, so no
      # existing row needs a real answer back-filled.
      V9 = [
        "ALTER TABLE intercept_held ADD COLUMN binary INTEGER NOT NULL DEFAULT 0",
      ]

      # Make rowid reuse impossible on the two tables an `entity_links` row can point at, so
      # a stranded link can never re-point at material nobody attached.
      #
      # `entity_links.ref_id` is a plain integer selected by `ref_kind` — the ref is
      # polymorphic, so no foreign key can express it and no `ON DELETE CASCADE` is available.
      # Until #574 neither `delete_fuzz_session` nor `delete_miner_session` deleted the link
      # rows, and both tables are `INTEGER PRIMARY KEY` WITHOUT AUTOINCREMENT — so SQLite
      # reassigns `max(rowid)+1`, while closing a sub-tab (^W) deletes at the TOP of the id
      # space. The next `^N` was handed the id that had just gone, and a surviving link
      # silently re-bound (`stale: false`) to a session against a DIFFERENT target: an issue's
      # evidence confidently naming traffic the operator never linked. #574 closed the delete
      # path; this closes the property that made a stranded link DANGEROUS rather than merely
      # dead, and it is the half that reaches databases already carrying strays.
      #
      # Deliberately NOT a sweep of those strays. Deleting them is irreversible and discards a
      # fact the operator put there, and it is unnecessary: `Links.resolve_fuzz` already
      # renders an absent row as `fuzz #N (gone)` with `stale: true` (pinned by
      # spec/links_spec.cr), which is strictly more informative than no row at all. Seeding
      # `sqlite_sequence` past the highest id ANY surviving link references makes every stray
      # permanently safe instead of permanently deleted — including the case that defeats
      # AUTOINCREMENT on its own, where the table is EMPTY at migration time so the copy
      # creates no `sqlite_sequence` row and ids would otherwise restart at 1 under a stray
      # pointing at 1.
      #
      # Two ordering facts this depends on, both verified rather than assumed: the seed reads
      # the live table by its FINAL name, so it must run AFTER the rename; and a
      # `sqlite_sequence` row FOLLOWS `ALTER TABLE … RENAME TO`, so the DELETE below targets
      # the row the copy just created and cannot leave a stale duplicate under the old name.
      #
      # Columns are enumerated rather than `SELECT *` — leaning on column order is how a
      # rebuild migration silently corrupts data. The shapes are V1's, still current (no
      # V2..V9 statement touches these tables). A fresh database runs V1's plain-PK CREATE and
      # then rebuilds it here in the same transaction: microseconds on an empty table, and it
      # keeps every database, new or migrated, on exactly one definition.
      #
      # `sequencer_sessions` is NOT rebuilt here: no link can name one (`LinkRefKind.parse`
      # accepts only flow|repeater|fuzz|miner). That undercounted its holders — a peer TUI's tab
      # and an Activity row keep a session id too — and V41 moves it.
      # `flows` is not swept either, and must not be: the prune paths delete from the BOTTOM
      # (`id <= cutoff`), so `MAX(id)` survives and a pruned flow's id never returns — its
      # links are already safely `(gone)`.
      V10 = [
        <<-SQL,
          CREATE TABLE fuzz_sessions_v10 (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            target     TEXT    NOT NULL,
            template   TEXT    NOT NULL,
            http2      INTEGER NOT NULL DEFAULT 0,
            sni        TEXT,
            config     TEXT    NOT NULL DEFAULT '',
            flow_id    INTEGER,
            position   INTEGER NOT NULL DEFAULT 0,
            name       TEXT
          )
          SQL
        <<-SQL,
          INSERT INTO fuzz_sessions_v10
            (id, created_at, updated_at, target, template, http2, sni, config, flow_id, position, name)
            SELECT id, created_at, updated_at, target, template, http2, sni, config, flow_id, position, name
            FROM fuzz_sessions
          SQL
        "DROP TABLE fuzz_sessions",
        "ALTER TABLE fuzz_sessions_v10 RENAME TO fuzz_sessions",
        "CREATE INDEX idx_fuzz_sessions_position ON fuzz_sessions (position, id)",
        "DELETE FROM sqlite_sequence WHERE name = 'fuzz_sessions'",
        <<-SQL,
          INSERT INTO sqlite_sequence (name, seq)
            SELECT 'fuzz_sessions', COALESCE(MAX(v), 0) FROM (
              SELECT MAX(id) AS v FROM fuzz_sessions
              UNION ALL
              SELECT MAX(ref_id) FROM entity_links WHERE ref_kind = 'fuzz'
            )
          SQL

        <<-SQL,
          CREATE TABLE miner_sessions_v10 (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            target     TEXT    NOT NULL,
            request    BLOB    NOT NULL,
            http2      INTEGER NOT NULL DEFAULT 0,
            sni        TEXT,
            config     TEXT    NOT NULL DEFAULT '',
            flow_id    INTEGER,
            position   INTEGER NOT NULL DEFAULT 0,
            name       TEXT
          )
          SQL
        <<-SQL,
          INSERT INTO miner_sessions_v10
            (id, created_at, updated_at, target, request, http2, sni, config, flow_id, position, name)
            SELECT id, created_at, updated_at, target, request, http2, sni, config, flow_id, position, name
            FROM miner_sessions
          SQL
        "DROP TABLE miner_sessions",
        "ALTER TABLE miner_sessions_v10 RENAME TO miner_sessions",
        "CREATE INDEX idx_miner_sessions_position ON miner_sessions (position, id)",
        "DELETE FROM sqlite_sequence WHERE name = 'miner_sessions'",
        <<-SQL,
          INSERT INTO sqlite_sequence (name, seq)
            SELECT 'miner_sessions', COALESCE(MAX(v), 0) FROM (
              SELECT MAX(id) AS v FROM miner_sessions
              UNION ALL
              SELECT MAX(ref_id) FROM entity_links WHERE ref_kind = 'miner'
            )
          SQL
      ]

      # `repeaters.ws_http_only` is the operator's override of gori's WebSocket AUTO-DETECTION.
      #
      # Whether a Repeater tab is a WebSocket tab has never been stored: it is re-derived from
      # the request bytes on every load (`WsEngine.replayable?` — an `Upgrade:` header, or the
      # `CONNECT` + `X-Gori-Protocol: websocket` pair of an RFC 8441 handshake),
      # and that verdict decides the engine `^R` dials, the split request pane, the transcript
      # response, and — the part that is easy to miss — whether diff, pretty-print, hex edit,
      # minimize, group send, Match&Replace and the h1/h2 toggle are available at all. They are
      # all gated on the same flag, so a WS endpoint could only ever be tested as a WebSocket.
      #
      # A handshake is also an ordinary HTTP request, and "does this endpoint 101 for an
      # unauthenticated Origin?" is an HTTP question. This column says the operator answered it:
      # dial the h1/h2 engine, read the response as a response, stop there. It does NOT touch
      # the bytes — the `Upgrade:` header stays exactly as authored — and it does not discard
      # the tab's frames: `ws_messages` rows are still persisted, so `^V` back to WebSocket
      # replays the same session.
      #
      # 0 on every existing row, which is what they have always done: auto-detect.
      V11 = [
        "ALTER TABLE repeaters ADD COLUMN ws_http_only INTEGER NOT NULL DEFAULT 0",
      ]

      # `probe_oast_probes` is the ONE piece of probe state that outlives the scan that created
      # it. Every other active rule is a synchronous function of a response gori read on the same
      # socket it wrote; an OAST rule cannot be, because the evidence — a DNS/HTTP callback the
      # TARGET makes to a third-party interaction server — arrives seconds to hours later, over a
      # channel gori is not part of, quite possibly in a different process run.
      #
      # So the probe is split in two and this table is the seam: at plan time a rule mints a
      # payload from a registered `oast_sessions` row (`Provider#generate_payload` is LOCAL by
      # invariant, so this costs no network) and records the finding it WOULD emit; later, when a
      # callback carrying that payload's unique `token` lands in `oast_callbacks`, the sweep
      # promotes the row to a real probe issue. Nothing is emitted on the send alone — a payload
      # going out is not a finding, and a table of un-promoted rows is exactly the "we asked, and
      # nothing answered" state.
      #
      # `token` is UNIQUE and is the substring the provider echoes back in `full_id` /
      # `raw_request` (the interactsh 13-char label, the custom-http `oid`, …), so matching is a
      # containment test against callbacks rather than a join on provider-specific identifiers.
      # `matched_at` is the promotion stamp AND the pending filter — the partial index keeps the
      # sweep O(outstanding probes), which is a handful, not O(table).
      #
      # Rows are kept after promotion: the token in a callback is the only thing tying that
      # interaction to the parameter that caused it, and deleting the row would leave the issue
      # unable to say which probe drew it.
      V12 = [
        <<-SQL,
          CREATE TABLE probe_oast_probes (
            id         INTEGER PRIMARY KEY,
            created_at INTEGER NOT NULL,
            token      TEXT    NOT NULL,
            payload    TEXT    NOT NULL,
            session_id INTEGER NOT NULL,
            rule_id    TEXT    NOT NULL,
            code       TEXT    NOT NULL,
            category   TEXT    NOT NULL,
            title      TEXT    NOT NULL,
            severity   INTEGER NOT NULL,
            host       TEXT    NOT NULL,
            url        TEXT    NOT NULL,
            evidence   TEXT,
            flow_id    INTEGER,
            matched_at INTEGER,
            UNIQUE(token)
          )
          SQL
        "CREATE INDEX idx_probe_oast_pending ON probe_oast_probes (id) WHERE matched_at IS NULL",
      ]

      # Colormarker (display only): assign a COLOUR to the History rows whose flow matches a
      # condition. Nothing here reaches the proxy — a rule paints a row that has already been
      # captured, so unlike `match_rules` a malformed or over-broad rule costs an operator a
      # misleading list, never a modified message.
      #
      # `match_filter` is an `InterceptFilter` source string — the SAME grammar `extract_rules`
      # uses and the conditional-intercept bar speaks, evaluated here against a `FlowRow` in
      # memory. NOT a new dialect, and not QL: QL compiles to SQL against the flows table, and
      # there is no query to run when the row is already in hand on the render path.
      #
      # No `host` column, unlike match_rules and extract_rules: `host:` inside the filter is
      # the same statement, and a second host axis would make "which one wins" a question with
      # no good answer. The cost — the filter's `host:` is a plain substring rather than the
      # DNS-label-boundary glob `Rules.host_matches?` implements — is stated at every surface.
      #
      # `position` is load-bearing here in a way it is not in match_rules: rewrite rules
      # COMPOSE (all of them run, in order), colour rules RESOLVE (the first enabled match wins
      # and the rest are never consulted). Order is therefore the operator's precedence
      # statement, which is why reordering exists on the TUI, the CLI and MCP alike.
      #
      # No UNIQUE anywhere: two rules may legitimately share a condition (a triage rule being
      # promoted from yellow to red sits above the one it supersedes), and refusing that would
      # refuse the workflow the feature exists for.
      V13 = [
        <<-SQL,
          CREATE TABLE color_rules (
            id           INTEGER PRIMARY KEY,
            enabled      INTEGER NOT NULL DEFAULT 1,
            name         TEXT    NOT NULL DEFAULT '',
            match_filter TEXT    NOT NULL DEFAULT '',
            color        TEXT    NOT NULL DEFAULT 'yellow',
            style        TEXT    NOT NULL DEFAULT 'full',
            position     INTEGER NOT NULL DEFAULT 0
          )
          SQL
      ]

      # The REQUEST's declared Content-Type, beside the response's (`content_type`).
      #
      # `Gori::Proto` classifies a flow's application protocol with no column of its own — it
      # reads WS off the 101 status and gRPC/SSE off the content type — and the only content
      # type on the row was the RESPONSE's. So a gRPC call classified as gRPC exactly when it
      # SUCCEEDED: a still-Pending one, an aborted one, and one answered with a proxy's
      # `text/html` 502 all read as plain HTTP in the PROTO column and were missed by
      # `proto:grpc`. Those are the calls an operator is looking for.
      #
      # A column and not a re-parse of `request_head` at read time, because `QL.proto_cond`
      # compiles `proto:` to SQL against this table: a label derived from bytes the query
      # cannot see is precisely the drift `Proto` exists to prevent, and a `LIKE` over the head
      # BLOB would be both unindexable and the substring-matching this classification was fixed
      # to stop doing.
      #
      # Rows written before this migration keep NULL, and NULL means "not recorded" — not
      # "none". They classify exactly as they did before. gori does NOT backfill by guessing
      # at the stored heads: this column holds what the request DECLARED, and writing a value
      # into it that no capture produced would put uncaptured data in the store. Every DECODE
      # surface reads the head directly and is unaffected either way; what a pre-V14 row
      # cannot have is the PROTO label and the `proto:` filter for a failed gRPC call.
      V14 = [
        "ALTER TABLE flows ADD COLUMN request_content_type TEXT",
      ]

      # Both triage lists are read WHOLE and sorted by the same shape, and neither sort had an
      # index: `Store#probe_issues` is `ORDER BY severity DESC, last_seen DESC` and
      # `Store#issues` is `ORDER BY severity DESC, created_at DESC`, so SQLite sorted the
      # entire table every time. `probe_issues` is the one that grows without bound — its rows
      # are (code × host), so a crawl across thousands of hosts reaches hundreds of thousands
      # — and the Probe tab re-runs that query on every `probe_generation` bump, which during
      # an active scan is essentially every tick.
      #
      # Index only; the queries are unchanged. Capping them with LIMIT is a VISIBLE change (a
      # security tool that drops findings has to say so, on three surfaces) and belongs in its
      # own commit.
      V15 = [
        "CREATE INDEX IF NOT EXISTS idx_probe_issues_triage ON probe_issues (severity DESC, last_seen DESC)",
        "CREATE INDEX IF NOT EXISTS idx_issues_triage ON issues (severity DESC, created_at DESC)",
      ]

      # The RFC 8441 extended CONNECT's `:protocol` pseudo-header, verbatim — the one fact that
      # makes a WebSocket over HTTP/2 a WebSocket.
      #
      # Same shape of bug V14 fixed, one transport over. An h2 socket's handshake is `CONNECT`
      # answered `200` (RFC 8441 §5.1 replaces the h1 upgrade and there is no 101 anywhere in
      # it), and `Gori::Proto` read WS off `status == 101` — so a flow with a full WebSocket
      # transcript behind it showed `HTTPS` in the History PROTO column and `proto:ws`, the
      # filter an operator reaches for to find sockets, silently omitted every h2 one.
      #
      # A column and not a re-parse of `request_head` at read time, for V14's reason verbatim:
      # `QL.proto_cond` compiles `proto:` to SQL against this table, so a label derived from
      # bytes the query cannot see is precisely the drift `Proto` exists to prevent, and a
      # `LIKE` over the head BLOB would be both unindexable and the substring-matching this
      # classification was fixed to stop doing. Nor is it derived from the transcript ("has
      # `ws_messages` rows"), which is SQL-reachable but answers a different question: a socket
      # that opened and carried no frames would classify as HTTP, and a `[gori] …` advisory row
      # on a non-WebSocket 101 (#736) would classify as one.
      #
      # The `:protocol` TOKEN and not a WebSocket boolean, because an extended CONNECT carries
      # others — `connect-udp` (RFC 9298) and `connect-ip` (RFC 9484) are extended CONNECTs that
      # are NOT RFC 6455 framing. `H2::Assembler` already tells them apart to decide whether to
      # point a frame codec at the stream; storing what the request DECLARED keeps that
      # distinction on disk instead of collapsing it at the write site.
      #
      # NOT written by the HTTP/1.1 path, which needs nothing: `status == 101` is still the
      # answer there, and per V14's precedent a value no capture produced must not be invented
      # into a column. Rows written before this migration keep NULL, and NULL means "not
      # recorded" — not "this was not an extended CONNECT". They classify exactly as they did
      # before; gori does NOT backfill by guessing at the stored heads.
      V16 = [
        "ALTER TABLE flows ADD COLUMN connect_protocol TEXT",
      ]

      # Where a flow CAME FROM: which gori tool produced it (`source`), which surface issued the
      # request (`source_surface`), and which of that tool's sessions it belongs to
      # (`source_ref`). See `Gori::FlowSource`.
      #
      # Six producers already wrote into this table and NOTHING on the row told them apart: the
      # capture proxy, MCP `send_request` (whose `record_history` defaults to TRUE), a Discover
      # crawl (on by default), an opt-in `--record-history` fuzz sweep or repeater send, and
      # `import`. History is read as evidence, so "the target answered this" and "gori's own
      # Repeater elicited this" being byte-identical here is the same class of defect V5's
      # `short_circuited` fixed one layer down — that one about a response gori FABRICATED, this
      # one about a request gori SENT.
      #
      # Columns and not a re-derivation at read time, for V14's and V16's reason verbatim:
      # `QL.src_cond` compiles `src:` to SQL against this table, so a label derived from
      # something the query cannot see is precisely the drift `Proto`/`FlowSource` exist to
      # prevent.
      #
      # ## Why these are NULLable and NOT backfilled
      #
      # V5 could give `short_circuited` a `NOT NULL DEFAULT 0` because 0 was the TRUTH for every
      # existing row — gori could not short-circuit before that migration. **That argument does
      # not hold here.** gori could already record a repeater send, a fuzz hit, an MCP
      # `send_request`, a crawl and an import before this migration, so writing `proxy` into
      # every pre-existing row would be inventing a fact no capture produced — the thing V14 and
      # V16 both refuse to do. NULL means "not recorded", not "proxy"; the SRC column draws it as
      # `—` and a `src:` term matches neither direction on those rows (`QL::CAVEATS` says so).
      #
      # `source_surface` NULL carries a SECOND meaning for rows that DO have a `source`: a proxy
      # capture has no originating gori surface, because the request came from the client's own
      # program. `source IS NULL` is what separates "not recorded" from "not applicable".
      #
      # `source_ref` is opaque and only meaningful beside `source` — a repeater session id, a
      # fuzz job id, an import's filename. TEXT because each tool numbers its own space (and
      # some do not number at all), and nothing joins on it.
      #
      # No index. `src:` is a low-cardinality term that rides an AND-chain with a selective one,
      # and `flows` already carries six indexes plus the inline request/response BLOBs.
      V17 = [
        "ALTER TABLE flows ADD COLUMN source TEXT",
        "ALTER TABLE flows ADD COLUMN source_surface TEXT",
        "ALTER TABLE flows ADD COLUMN source_ref TEXT",
      ]

      # The PROJECT half of the History view library (#776). A view is a named QL query the
      # History list ANDs over the filter bar, and the global half lives in settings.json
      # (`saved_views.views`); `SavedViews.merged` folds the two together the way
      # `Probe.custom_rules` and `Oast.provider_configs` do for their pairs.
      #
      # `name` is UNIQUE within this project, and the index is what enforces it: the two scopes
      # number themselves independently, so a project view and a global view MAY share a name
      # (`SavedViews.resolve_by_name` prefers the project one, as `Env.effective_vars` prefers a
      # project variable). Enforcing it here rather than only at the surfaces means a hand-edited
      # DB cannot produce two views one `--view NAME` would have to choose between.
      #
      # No `position` column, deliberately. `color_rules` carries one because for a colour rule
      # order IS the meaning — the first enabled match paints the row — while a view is chosen
      # by pick, so its order is display-only and `SavedViews.merged` derives it.
      V18 = [
        <<-SQL,
          CREATE TABLE saved_views (
            id    INTEGER PRIMARY KEY,
            name  TEXT NOT NULL,
            query TEXT NOT NULL
          )
          SQL
        "CREATE UNIQUE INDEX idx_saved_views_name ON saved_views (name COLLATE NOCASE)",
      ]

      # User-defined History columns (#819). A column is an extract descriptor the LIST draws:
      # `header:x-request-id`, `jsonpath:data.id`, a regex capture — the values QL can already
      # filter on but never show.
      #
      # A separate table rather than a `display` flag on `extract_rules`, and the difference is
      # the `position` column right there: an extract rule produces no bytes and cannot compose,
      # so V6 deliberately gave it no order — while columns are read LEFT TO RIGHT and that
      # order is the whole of what the operator arranges. Same split, and the same reasoning,
      # `match_rules` and `extract_rules` already carry between them.
      #
      # `side` is the axis extraction never needed until now: the Sequencer and session bindings
      # both observe RESPONSES, so "the response" was implied by the descriptor. An operator
      # wants an `X-Request-Id` column as often for the request their client SENT. Defaults to
      # `response`, which is what every descriptor written before this migration meant.
      #
      # `width` is 0 for "auto" — the renderer's default cell — rather than NULL, so the column
      # is NOT NULL like every other one here and no reader has to spell the fallback twice.
      #
      # No UNIQUE on `label`: two columns may legitimately share a header (`ID` off the request
      # and `ID` off the response is a comparison, not a mistake), and nothing keys a column by
      # name — the id does.
      V19 = [
        <<-SQL,
          CREATE TABLE display_columns (
            id        INTEGER PRIMARY KEY,
            position  INTEGER NOT NULL DEFAULT 0,
            label     TEXT    NOT NULL,
            side      TEXT    NOT NULL DEFAULT 'response',
            kind      TEXT    NOT NULL,
            selector  TEXT    NOT NULL DEFAULT '',
            pos_start INTEGER NOT NULL DEFAULT 0,
            pos_end   INTEGER NOT NULL DEFAULT 0,
            width     INTEGER NOT NULL DEFAULT 0
          )
          SQL
      ]

      V20 = [
        "ALTER TABLE issues ADD COLUMN cvss TEXT",
      ]

      # gRPC server-reflection cache (#827). ONE row per reflected target, holding the
      # FileDescriptorSet gori synthesized from the FileDescriptorProtos the server returned
      # — so one operator-initiated fetch serves every flow on that host, across restarts,
      # without a second outbound request (P4: the network is touched when someone asks, and
      # this table is what makes "once" enough).
      #
      # Keyed by `scheme://authority`, not by bare host: the plaintext port of a host is not
      # necessarily the same server as its TLS port, and a descriptor set is the server's word
      # about ITSELF.
      #
      # `descriptor` is a BLOB and stays byte-exact (P7) — it is re-parsed by the same
      # `Schema.parse` a file-loaded set goes through, which is what makes a reflected schema
      # and a `protoc --descriptor_set_out` one indistinguishable downstream. `service` records
      # WHICH reflection service answered (`grpc.reflection.v1…` / `…v1alpha…`), because
      # "where did this schema come from" is a question the Project settings row has to answer.
      V21 = [
        <<-SQL,
          CREATE TABLE grpc_reflection (
            target     TEXT    PRIMARY KEY,
            service    TEXT    NOT NULL DEFAULT '',
            fetched_at INTEGER NOT NULL DEFAULT 0,
            services   INTEGER NOT NULL DEFAULT 0,
            files      INTEGER NOT NULL DEFAULT 0,
            descriptor BLOB    NOT NULL
          )
          SQL
      ]

      # `repeaters.tls_preset` — the per-send TLS fingerprint override (#844) THIS TAB sends
      # with, so a reopened tab dials the handshake it was saved with rather than falling back
      # to the destination policy. Two tabs against one host with different values is the
      # whole point of the feature, and a per-TAB column is the only shape that can express it.
      #
      # NULL and '' both mean "no override — use the destination policy", which is what every
      # existing row means and what makes this migration a no-op for them. The value is a
      # PRESET NAME (`Settings::TLS_PRESETS`), kept verbatim: an unknown one is refused at the
      # send (`Settings.tls_preset_error`), never folded away here, so a project written by a
      # newer gori reads back as the name it holds rather than as silence.
      #
      # At V22 the Fuzzer still had no production `fuzz_runs` writer, so its per-session value
      # remained inside `fuzz_sessions.config`. V24 below adds the permanent per-run column as
      # part of the complete result snapshot; this historical migration stays repeater-only.
      V22 = [
        "ALTER TABLE repeaters ADD COLUMN tls_preset TEXT",
      ]

      # WHICH SURFACE acted (#864). The feed already said what happened; it could not say who,
      # so a scope rule an operator edited in the TUI and one an agent rewrote through MCP read
      # identically — on the one surface whose job is telling those apart.
      #
      # `FlowSource::Surface`'s token (`tui`/`cli`/`mcp`), not a second vocabulary: `flows`
      # answers the same question with the same three words, and two spellings of one axis is
      # exactly what P3 forbids. NULL on every row written before this column, and on anything
      # a background engine produced on nobody's behalf — "not recorded" and "no surface" are
      # both honest answers that a defaulted string would have overwritten with a guess.
      V23 = [
        "ALTER TABLE events ADD COLUMN actor TEXT",
      ]

      # Complete, permanent Fuzzer run snapshots. V1 created the run/result tables for this
      # purpose, but their shape stopped at the first HTTP-only Result and no production path
      # ever wrote them. Keep every fact the current Fuzz::Result exposes, plus the transport
      # context needed to reopen a run after its session has since been edited.
      V24 = [
        "ALTER TABLE fuzz_runs ADD COLUMN http2 INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE fuzz_runs ADD COLUMN sni TEXT",
        "ALTER TABLE fuzz_runs ADD COLUMN tls_preset TEXT",
        "ALTER TABLE fuzz_runs ADD COLUMN websocket INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE fuzz_runs ADD COLUMN surface TEXT",
        "ALTER TABLE fuzz_runs ADD COLUMN source_ref TEXT",
        "ALTER TABLE fuzz_results ADD COLUMN position INTEGER",
        "ALTER TABLE fuzz_results ADD COLUMN incomplete INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE fuzz_results ADD COLUMN retried INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE fuzz_results ADD COLUMN chain_error TEXT",
        "ALTER TABLE fuzz_results ADD COLUMN grpc_status INTEGER",
        "ALTER TABLE fuzz_results ADD COLUMN grpc_message TEXT",
        "ALTER TABLE fuzz_results ADD COLUMN timed_out INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE fuzz_results ADD COLUMN resent_count INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE fuzz_results ADD COLUMN wire BLOB",
        "ALTER TABLE fuzz_results ADD COLUMN ws_close_code INTEGER",
        "ALTER TABLE fuzz_results ADD COLUMN ws_frames_in INTEGER",
      ]

      # Version complete result snapshots independently from the database schema. Rows written
      # through V24's three production surfaces contain the current complete shape; older rows
      # came from the never-finished V1 path and cannot be safely auto-restored. The surface is
      # the only durable provenance V24 recorded, so only its three known values are backfilled.
      #
      # Do NOT infer compaction from three empty BLOBs. V24's temporary compactor produced that
      # shape, but a genuinely retained empty request/head/body has the same durable bytes and
      # migration may not guess which evidence to erase. Re-running current compact clears all
      # four nullable byte columns explicitly; schema migration remains byte-preserving.
      V25 = [
        "ALTER TABLE fuzz_runs ADD COLUMN snapshot_version INTEGER NOT NULL DEFAULT 0",
        "UPDATE fuzz_runs SET snapshot_version = 1 WHERE surface IN ('tui', 'cli', 'mcp')",
      ]

      # Frozen issue evidence (#1038): an IMMUTABLE copy of one exchange at the moment it proved
      # a finding, owned by the issue it proves.
      #
      # A copy, not a "protect this flow from retention" flag on `flows`, because the product
      # contract is that ordinary workbench activity must never change what the evidence says
      # — and both live sources are mutable in ways a flag cannot stop. A Repeater tab holds
      # exactly ONE response, and the next send REPLACES it (`update_repeater_response`); the
      # working tab must stay editable and sendable, so the only way to keep the response that
      # confirmed the finding is to keep a copy that the tab's next send cannot reach. A flow
      # is only ever DELETED, but a flag would then have to be honoured by three prune paths,
      # `delete_flows`, `clear_flows` and every export's "no longer captured" branch. The
      # bytes are already capture-capped per flow, and `bytes` is summed against
      # `Evidence::QUOTA_BYTES` on every freeze so the table stays bounded.
      #
      # `source_kind`/`source_id` preserve PROVENANCE. A flow `source_id` is negated when its
      # row is deleted, keeping the original id readable while preventing a later row from
      # inheriting the source reference. The live row may otherwise be re-sent tomorrow and
      # this snapshot must read exactly as it does today. `request_sha256`/`response_sha256` are the hashes
      # of the stored bytes (head + body), written at freeze time so a later reader — an export,
      # a report — can state what it was handed.
      #
      # Evidence and Issue membership are separate: bytes stay even when the last Issue is
      # unlinked/deleted, and one immutable copy may support several findings (#1039).
      # AUTOINCREMENT is required now that `evidence_issue_links` points AT an evidence id:
      # a deleted id must never be reused underneath a stale peer's pending link operation.
      V26 = [
        <<-SQL,
          CREATE TABLE issue_evidence (
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at         INTEGER NOT NULL,
            source_kind        TEXT    NOT NULL,
            source_id          INTEGER NOT NULL,
            method             TEXT    NOT NULL,
            url                TEXT    NOT NULL,
            protocol           TEXT,
            status             INTEGER,
            duration_us        INTEGER,
            error              TEXT,
            request_head       BLOB    NOT NULL,
            request_body       BLOB,
            response_head      BLOB,
            response_body      BLOB,
            request_truncated  INTEGER NOT NULL DEFAULT 0,
            response_truncated INTEGER NOT NULL DEFAULT 0,
            request_sha256     TEXT    NOT NULL,
            response_sha256    TEXT,
            bytes              INTEGER NOT NULL
          )
          SQL
        <<-SQL,
          CREATE TABLE evidence_issue_links (
            evidence_id INTEGER NOT NULL,
            issue_id    INTEGER NOT NULL,
            created_at  INTEGER NOT NULL,
            PRIMARY KEY (evidence_id, issue_id)
          )
          SQL
        # The Issues detail lists an issue's snapshots in freeze order on every open; the
        # reverse index makes a global evidence row's linked Issue ids cheap to resolve.
        "CREATE INDEX idx_evidence_issue_links_issue ON evidence_issue_links (issue_id, evidence_id)",
        "CREATE INDEX idx_evidence_issue_links_evidence ON evidence_issue_links (evidence_id, issue_id)",
        # The History detail and the Repeater ask "does a frozen copy of THIS exist" per open.
        "CREATE INDEX idx_issue_evidence_source ON issue_evidence (source_kind, source_id)",
      ]

      # Issue-linked retest (#1036): an ordered, role-tagged list of Repeater sends with one
      # assertion each, plus a bounded record of what happened the last few times it ran.
      #
      # SEPARATE from `entity_links`, deliberately, and the issue says why: an evidence link
      # answers "what material is related", while a retest step additionally carries order,
      # role, an assertion and execution state. Folding the two would make unlinking a piece
      # of evidence silently delete a test step, and adding a link silently add one.
      #
      # `issue_retest_steps.ref_kind`/`ref_id` reuse the `entity_links` vocabulary so both
      # name a workbench object the same way; only `repeater` is written today (`Retest.plan`
      # refuses the rest), and the column is TEXT rather than a constant so a later kind does
      # not need a migration to be nameable.
      #
      # Runs are a CHILD of the issue and cascade with it (`delete_issue`), unlike frozen
      # evidence: a run summary is a statement about one issue's check and means nothing
      # detached from it, where a frozen exchange is bytes that outlive any filing. The
      # newest `Retest::RUN_HISTORY` runs per issue are kept; `record_retest_run` prunes.
      #
      # AUTOINCREMENT on both parents, for the reason V26 gives: `issue_retest_run_steps`
      # points AT a run id, and a reused id would silently re-parent an orphaned result row.
      V27 = [
        <<-SQL,
          CREATE TABLE issue_retest_steps (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            issue_id   INTEGER NOT NULL,
            position   INTEGER NOT NULL,
            role       TEXT    NOT NULL,
            ref_kind   TEXT    NOT NULL,
            ref_id     INTEGER NOT NULL,
            assertion  TEXT    NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL
          )
          SQL
        "CREATE INDEX idx_issue_retest_steps_issue ON issue_retest_steps (issue_id, position, id)",
        <<-SQL,
          CREATE TABLE issue_retest_runs (
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            issue_id     INTEGER NOT NULL,
            started_at   INTEGER NOT NULL,
            finished_at  INTEGER NOT NULL,
            surface      TEXT,
            verdict      TEXT    NOT NULL,
            total        INTEGER NOT NULL,
            passed       INTEGER NOT NULL,
            failed       INTEGER NOT NULL,
            inconclusive INTEGER NOT NULL,
            errored      INTEGER NOT NULL,
            blocked      INTEGER NOT NULL,
            skipped      INTEGER NOT NULL,
            note         TEXT
          )
          SQL
        "CREATE INDEX idx_issue_retest_runs_issue ON issue_retest_runs (issue_id, started_at, id)",
        # `label`/`method`/`url`/`assertion` are COPIES taken at run time, not references: a
        # run is read after the Repeater tab has been renamed, edited or closed, and a row
        # that re-resolved would describe a request that never ran.
        <<-SQL,
          CREATE TABLE issue_retest_run_steps (
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            run_id      INTEGER NOT NULL,
            position    INTEGER NOT NULL,
            role        TEXT    NOT NULL,
            ref_kind    TEXT    NOT NULL,
            ref_id      INTEGER NOT NULL,
            label       TEXT    NOT NULL,
            method      TEXT    NOT NULL,
            url         TEXT    NOT NULL,
            assertion   TEXT    NOT NULL,
            outcome     TEXT    NOT NULL,
            detail      TEXT    NOT NULL,
            status      INTEGER,
            duration_us INTEGER,
            bytes       INTEGER NOT NULL DEFAULT 0,
            flow_id     INTEGER
          )
          SQL
        "CREATE INDEX idx_issue_retest_run_steps_run ON issue_retest_run_steps (run_id, position, id)",
      ]

      # `repeaters.response_request_sha256` — the SHA-256 of the tab's SAVED request as it
      # stood when the response beside it was written (#1038).
      #
      # A `repeaters` row holds the tab's CURRENT request and its LAST response, and nothing
      # tied the two together: edit the request after a send and the row reads as one
      # exchange that never happened. That is tolerable for a workbench tab — the pane shows
      # what it shows — and NOT tolerable for frozen evidence, whose whole promise is the
      # request and the response of ONE exchange. This column is what lets a freeze tell the
      # two apart: `update_repeater_response` writes the digest of the request that was sent
      # beside the response, and `Evidence.from_repeater` compares it against the digest of
      # the request the row holds now.
      #
      # Over the SAVED request bytes (`repeaters.request`), not the wire: the send seam
      # expands `$NAME` bindings and overlays the active session slot, so a wire digest would
      # differ from the stored request on every tab that uses either and report drift on all
      # of them.
      #
      # NULL on every row written before this column, and NULL means NOT RECORDED — not "no
      # drift" and not "drifted". `from_repeater` leaves `request_drifted` false there: an
      # unknown is not an accusation, and the docs' "freeze right after the send" is still
      # the rule for a response persisted by an older gori.
      V28 = [
        "ALTER TABLE repeaters ADD COLUMN response_request_sha256 TEXT",
      ]

      # Which saved provider an OAST session was registered with, when that provider is a GLOBAL
      # one (#1192). `provider_id` can only name a row of this project's `oast_providers`, so a
      # global provider's session carried no identity and was re-resolved by kind + endpoint —
      # which binds the FIRST match, and so the wrong token whenever two global providers share
      # an endpoint. Holds the provider's scope-qualified key (`g_<id>`, `ProviderConfig#key`),
      # "" for a session registered with no saved provider at all (`gori run oast listen
      # --save`, an MCP `oast_start` given a kind and host), and NULL for a project provider
      # (`provider_id` says it) or a row written before this column. NULL is "not recorded",
      # and `Oast::Sessions.resolve` says what it does with that.
      V29 = [
        "ALTER TABLE oast_sessions ADD COLUMN provider_key TEXT",
      ]

      # The result-capture policy a saved fuzz run was written under (issue #1240): `all` (every
      # row) or `interesting` (matched rows plus the ones carrying an observed fact — an error, a
      # re-send, a truncated capture, the stop condition). Recorded so a filtered archive reads
      # "12 of 100,000 rows kept (keep: interesting)" rather than looking like a lost run — the
      # counters (`sent`/`matched`/`errors`) stay whole-run and `idx` stays the payload position,
      # so a kept row's gaps are the dropped rows. DEFAULT 'all', which is what every run before
      # this column was: the archive kept everything.
      V30 = [
        "ALTER TABLE fuzz_runs ADD COLUMN keep TEXT NOT NULL DEFAULT 'all'",
      ]

      # V31 — the hide-static lens (#1239). `static:` and the lens read a COLUMN decided once,
      # when the response lands (`Store#update_one`), rather than calling `gori_static_asset`
      # per row per query: `content_type` and `status` sit AFTER the body BLOBs, so reading
      # them walks every row's overflow chain, and the Sitemap's DISTINCT — which otherwise
      # never leaves `idx_flows_sitemap` — went from ~4 ms to ~156 ms at 100k flows with the
      # lens on, re-run on every data_version tick (P6).
      #
      # The partial index is that DISTINCT with the lens on, covered: ~2.5 ms on the same set.
      # The rows a project already holds are classified by `BACKFILLS[31]`, not here — see there.
      V31 = [
        "ALTER TABLE flows ADD COLUMN static_asset INTEGER NOT NULL DEFAULT 0",
        "CREATE INDEX idx_flows_sitemap_nonstatic ON flows (host, target, method) WHERE static_asset = 0",
      ]

      # V32 has no schema shape to add; its backfill clears materialized classifications made
      # under V31's original narrower rules. Appending a data-only version makes already-V31
      # projects reclassify their rows once without rebuilding the table or index.
      V32 = [] of String

      # V33 — where a short-circuit rule's answer comes from (#1237). `respond` is the sub-kind
      # (`inline` | `file` | `dir` | `fault`, `Store::RespondKind`) and `respond_args` its
      # parameters as a small JSON object (`Store::RespondArgs`). A sub-kind of `short_circuit`
      # rather than a new `op`: an older binary reads an unknown op as inert (#1242) only from
      # that release on, while every release since #511 already fails a `dir` or `fault` row
      # CLOSED — a directory is "not a regular file", and a fault row's empty head does not parse,
      # so both answer the 502 stub instead of reaching the origin.
      #
      # The UPDATE is plain SQL, so it lives here and not in BACKFILLS: a row that already had a
      # `body_file` was a file stub, and saying so keeps `respond` truthful for every surface
      # that lists it.
      V33 = [
        "ALTER TABLE match_rules ADD COLUMN respond TEXT NOT NULL DEFAULT 'inline'",
        "ALTER TABLE match_rules ADD COLUMN respond_args TEXT NOT NULL DEFAULT ''",
        "UPDATE match_rules SET respond = 'file' WHERE op = 'short_circuit' AND body_file != ''",
      ]

      # Which result a saved fuzz run's `stop_on` tripped on (issue #1270): the `idx` of that
      # row, written by the terminal update only when the run committed `condition_met`. NULL
      # on every other run, and on every `condition_met` run written before this column — NULL
      # means NOT RECORDED, not "no row", and nothing here can recover it: the per-row
      # `stop_hit` flag was never stored, an `after_matches` stop trips on a row that flag does
      # not mark, and concurrency lets later in-flight rows meet the condition too. On the run
      # row rather than a `fuzz_results` column because it is one fact about the run, and it
      # costs no result projection a byte.
      V34 = [
        "ALTER TABLE fuzz_runs ADD COLUMN stop_idx INTEGER",
      ]

      # V35 — endpoints referenced in captured JavaScript (#1243). DERIVED rows: `JsRefs.scan`
      # reads bodies already in the store and sends nothing, so every row here is a projection
      # of a flow and is deleted WITH that flow (`delete_flow_set`, `clear_flows`, both retention
      # sweeps). Not flows, deliberately: a Pending or stub flow would read as "a request was
      # attempted" in History, QL and every export, and nothing was.
      #
      # `path` is the Sitemap's query-less node path (`Sitemap.path_part(node_path)`), the key the
      # tree attaches on; `target` keeps the query the literal carried, for a replay. `host` is
      # `Url.parse`'s lowercased host. `flags` bit 0 = the literal sat in a comment, bit 1 = it
      # was a template literal cut at `${…}`. `base` names what a relative literal was resolved
      # against (absolute|page|referer|guessed). `body_offset` is a byte offset into the decoded
      # response body — not `offset`, which is an SQL keyword.
      #
      # `js_ref_scans` records WHICH flows were scanned, per flow rather than as a watermark:
      # `flows.id` was a reused rowid until V39 (see `detach_flow_refs`), so after a `history clear`
      # the next capture was handed ids BELOW any "scanned up to" mark and would never be scanned. A marker
      # row dies with its flow, so a reused id starts unscanned. `version` is the extractor's
      # (`JsRefs::VERSION`): a flow scanned by an older one reads as unscanned again.
      V35 = [
        <<-SQL,
          CREATE TABLE js_refs (
            id          INTEGER PRIMARY KEY,
            flow_id     INTEGER NOT NULL,
            scheme      TEXT    NOT NULL,
            host        TEXT    NOT NULL,
            port        INTEGER NOT NULL,
            path        TEXT    NOT NULL,
            target      TEXT    NOT NULL,
            literal     TEXT    NOT NULL,
            body_offset INTEGER NOT NULL,
            line        INTEGER NOT NULL,
            flags       INTEGER NOT NULL DEFAULT 0,
            base        TEXT    NOT NULL,
            created_at  INTEGER NOT NULL,
            UNIQUE(host, path, flow_id)
          )
          SQL
        "CREATE INDEX idx_js_refs_flow ON js_refs (flow_id)",
        <<-SQL,
          CREATE TABLE js_ref_scans (
            flow_id    INTEGER PRIMARY KEY,
            version    INTEGER NOT NULL,
            refs       INTEGER NOT NULL,
            scanned_at INTEGER NOT NULL
          )
          SQL
      ]

      # V36 — the rows `Store#abandon_all_pending` finalises: Pending captures that were sent.
      # It runs on the writer at every session open and twice at close, and without this its
      # `state = 0 AND unsent = 0` was a full scan of `flows` — and both columns sit past the
      # body BLOBs (see V31), so it walked every row's overflow chain. The index holds only
      # in-flight flows, so it stays a handful of entries on any project, and a capture pays
      # one small insert/delete pair for it.
      #
      # `0` is `FlowState::Pending.value`, spelled literally because SQLite uses a partial index
      # only for a query whose WHERE carries the same literal (a bound `?` never matches);
      # `abandon_all_pending` interpolates the enum, and `spec/store/pending_index_spec.cr`
      # holds the two together and checks the plan.
      V36 = [
        "CREATE INDEX idx_flows_pending ON flows (id) WHERE state = 0 AND unsent = 0",
      ]

      # V37 — the History list, answered without touching a `flows` row. Every column
      # `Store::SELECT_ROW` reads, plus every non-BLOB column a QL term filters on
      # (`static_asset`), so a list page and a QL filter over the projection are one scan of
      # this index. `id` LEADS, so the index is in rowid order and `ORDER BY id DESC LIMIT n`
      # still stops after n matches instead of sorting.
      #
      # Round 1 tried this shape and measured nothing worth keeping (see the note in
      # `Store.open`): with 8 KB bodies every row fit its leaf page and the 64 MiB cache held
      # them. Real captures carry MB bodies, and then the leaf pages are spread through the
      # whole file between overflow pages, and every column stored after the BLOBs (`status`
      # onwards) is an overflow-chain walk. At 200k flows / 6.5 GB, 2% with 0.5–2 MB bodies:
      # `host:` with no match 121 -> 9.4 ms, `src:repeater` 1061 -> 7.3 ms, `respsize:>1.5M`
      # 252 -> 1.9 ms. ~121 B per flow on disk, ~1.3% more instructions per captured flow.
      #
      # A column added to `SELECT_ROW` or read by a new QL term belongs HERE too (a new
      # version recreating the index), or every list read falls back to the table:
      # `spec/store/list_index_spec.cr` pins the plans so that fails loudly.
      V37 = [
        "CREATE INDEX idx_flows_list ON flows (id, created_at, scheme, method, host, port, target, " \
        "status, request_size, response_size, state, duration_us, content_type, short_circuited, " \
        "advisory, request_content_type, connect_protocol, source, source_surface, source_ref, " \
        "static_asset)",
      ]

      # V38 — `idx_flows_sitemap` widened from (host, target, method) to every column the
      # Sitemap reads. `sitemap_entries_detailed` (MCP list_sitemap, `gori run sitemap`) and
      # `endpoint_observations` (the retest diff) read `status`, `created_at`, `content_type`
      # and `response_size`, all stored after the body BLOBs, so each page walked every row's
      # overflow chain: ~1.2 s per page at 200k flows / 6.5 GB, at ANY offset, because the
      # GROUP BY had to see every row before the first one came out. Covered, and grouped in
      # the index's order (both queries spell their GROUP BY in their ORDER BY order), a page
      # stops after its groups. The DISTINCT tree query, the host completion and the
      # (host, target) lookups keep the prefix they used, now covered too.
      #
      # `static_asset` rides along so the hide-static lens stays covered on the wide query;
      # the plain DISTINCT with the lens on still prefers `idx_flows_sitemap_nonstatic`, which
      # is smaller. `spec/store/sitemap_index_spec.cr` pins the plans.
      V38 = [
        "DROP INDEX idx_flows_sitemap",
        "CREATE INDEX idx_flows_sitemap ON flows (host, target, method, scheme, port, http_version, " \
        "status, created_at, content_type, response_size, static_asset)",
      ]

      # V39 — a flow id, once issued, is never issued again, and neither is an h2 connection id.
      #
      # Both were `INTEGER PRIMARY KEY` without AUTOINCREMENT, so SQLite handed a new row
      # `max(rowid)+1`: after `history clear`, or a delete of the newest flows, the next capture
      # took an id that had named another flow. Every holder of one then pointed at the wrong
      # traffic without noticing — TUI marks, an open detail, an MCP job's results, a
      # `list_history` cursor an agent kept, and above all a PEER process, which never saw the
      # delete. #1342 patched the consumers that were visibly wrong; this removes the cause.
      # `h2_connections` had the same shape: a browser's connection outlives a clear, and the
      # next one took its id and shared its frame log.
      #
      # Seeded the way V10 seeds (read its comment): past the highest id ANYTHING still
      # references, not just `MAX(id)`, so a stranded reference in an emptied table cannot be
      # handed its id back. That list is every column `detach_flow_refs` nulls, the columns a
      # flow's delete removes with it (`ws_messages`, `js_refs`, `js_ref_scans`), the FTS rowids
      # (the contentless index is keyed by `flows.id`, so a stray entry would put search hits on
      # a new flow), the polymorphic refs and a flow evidence `source_id`, which is NEGATED when
      # its flow goes. `flows.h2_conn_id` and `h2_frames.conn_id` seed `h2_connections`.
      #
      # These statements are the REBUILD, the V10 shape: new table, enumerated copy (never
      # `SELECT *`), drop, rename, every index recreated, then the seed — which must follow the
      # rename, because `sqlite_sequence` rows follow `RENAME TO` and the seed reads the table
      # by its final name. Between the copy and the drop `rebuild_v39` runs `verify_v39_copy`,
      # which a bare replay skips: it is there for tables with rows in them. The column order is
      # V1's with V2..V31's ADD COLUMNs appended, and it is kept exactly: everything after the
      # body BLOBs is an overflow-chain walk, and V31, V37 and V38 are built on that. No trigger
      # or view names `flows`, nothing declares a foreign key, and `foreign_keys` is off on
      # every gori connection, so neither the DROP nor the RENAME rewrites anything else.
      #
      # `migrate!` runs them only when it cannot do better. Measured: a copy of a 3.4 GB,
      # 100k-flow project held the write lock 16-21 s, and left the file at 6.75 GB, because the
      # old table's pages go to the freelist until a compact. The same 16 s had already been
      # measured and refused as an open-time cost (`detach_flow_refs`' comment, #552): a peer
      # waiting on the 5 s `busy_timeout` gets `database is locked`. AUTOINCREMENT does not change
      # a table's on-disk format — it only changes how the next rowid is picked, through
      # `sqlite_sequence` — so `Schema.autoincrement_in_place` makes it the change SQLite
      # documents for format-preserving schema edits (lang_altertable.html, "otheralter"): edit
      # the stored CREATE text, bump `schema_version`, then the same seed. Milliseconds at any
      # size. The rebuild remains the definition a bare connection replays (specs build every
      # historical shape that way) and the fallback for a SQLite that refuses the edit.
      #
      # Every `flows` column in table order, spelled once for the copy and for its verification.
      V39_FLOW_COLUMNS = "id, created_at, scheme, host, port, method, target, http_version, sni, alpn, " \
                         "tls_version, request_head, request_body, response_head, response_body, status, " \
                         "reason, content_type, request_size, response_size, state, ttfb_us, duration_us, " \
                         "error, h2_conn_id, h2_stream_id, request_body_truncated, response_body_truncated, " \
                         "unsent, fts_dirty, short_circuited, advisory, request_content_type, " \
                         "connect_protocol, source, source_surface, source_ref, static_asset"

      V39_COPY = [
        <<-SQL,
          CREATE TABLE flows_v39 (
            id                      INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at              INTEGER NOT NULL,
            scheme                  TEXT    NOT NULL,
            host                    TEXT    NOT NULL,
            port                    INTEGER NOT NULL,
            method                  TEXT    NOT NULL,
            target                  TEXT    NOT NULL,
            http_version            TEXT    NOT NULL,
            sni                     TEXT,
            alpn                    TEXT,
            tls_version             TEXT,
            request_head            BLOB    NOT NULL,
            request_body            BLOB,
            response_head           BLOB,
            response_body           BLOB,
            status                  INTEGER,
            reason                  TEXT,
            content_type            TEXT,
            request_size            INTEGER NOT NULL DEFAULT 0,
            response_size           INTEGER,
            state                   INTEGER NOT NULL,
            ttfb_us                 INTEGER,
            duration_us             INTEGER,
            error                   TEXT,
            h2_conn_id              INTEGER,
            h2_stream_id            INTEGER,
            request_body_truncated  INTEGER NOT NULL DEFAULT 0,
            response_body_truncated INTEGER NOT NULL DEFAULT 0,
            unsent                  INTEGER NOT NULL DEFAULT 0,
            fts_dirty               INTEGER NOT NULL DEFAULT 0,
            short_circuited         INTEGER NOT NULL DEFAULT 0,
            advisory                TEXT,
            request_content_type    TEXT,
            connect_protocol        TEXT,
            source                  TEXT,
            source_surface          TEXT,
            source_ref              TEXT,
            static_asset            INTEGER NOT NULL DEFAULT 0
          )
          SQL
        "INSERT INTO flows_v39 (#{V39_FLOW_COLUMNS}) SELECT #{V39_FLOW_COLUMNS} FROM flows",
        <<-SQL,
          CREATE TABLE h2_connections_v39 (
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at INTEGER NOT NULL,
            host       TEXT    NOT NULL,
            port       INTEGER NOT NULL,
            alpn       TEXT    NOT NULL
          )
          SQL
        "INSERT INTO h2_connections_v39 (id, created_at, host, port, alpn) " \
        "SELECT id, created_at, host, port, alpn FROM h2_connections",
      ]

      # Nothing here runs before `Schema.verify_v39_copy` has compared the copies with the
      # originals (see `rebuild_v39`): a DROP is the one statement that cannot be taken back.
      V39_SWAP = [
        "DROP TABLE flows",
        "ALTER TABLE flows_v39 RENAME TO flows",
        # Every index `flows` carried at V38, in the shape its latest version gave it.
        "CREATE INDEX idx_flows_created_at ON flows (created_at)",
        "CREATE INDEX idx_flows_status ON flows (status)",
        "CREATE INDEX idx_flows_h2_conn ON flows (h2_conn_id)",
        "CREATE INDEX idx_flows_sizes ON flows (request_size, response_size)",
        "CREATE INDEX idx_flows_fts_dirty ON flows (id) WHERE fts_dirty = 1",
        "CREATE INDEX idx_flows_sitemap_nonstatic ON flows (host, target, method) WHERE static_asset = 0",
        "CREATE INDEX idx_flows_pending ON flows (id) WHERE state = 0 AND unsent = 0",
        V37[0],
        V38[1],
        "DROP TABLE h2_connections",
        "ALTER TABLE h2_connections_v39 RENAME TO h2_connections",
      ]

      # The same filtered seed V40 uses (`Schema.seed_sql`): a crafted archive's TEXT, REAL or
      # top-of-int64 value in one of these columns would otherwise win the maximum, and hide the
      # real references, or leave every later capture failing with SQLITE_FULL. `magnitude`, not
      # `ABS`, which raises on the one int64 it cannot negate and would abort the upgrade. Each ref
      # keeps its seek: rowid, `idx_flows_h2_conn` (never the row, whose `h2_conn_id` sits after
      # the bodies), and the FTS index read from its top end.
      V39_SEED = seed_sql("flows", [
        "SELECT id AS v FROM flows",
        "SELECT rowid AS v FROM flows_fts WHERE rowid < #{SEED_CEILING} ORDER BY rowid DESC LIMIT 1",
        "SELECT flow_id AS v FROM ws_messages",
        "SELECT flow_id AS v FROM js_refs",
        "SELECT flow_id AS v FROM js_ref_scans",
        "SELECT flow_id AS v FROM issues",
        "SELECT flow_id AS v FROM repeaters",
        "SELECT flow_id AS v FROM fuzz_sessions",
        "SELECT flow_id AS v FROM miner_sessions",
        "SELECT flow_id AS v FROM sequencer_sessions",
        "SELECT flow_id AS v FROM issue_retest_run_steps",
        "SELECT flow_id AS v FROM events",
        "SELECT flow_id AS v FROM intercept_held",
        "SELECT flow_id AS v FROM probe_oast_probes",
        "SELECT sample_flow_id AS v FROM probe_issues",
        "SELECT ref_id AS v FROM entity_links WHERE ref_kind = 'flow'",
        "SELECT ref_id AS v FROM issue_retest_steps WHERE ref_kind = 'flow'",
        "SELECT ref_id AS v FROM issue_retest_run_steps WHERE ref_kind = 'flow'",
        "SELECT #{magnitude("source_id")} AS v FROM issue_evidence WHERE source_kind = 'flow'",
      ]) + seed_sql("h2_connections", [
        "SELECT id AS v FROM h2_connections",
        "SELECT h2_conn_id AS v FROM flows",
        "SELECT conn_id AS v FROM h2_frames",
      ])

      V39 = V39_COPY + V39_SWAP + V39_SEED

      # One table V40 moves to `INTEGER PRIMARY KEY AUTOINCREMENT`, spelled once. `copy` and
      # `swap` are its V10-shaped rebuild (read V10's comment): an enumerated copy into
      # `<table>_autoinc`, then — only after `verify_rebuilt_copies` has compared it with the
      # original — drop, rename, every index recreated. `seed` starts `sqlite_sequence` past the
      # highest id the table or anything outside it still holds, whichever path moved it.
      # `refs` are those outside holders, one `SELECT <value> AS v FROM …` each, a row per value
      # (the seed takes the maximum). `body` is the column list exactly as V39 left it, the
      # ADD COLUMNs appended in order.
      record TableRebuild, table : String, columns : Array(String), body : String,
        indexes : Array(String), refs : Array(String) do
        def temp : String
          "#{table}_autoinc"
        end

        def copy : Array(String)
          cols = columns.join(", ")
          ["CREATE TABLE #{temp} (\n#{body}\n)",
           "INSERT INTO #{temp} (#{cols}) SELECT #{cols} FROM #{table}"]
        end

        def swap : Array(String)
          ["DROP TABLE #{table}", "ALTER TABLE #{temp} RENAME TO #{table}"] + indexes
        end

        # After EVERY swap, because a ref can name another rebuilt table by its final name.
        def seed : Array(String)
          Schema.seed_sql(table, ["SELECT id AS v FROM #{table}"] + refs)
        end
      end

      SEED_CEILING = 1_i64 << 62

      # Start `table`'s `sqlite_sequence` row at the highest of `refs`, one `SELECT <value> AS v
      # FROM …` each (V39 and V40 both). Only an integer below SEED_CEILING counts, filtered inside
      # each ref BEFORE its maximum is taken, so one odd value cannot hide the real ones beside it.
      # No gori issues ids at the ceiling, and a sequence at the top of the int64 range would make
      # every later insert fail with SQLITE_FULL; text or a REAL is not an id at all. SQLite still
      # never hands out an id at or below `MAX(id)`. A ref over one indexed column keeps its
      # min/max lookup: the subquery flattens to `MAX(col) … WHERE col < ceiling`.
      def self.seed_sql(table : String, refs : Array(String)) : Array(String)
        values = refs.join("\n              UNION ALL ") do |ref|
          "SELECT MAX(v) AS v FROM (#{ref}) WHERE v < #{SEED_CEILING} AND typeof(v) = 'integer'"
        end
        ["DELETE FROM sqlite_sequence WHERE name = '#{table}'",
         "INSERT INTO sqlite_sequence (name, seq)\n" \
         "  SELECT '#{table}', COALESCE(MAX(v), 0) FROM (\n              #{values}\n  )"]
      end

      # `ABS` raises on the one int64 it cannot negate; a negation there turns REAL instead, and
      # the seed drops it. Negative ids are DETACHED references (see `delete_repeater`).
      private def self.magnitude(col : String) : String
        "CASE WHEN #{col} < 0 THEN -#{col} ELSE #{col} END"
      end

      # The N of a project custom probe rule's finding code, `custom_p_<N>`.
      private def self.custom_rule_n(col : String, from : String) : String
        "SELECT CAST(substr(#{col}, 10) AS INTEGER) AS v FROM #{from} " \
        "WHERE #{col} GLOB 'custom_p_[0-9]*' AND substr(#{col}, 10) NOT GLOB '*[^0-9]*'"
      end

      # V40 — an id on these eight tables, once issued, is never issued again (#1344).
      #
      # Each was `INTEGER PRIMARY KEY` without AUTOINCREMENT, so SQLite handed a new row
      # `max(rowid)+1` and a delete of the newest rows, or a wipe, gave the next insert an id
      # that had named another row. Whatever still held the old id then acted on the new row
      # without noticing, and the holder is usually another PROCESS (`gori mcp`, `gori run`, a
      # peer TUI) that never saw the delete: a Probe finding's `sample_repeater_id` linked an
      # issue to an unrelated tab, a recreated custom rule inherited the deleted one's finding
      # code (`custom_p_<id>`) and with it the suppressions and false-positive rows, a stale
      # `add_retest_step` passed the gone-issue guard, a stale `delete_scope_rule` could drop
      # an EXCLUDE, a stale `delete_fuzz_run` removed another saved run. V10 did this for the
      # fuzz and miner sessions and V39 for `flows`; this is the same decision for the rest
      # (DESIGN.md §7).
      #
      # Seeded past every reference a surviving row can hold: the columns and polymorphic refs
      # that name each table, negated (detached) refs by magnitude, the session slots' refresh
      # steps and the disabled-rule set in `settings` (their keys spelled out, not read from
      # `SESSION_SLOTS_KEY`/`PROBE_DISABLED_KEY`: a migration is history and must not follow a
      # later rename), the custom rule codes, and the provenance a flow row carries in
      # `source_ref` ("12" for a Repeater send, "issue #3 step 1", "project rule #4 · …") —
      # read from `idx_flows_list`, which covers `source`/`source_ref`, never from `flows`.
      #
      # Moved the way V39 moves `flows` (read its comment): `move_to_autoincrement` edits each
      # eligible table's stored CREATE text in place (`autoincrement_in_place`), which is
      # milliseconds and touches no row, and gives any table it cannot edit the verified
      # rebuild — cheap here, since these tables hold hundreds to a few thousand rows. Every
      # table V1 or a later ADD COLUMN wrote is eligible; the rebuild is for a SQLite that
      # refuses the edit or a CREATE text gori did not write. The statements below are that rebuild, which is what
      # a bare replay runs.
      ID_REBUILDS = [
        TableRebuild.new("repeaters",
          %w[id created_at updated_at target request http2 auto_content_length flow_id position
            response_head response_body response_error response_duration_us name sni tags
            ws_keep_key ws_http_only tls_preset response_request_sha256],
          <<-SQL,
            id                      INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at              INTEGER NOT NULL,
            updated_at              INTEGER NOT NULL,
            target                  TEXT    NOT NULL,
            request                 TEXT    NOT NULL,
            http2                   INTEGER NOT NULL DEFAULT 0,
            auto_content_length     INTEGER NOT NULL DEFAULT 1,
            flow_id                 INTEGER,
            position                INTEGER NOT NULL DEFAULT 0,
            response_head           BLOB,
            response_body           BLOB,
            response_error          TEXT,
            response_duration_us    INTEGER,
            name                    TEXT,
            sni                     TEXT,
            tags                    TEXT,
            ws_keep_key             INTEGER NOT NULL DEFAULT 0,
            ws_http_only            INTEGER NOT NULL DEFAULT 0,
            tls_preset              TEXT,
            response_request_sha256 TEXT
            SQL
          ["CREATE INDEX idx_repeaters_position ON repeaters (position, id)"],
          ["SELECT repeater_id AS v FROM ws_messages",
           "SELECT ref_id AS v FROM entity_links WHERE ref_kind = 'repeater'",
           "SELECT #{magnitude("ref_id")} AS v FROM issue_retest_steps WHERE ref_kind = 'repeater'",
           "SELECT #{magnitude("ref_id")} AS v FROM issue_retest_run_steps WHERE ref_kind = 'repeater'",
           "SELECT #{magnitude("source_id")} AS v FROM issue_evidence WHERE source_kind = 'repeater'",
           "SELECT sample_repeater_id AS v FROM probe_issues",
           # `json_each` raises on text that is not JSON, and `e.value` of a non-object entry
           # is not a JSON object: both are routed to an empty one rather than abort the upgrade.
           "SELECT #{magnitude("r.value")} AS v FROM settings s, " \
           "json_each(CASE WHEN json_valid(s.value) THEN s.value ELSE '[]' END) e, " \
           "json_each(CASE WHEN e.type = 'object' THEN e.value ELSE '{}' END, '$.refresh') r " \
           "WHERE s.key = 'authorize_identities' AND r.type = 'integer'",
           "SELECT CAST(source_ref AS INTEGER) AS v FROM flows WHERE source = 'repeater' " \
           "AND source_ref GLOB '[0-9]*' AND source_ref NOT GLOB '*[^0-9]*'"]),

        TableRebuild.new("probe_custom_rules",
          %w[id title description side region kind pattern severity enabled],
          <<-SQL,
            id          INTEGER PRIMARY KEY AUTOINCREMENT,
            title       TEXT    NOT NULL,
            description TEXT    NOT NULL DEFAULT '',
            side        TEXT    NOT NULL,
            region      TEXT    NOT NULL,
            kind        TEXT    NOT NULL,
            pattern     TEXT    NOT NULL,
            severity    TEXT    NOT NULL,
            enabled     INTEGER NOT NULL DEFAULT 1
            SQL
          [] of String,
          [custom_rule_n("code", "probe_issues"),
           custom_rule_n("code", "probe_suppressions"),
           custom_rule_n("code", "probe_oast_probes"),
           custom_rule_n("rule_id", "probe_oast_probes"),
           custom_rule_n("d.value", "settings s, json_each(CASE WHEN json_valid(s.value) THEN s.value ELSE '[]' END) d") +
           " AND s.key = 'probe_disabled_rules' AND d.type = 'text'"]),

        TableRebuild.new("probe_issues",
          %w[id code category host title severity status hit_count affected sample_flow_id
            sample_repeater_id evidence first_seen last_seen],
          <<-SQL,
            id                 INTEGER PRIMARY KEY AUTOINCREMENT,
            code               TEXT    NOT NULL,
            category           TEXT    NOT NULL,
            host               TEXT    NOT NULL,
            title              TEXT    NOT NULL,
            severity           INTEGER NOT NULL,
            status             INTEGER NOT NULL DEFAULT 0,
            hit_count          INTEGER NOT NULL DEFAULT 1,
            affected           TEXT    NOT NULL DEFAULT '[]',
            sample_flow_id     INTEGER,
            sample_repeater_id INTEGER,
            evidence           TEXT,
            first_seen         INTEGER NOT NULL,
            last_seen          INTEGER NOT NULL,
            UNIQUE(code, host)
            SQL
          ["CREATE INDEX idx_probe_issues_cat ON probe_issues (category, host)",
           "CREATE INDEX idx_probe_issues_triage ON probe_issues (severity DESC, last_seen DESC)"],
          [] of String),

        TableRebuild.new("issues",
          %w[id created_at updated_at title severity host flow_id notes status cvss],
          <<-SQL,
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            title      TEXT    NOT NULL,
            severity   INTEGER NOT NULL,
            host       TEXT,
            flow_id    INTEGER,
            notes      TEXT    NOT NULL DEFAULT '',
            status     INTEGER NOT NULL DEFAULT 0,
            cvss       TEXT
            SQL
          ["CREATE INDEX idx_issues_severity ON issues (severity)",
           "CREATE INDEX idx_issues_triage ON issues (severity DESC, created_at DESC)"],
          ["SELECT owner_id AS v FROM entity_links WHERE owner_kind = 'issue'",
           "SELECT issue_id AS v FROM evidence_issue_links",
           "SELECT issue_id AS v FROM issue_retest_steps",
           "SELECT issue_id AS v FROM issue_retest_runs",
           "SELECT CAST(substr(source_ref, 8) AS INTEGER) AS v FROM flows " \
           "WHERE source = 'retest' AND source_ref GLOB 'issue #[0-9]*'"]),

        TableRebuild.new("match_rules",
          %w[id enabled target pattern replacement position part op match_kind name host
            body_file respond respond_args],
          <<-SQL,
            id           INTEGER PRIMARY KEY AUTOINCREMENT,
            enabled      INTEGER NOT NULL DEFAULT 1,
            target       TEXT    NOT NULL,
            pattern      TEXT    NOT NULL,
            replacement  TEXT    NOT NULL DEFAULT '',
            position     INTEGER NOT NULL DEFAULT 0,
            part         TEXT    NOT NULL DEFAULT 'head',
            op           TEXT    NOT NULL DEFAULT 'replace',
            match_kind   TEXT    NOT NULL DEFAULT 'literal',
            name         TEXT    NOT NULL DEFAULT '',
            host         TEXT    NOT NULL DEFAULT '',
            body_file    TEXT    NOT NULL DEFAULT '',
            respond      TEXT    NOT NULL DEFAULT 'inline',
            respond_args TEXT    NOT NULL DEFAULT ''
            SQL
          [] of String,
          # A mocked flow names the rule that answered it (`Rules#stub_ref`).
          ["SELECT CAST(substr(source_ref, 15) AS INTEGER) AS v FROM flows " \
           "WHERE source_ref GLOB 'project rule #[0-9]*'"]),

        TableRebuild.new("scope_rules",
          %w[id kind match_type pattern],
          <<-SQL,
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            kind       TEXT NOT NULL DEFAULT 'include',
            match_type TEXT NOT NULL DEFAULT 'host',
            pattern    TEXT NOT NULL,
            UNIQUE(kind, match_type, pattern)
            SQL
          [] of String, [] of String),

        TableRebuild.new("host_overrides",
          %w[id host ip],
          <<-SQL,
            id   INTEGER PRIMARY KEY AUTOINCREMENT,
            host TEXT NOT NULL UNIQUE,
            ip   TEXT NOT NULL
            SQL
          [] of String, [] of String),

        # The spool is a private file per run and holds nothing this project's ids index.
        TableRebuild.new("fuzz_runs",
          %w[id session_id created_at finished_at target mode total sent matched errors status
            http2 sni tls_preset websocket surface source_ref snapshot_version keep stop_idx],
          <<-SQL,
            id               INTEGER PRIMARY KEY AUTOINCREMENT,
            session_id       INTEGER,
            created_at       INTEGER NOT NULL,
            finished_at      INTEGER,
            target           TEXT    NOT NULL,
            mode             TEXT    NOT NULL,
            total            INTEGER,
            sent             INTEGER NOT NULL DEFAULT 0,
            matched          INTEGER NOT NULL DEFAULT 0,
            errors           INTEGER NOT NULL DEFAULT 0,
            status           TEXT    NOT NULL DEFAULT 'running',
            http2            INTEGER NOT NULL DEFAULT 0,
            sni              TEXT,
            tls_preset       TEXT,
            websocket        INTEGER NOT NULL DEFAULT 0,
            surface          TEXT,
            source_ref       TEXT,
            snapshot_version INTEGER NOT NULL DEFAULT 0,
            keep             TEXT    NOT NULL DEFAULT 'all',
            stop_idx         INTEGER
            SQL
          ["CREATE INDEX idx_fuzz_runs_session ON fuzz_runs (session_id, id)"],
          ["SELECT run_id AS v FROM fuzz_results"]),
      ]

      V40_COPY = ID_REBUILDS.flat_map(&.copy)
      V40_SWAP = ID_REBUILDS.flat_map(&.swap)

      # Run on either path, after the move. The index is new in V40: closing a Repeater tab
      # clears it from the findings it raised (`delete_repeater`), on the writer fiber, and
      # without it that scans every finding.
      V40_AFTER = [
        "CREATE INDEX idx_probe_issues_sample_repeater ON probe_issues (sample_repeater_id) " \
        "WHERE sample_repeater_id IS NOT NULL",
      ] + ID_REBUILDS.flat_map(&.seed)

      V40 = V40_COPY + V40_SWAP + V40_AFTER

      # V41 — `sequencer_sessions` gets V40's treatment, which V10 withheld because no link could
      # name a session. A link is not the only holder: a peer TUI keeps its tab's row id, and a
      # delete of the newest session followed by a new one handed that id to the new row, which
      # the peer's `reconcile` took for its own tab and its next save overwrote. An Activity row's
      # `goto_session_id` opened the new session the same way. Moved as V40 moves its tables
      # (`move_to_autoincrement`), and seeded past both holders the project keeps: the events
      # that point at a session, and a `sequencer` link, which `LinkRefKind` cannot make today
      # but `delete_sequencer_session` already cascades.
      V41_REBUILDS = [
        TableRebuild.new("sequencer_sessions",
          %w[id created_at updated_at target request http2 sni config flow_id position name],
          <<-SQL,
            id         INTEGER PRIMARY KEY AUTOINCREMENT,
            created_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            target     TEXT    NOT NULL,
            request    BLOB    NOT NULL,
            http2      INTEGER NOT NULL DEFAULT 0,
            sni        TEXT,
            config     TEXT    NOT NULL DEFAULT '',
            flow_id    INTEGER,
            position   INTEGER NOT NULL DEFAULT 0,
            name       TEXT
            SQL
          ["CREATE INDEX idx_sequencer_sessions_position ON sequencer_sessions (position, id)"],
          ["SELECT goto_session_id AS v FROM events WHERE goto_tab = 'sequencer'",
           "SELECT ref_id AS v FROM entity_links WHERE ref_kind = 'sequencer'"]),
      ]

      V41_AFTER = V41_REBUILDS.flat_map(&.seed)
      V41       = V41_REBUILDS.flat_map(&.copy) + V41_REBUILDS.flat_map(&.swap) + V41_AFTER

      # V42 — the response-shape fingerprint of each saved fuzz result (#1351): `Fuzz::Shape`,
      # computed by `Matcher#build` over the decoded body before the retention policy drops it,
      # so a saved run clusters by shape even when its bodies were not kept. A signed INTEGER
      # holding the FNV-1a 64 bits. NULL on every row written before this column; those rows
      # cluster by `Shape.approximate` (outcome + metrics), and the surfaces say so.
      V42 = [
        "ALTER TABLE fuzz_results ADD COLUMN shape INTEGER",
      ]

      # V43 — a JavaScript reference is keyed by its ORIGIN (#1371): `UNIQUE(host, path, flow_id)`
      # kept one row per (host, path) per scanned flow, so a bundle naming both
      # `http://h:8080/p` and `https://h/p` stored whichever resolved first and the other origin
      # was never drawn, listed or counted. Rebuilt with scheme and port in the key; the rows
      # are copied as they are (each old row is still unique under the wider key), so nothing
      # has to be rescanned — a flow scanned before this upgrade just keeps the one origin it
      # stored until a rescan (`sitemap js --scan --rescan`) reads it again. No triggers or
      # views name the table, and the rebuild starts from whatever `js_refs` is there, so a
      # replay (the index specs wind `user_version` back) converges on the same shape.
      V43 = [
        <<-SQL,
          CREATE TABLE js_refs_v43 (
            id          INTEGER PRIMARY KEY,
            flow_id     INTEGER NOT NULL,
            scheme      TEXT    NOT NULL,
            host        TEXT    NOT NULL,
            port        INTEGER NOT NULL,
            path        TEXT    NOT NULL,
            target      TEXT    NOT NULL,
            literal     TEXT    NOT NULL,
            body_offset INTEGER NOT NULL,
            line        INTEGER NOT NULL,
            flags       INTEGER NOT NULL DEFAULT 0,
            base        TEXT    NOT NULL,
            created_at  INTEGER NOT NULL,
            UNIQUE(host, path, scheme, port, flow_id)
          )
          SQL
        "INSERT OR IGNORE INTO js_refs_v43 (id, flow_id, scheme, host, port, path, target, literal, " \
        "body_offset, line, flags, base, created_at) SELECT id, flow_id, scheme, host, port, path, target, " \
        "literal, body_offset, line, flags, base, created_at FROM js_refs",
        "DROP TABLE js_refs",
        "ALTER TABLE js_refs_v43 RENAME TO js_refs",
        "CREATE INDEX idx_js_refs_flow ON js_refs (flow_id)",
      ]

      # Data statements that call gori's OWN SQL functions, run by `migrate!` right after the
      # version they complete. Kept out of MIGRATIONS because that list is plain schema that a
      # bare connection can replay (specs build every historical shape that way), and a bare
      # connection has no `gori_static_asset`; `migrate!` registers it before running these.
      #
      # 31: rewrite only rows that ARE static (an UPDATE storing 0 over the default would still
      # rewrite every row's overflow chain), and only completed responses with a status the rule
      # can call static, so a pending or failed transfer is never even classified. ~2.5 s once
      # at 100k flows, 40% of them 20 KB images.
      # 32: only clear old positive flags that the current classifier rejects. The rule changes
      # in #1257 add exclusions, never newly-static cases, so this scans the old positive subset
      # and leaves still-static rows and their overflow chains untouched.
      BACKFILLS = {
        31 => "UPDATE flows SET static_asset = 1 " \
              "WHERE state = #{FlowState::Complete.value} AND (status BETWEEN 200 AND 299 OR status = 304) " \
              "AND gori_static_asset(content_type, target, status) = 1",
        32 => "UPDATE flows SET static_asset = 0 WHERE static_asset = 1 " \
              "AND (state != #{FlowState::Complete.value} OR gori_static_asset(content_type, target, status) = 0)",
      }

      MIGRATIONS = [V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15, V16, V17,
                    V18, V19, V20, V21, V22, V23, V24, V25, V26, V27, V28, V29, V30, V31, V32, V33,
                    V34, V35, V36, V37, V38, V39, V40, V41, V42, V43]

      def self.migrate!(db : DB::Database, read_only : Bool = false) : Nil
        db.using_connection do |conn|
          # A read-only open peeks at `user_version` WITHOUT the write lock first, and returns
          # when there is nothing to do — which is the overwhelmingly common case. That peek is
          # what makes `gori mcp --read-only` honest: otherwise the one write lock it still took
          # was at startup, against whichever gori is capturing into the project, and a busy
          # database turned "serve this project read-only" into "start unbound" five seconds
          # later (#752). A stale schema still falls through and migrates — a database this
          # binary cannot read is worse than a write the operator did not ask for — and a schema
          # from a NEWER gori still has to reach the refusal below, so only `current == VERSION`
          # may take this exit.
          #
          # Writable opens do NOT take this shortcut. The `current > VERSION` refusal below
          # has to observe the version AFTER any concurrent migrator commits; peek-then-skip
          # would let an older gori see VERSION, skip the lock, and write into a schema a
          # newer binary just upgraded. Lock-first serialises that. The cost is a brief
          # IMMEDIATE at every writable open, which `busy_timeout` absorbs.
          if read_only && conn.scalar("PRAGMA user_version").as(Int64).to_i == VERSION
            next
          end
          # Take the write lock (RESERVED) BEFORE reading user_version, so concurrent
          # openers of the same db serialize here: the loser blocks on BEGIN IMMEDIATE
          # (busy_timeout), then re-reads an already-migrated user_version and does
          # nothing — rather than both reading current=0 and racing the same CREATE/
          # ALTER statements, which crashed the loser with an uncaught SQLite error.
          conn.exec("BEGIN IMMEDIATE")
          begin
            current = conn.scalar("PRAGMA user_version").as(Int64).to_i
            # A db stamped ABOVE what this binary knows was written by a NEWER gori, and
            # there is nothing to migrate: `MIGRATIONS[current..]?` is nil past the end, so
            # the runner used to fall straight through to COMMIT and report a clean open.
            # The store then ran against a schema it does not understand — every read that
            # touches a column the newer version added or renamed fails as a raw driver
            # error somewhere far from the cause, and a write can persist rows that the
            # newer build's own constraints would have refused. This is not hypothetical
            # here: one `~/.gori` is shared by every gori on the host, so a project opened
            # once by a newer build (a release, another worktree's binary, a `gori update`
            # that was rolled back) is then opened by an older one. Refuse it by name, and
            # say which two versions disagree — the operator can act on "upgrade gori",
            # not on "no such column: advisory".
            #
            # DOWNWARD is still fine (`current < VERSION` migrates as always); only the
            # direction that cannot be reconciled is refused.
            # `>`, not `>=`: an up-to-date db has current == VERSION and must open normally
            # (`MIGRATIONS[VERSION..]?` is an empty slice, not nil, so the loop just no-ops).
            if current > VERSION
              raise Gori::Error.new(
                "database schema v#{current} was written by a newer version of gori " \
                "(this build understands up to v#{VERSION}) — upgrade gori, or point " \
                "--db/--project at another database")
            end
            # A backfill calls gori's own SQL functions, and not every caller hands in a pooled
            # Store connection — a bench fixture migrates a bare `DB.open`. Registering is
            # idempotent, so a Store connection pays nothing.
            conn.as(SQLite3::Connection).gori_install_scope_match if current < VERSION
            MIGRATIONS[current..]?.try &.each_with_index(offset: current) do |statements, idx|
              run_statements(conn, statements).each { |sql| conn.exec(sql) }
              BACKFILLS[idx + 1]?.try { |sql| conn.exec(sql) }
              conn.exec("PRAGMA user_version = #{idx + 1}")
            end
            conn.exec("COMMIT")
          rescue ex
            conn.exec("ROLLBACK") rescue nil
            raise ex
          end
        end
      end

      # The statements one MIGRATIONS entry actually runs. V39–V41 do their table move in code
      # first and leave only their seeds; V42 is skipped when its column is already there.
      private def self.run_statements(conn : DB::Connection, statements : Array(String)) : Array(String)
        if statements.same?(V39)
          rebuild_v39(conn) unless autoincrement_in_place(conn.as(SQLite3::Connection))
          V39_SEED
        elsif statements.same?(V40)
          move_to_autoincrement(conn.as(SQLite3::Connection), ID_REBUILDS, 40)
          V40_AFTER
        elsif statements.same?(V41)
          move_to_autoincrement(conn.as(SQLite3::Connection), V41_REBUILDS, 41)
          V41_AFTER
        elsif statements.same?(V42) && column?(conn, "fuzz_results", "shape")
          # SQLite has no `ADD COLUMN IF NOT EXISTS`, and every migration since V36 is
          # replay-safe: a project whose `user_version` was wound back (the index specs rebuild
          # an older shape that way) already holds the column.
          [] of String
        else
          statements
        end
      end

      private def self.column?(conn : DB::Connection, table : String, column : String) : Bool
        !conn.query_one?("SELECT 1 FROM pragma_table_info(?) WHERE name = ?", table, column,
          as: Int64).nil?
      end

      # The tables V39 moves to AUTOINCREMENT, and the one clause each CREATE text carries.
      private AUTOINCREMENT_TABLES = {"flows", "h2_connections"}

      # Every table the CURRENT schema keeps as AUTOINCREMENT, read off the migrations rather
      # than listed: a CREATE that says AUTOINCREMENT (a `_vNN` or `_autoinc` copy renamed onto
      # its table counts as that table), V39's in-place tables, and V40's and V41's. An archive
      # written before one of them got there has no sequence row for it, and the migration seeds
      # one from what the table holds, so the archive check reads them all (`ProjectArchive`).
      # spec/store/table_id_autoincrement_migration_spec.cr holds it equal to a fresh store's.
      class_getter autoincrement_tables : Set(String) do
        created = MIGRATIONS.flat_map(&.to_a).flat_map do |sql|
          sql.scan(/CREATE TABLE(?: IF NOT EXISTS)?\s+"?(\w+)"?\s*\(([^;]*?\bAUTOINCREMENT\b)/i).map(&.[1].sub(/_(?:v\d+|autoinc)\z/, ""))
        end
        (created + AUTOINCREMENT_TABLES.to_a + (ID_REBUILDS + V41_REBUILDS).map(&.table)).to_set
      end
      private ROWID_CLAUSE      = "INTEGER PRIMARY KEY"
      private ROWID_DECLARATION = /\(\s*"?id"?\s+INTEGER PRIMARY KEY\s*,/

      # V39 without the copy: rewrite each table's stored CREATE to say AUTOINCREMENT and bump
      # `schema_version`, so every connection — this one included, verified — reparses it. The
      # rows, the indexes and the FTS rowids are not touched, because nothing about their bytes
      # changes. Runs inside `migrate!`'s transaction, under a savepoint of its own.
      #
      # Returns false, having changed nothing, when it cannot be sure: a CREATE text that is not
      # the one V1 wrote (exactly one rowid clause, no AUTOINCREMENT yet), or a SQLite that
      # refuses the edit. `migrate!` then runs the V39 rebuild, which always works and only
      # costs time. SQLITE_DBCONFIG_DEFENSIVE is what refuses it — it blocks `writable_schema`
      # and a `schema_version` write — and some builds turn it on by default (macOS's system
      # libsqlite3 does, checked), so it is lifted for these statements and put back. The
      # read-back of the cookie is the check that the bump landed (without it, the other
      # connections would keep the old definition), and the reparsed columns must match the old
      # ones exactly — or the savepoint is rolled back and the verified rebuild runs instead.
      #
      # Nothing here reads a row: every check is on the schema. `PRAGMA quick_check` did stand
      # here, and it walks the whole table, bodies' overflow chains included — 10-16 s on a
      # 3.3 GB History, measured, under the write lock a peer waits 5 s for. What it guarded (an
      # edit landing somewhere other than the rowid clause) is what `in_place_eligible?` rules
      # out before the edit, from the text alone: with the phrase present exactly once and first,
      # the blind `replace()` can only extend the rowid clause.
      #
      # `tables` defaults to V39's; V40 and V41 pass the ones `in_place_eligible?` accepts.
      def self.autoincrement_in_place(conn : SQLite3::Connection,
                                      tables : Enumerable(String) = AUTOINCREMENT_TABLES) : Bool
        return false if tables.empty? || !tables.all? { |table| in_place_eligible?(conn, table) }

        shape = tables.map { |table| column_shape(conn, table) }
        defensive = conn.gori_swap_defensive(false)
        conn.exec("SAVEPOINT autoincrement_in_place")
        begin
          cookie = conn.scalar("PRAGMA schema_version").as(Int64)
          conn.exec("PRAGMA writable_schema = ON")
          names = tables.join(", ") { |t| "'#{t}'" }
          conn.exec("UPDATE sqlite_master SET sql = replace(sql, '#{ROWID_CLAUSE}', '#{ROWID_CLAUSE} AUTOINCREMENT') " \
                    "WHERE type = 'table' AND name IN (#{names})")
          conn.exec("PRAGMA schema_version = #{cookie + 1}")
          conn.exec("PRAGMA writable_schema = OFF")
          moved = conn.scalar("PRAGMA schema_version").as(Int64) == cookie + 1 &&
                  tables.map { |table| column_shape(conn, table) } == shape
        rescue SQLite3::Exception
          moved = false
        end
        if moved
          conn.exec("RELEASE autoincrement_in_place")
        else
          conn.exec("PRAGMA writable_schema = OFF") rescue nil
          conn.exec("ROLLBACK TO autoincrement_in_place")
          conn.exec("RELEASE autoincrement_in_place")
        end
        moved
      ensure
        conn.gori_swap_defensive(defensive) unless defensive.nil?
      end

      # The stored CREATE text is the one gori wrote: its FIRST column is `id INTEGER PRIMARY KEY`,
      # spelled as V1 spells it, the phrase appears nowhere else in any case or spacing (the edit
      # is a blind `replace()`), there is no AUTOINCREMENT yet, and there is nothing a text edit
      # could reach into unseen — no CHECK or GENERATED expression, no comment — nor a WITHOUT
      # ROWID tail, where SQLite refuses AUTOINCREMENT outright. ADD COLUMNs
      # append plain declarations, so every table any gori wrote passes; anything else, such as
      # a crafted archive, takes the verified rebuild.
      def self.in_place_eligible?(conn : DB::Connection, table : String) : Bool
        sql = conn.query_one?("SELECT sql FROM sqlite_master WHERE type = 'table' AND name = ?", table, as: String)
        return false if sql.nil? || sql.includes?("--") || sql.includes?("/*")
        return false if sql.matches?(/\b(CHECK|GENERATED|AUTOINCREMENT)\b/i) || sql.matches?(/\bWITHOUT\s+ROWID\b/i)
        sql.matches?(ROWID_DECLARATION) && sql.scan(/integer\s+primary\s+key/i).size == 1
      end

      # V40's and V41's move: every eligible table in place, in one edit; the rest — or all of
      # them, when SQLite refuses the edit — by the verified rebuild. The seed (and V40's new
      # index) follow in the version's `_AFTER` statements either way. Returns the tables that
      # were rebuilt.
      def self.move_to_autoincrement(conn : SQLite3::Connection, rebuilds : Array(TableRebuild),
                                     version : Int32) : Array(String)
        eligible = rebuilds.select { |r| in_place_eligible?(conn, r.table) }
        eligible.clear unless autoincrement_in_place(conn, eligible.map(&.table))
        rebuild = rebuilds - eligible
        return [] of String if rebuild.empty?
        begin
          rebuild.each { |r| r.copy.each { |sql| conn.exec(sql) } }
          verify_rebuilt_copies(conn, rebuild, version)
          rebuild.each { |r| r.swap.each { |sql| conn.exec(sql) } }
        rescue ex : SQLite3::Exception
          raise ex unless ex.code == LibSQLite3::Code::FULL.value
          raise Gori::Error.new("not enough free disk space to upgrade this project: this gori rebuilds " \
                                "#{rebuild.join(", ", &.table)} once. Nothing was changed; free some space " \
                                "and open it again")
        end
        rebuild.map(&.table)
      end

      # Each column as SQLite parses it — position, name, type, NOT NULL, default, key — so the
      # in-place edit can check it changed nothing but the rowid rule.
      private def self.column_shape(conn : DB::Connection, table : String) : Array(String)
        conn.query_all("SELECT cid || '|' || name || '|' || type || '|' || \"notnull\" || '|' || " \
                       "COALESCE(dflt_value, '-') || '|' || pk FROM pragma_table_info(?)", table, as: String)
      end

      # V39's fallback: copy, verify, swap (see V39). It writes a second copy of the History
      # table inside one transaction, so the WAL grows by the table's size and the file by as
      # much again at the checkpoint. A disk that fills part-way answers SQLITE_FULL, which
      # would otherwise reach the operator as "database or disk is full" with no hint that this
      # open needs room for a one-time rebuild, or how much.
      def self.rebuild_v39(conn : DB::Connection) : Nil
        need = 2_i64 * conn.scalar("PRAGMA page_count").as(Int64) * conn.scalar("PRAGMA page_size").as(Int64)
        begin
          V39_COPY.each { |sql| conn.exec(sql) }
          verify_v39_copy(conn)
          V39_SWAP.each { |sql| conn.exec(sql) }
        rescue ex : SQLite3::Exception
          raise ex unless ex.code == LibSQLite3::Code::FULL.value
          raise Gori::Error.new("not enough free disk space to upgrade this project: this gori rebuilds " \
                                "its History table once, which needs about #{approx_size(need)} free " \
                                "(twice the project file). Nothing was changed; free some space and open it again")
        end
      end

      private def self.approx_size(bytes : Int64) : String
        return "#{(bytes / 1_073_741_824).round(1)} GB" if bytes >= 1_073_741_824
        "#{(bytes / 1_048_576).ceil.to_i} MB"
      end

      private V39_BLOBS = {"request_head", "request_body", "response_head", "response_body"}

      # Compare V39's copies with the tables they replace, BEFORE either original is dropped, and
      # raise on any difference — `migrate!` then rolls the whole upgrade back and the project
      # stays on the version it had, whole. A bug here would otherwise commit a damaged `flows`
      # table, and that is the one outcome of this migration nobody can undo.
      #
      # Whole-table: row count, lowest and highest id, and the summed length of every BLOB
      # column (`length()` of a BLOB reads the record header, not the overflow chain). Every
      # row: every non-BLOB column compared with `IS` — the columns after the BLOBs walk each
      # overflow chain, which the fallback can afford, since it holds the write lock for
      # seconds anyway. The body BYTES of the lowest, the highest and up to 64 random ids are
      # compared too; the rest are checked by length. And the FTS rowids at both ends of the
      # index must still name a row exactly where they named one before, since the contentless
      # index is keyed by `flows.id` and is not copied at all.
      def self.verify_v39_copy(conn : DB::Connection) : Nil
        totals = "COUNT(*), MIN(id), MAX(id), " + V39_BLOBS.join(", ") { |c| "SUM(length(#{c}))" }
        before = conn.query_one("SELECT #{totals} FROM flows", as: {Int64, Int64?, Int64?, Int64?, Int64?, Int64?, Int64?})
        after = conn.query_one("SELECT #{totals} FROM flows_v39", as: {Int64, Int64?, Int64?, Int64?, Int64?, Int64?, Int64?})
        v39_copy_mismatch("flows totals #{before} became #{after}") unless before == after

        plain = V39_FLOW_COLUMNS.split(", ").reject { |c| V39_BLOBS.includes?(c) }
        same = plain.join(" AND ") { |c| v39_same(c) }
        equal = conn.scalar("SELECT COUNT(*) FROM flows o JOIN flows_v39 n ON n.id = o.id WHERE #{same}").as(Int64)
        v39_copy_mismatch("#{before[0] - equal} of #{before[0]} rows differ outside the bodies") unless equal == before[0]

        sample = [] of Int64
        conn.query("SELECT id FROM (SELECT id FROM flows ORDER BY random() LIMIT 64) " \
                   "UNION SELECT MIN(id) FROM flows UNION SELECT MAX(id) FROM flows") do |rs|
          rs.each { rs.read(Int64?).try { |id| sample << id } }
        end
        unless sample.empty?
          bodies = V39_BLOBS.join(" AND ") { |c| v39_same(c) }
          equal = conn.scalar("SELECT COUNT(*) FROM flows o JOIN flows_v39 n ON n.id = o.id " \
                              "WHERE o.id IN (#{sample.join(", ")}) AND #{bodies}").as(Int64)
          v39_copy_mismatch("#{sample.size - equal} of #{sample.size} sampled bodies differ") unless equal == sample.size
        end

        fts = [] of Int64
        {"DESC", "ASC"}.each do |dir|
          conn.query("SELECT rowid FROM flows_fts ORDER BY rowid #{dir} LIMIT 32") { |rs| rs.each { fts << rs.read(Int64) } }
        end
        fts.uniq.each do |id|
          was = conn.scalar("SELECT COUNT(*) FROM flows WHERE id = ?", id).as(Int64)
          now = conn.scalar("SELECT COUNT(*) FROM flows_v39 WHERE id = ?", id).as(Int64)
          v39_copy_mismatch("search index entry #{id} resolved to #{was} row(s), now #{now}") unless was == now
        end

        h2_count = conn.scalar("SELECT COUNT(*) FROM h2_connections").as(Int64)
        h2_same = conn.scalar("SELECT COUNT(*) FROM h2_connections o JOIN h2_connections_v39 n ON n.id = o.id " \
                              "WHERE o.created_at IS n.created_at AND o.host IS n.host AND o.port IS n.port " \
                              "AND o.alpn IS n.alpn").as(Int64)
        h2_copied = conn.scalar("SELECT COUNT(*) FROM h2_connections_v39").as(Int64)
        unless h2_same == h2_count && h2_copied == h2_count
          v39_copy_mismatch("h2_connections: #{h2_count} rows, #{h2_copied} copied, #{h2_same} identical")
        end
      end

      # One column of `o` (the original) and `n` (the copy) holding the same value. `IS` alone
      # compares under column affinity, so a TEXT '443' in a column the copy declares INTEGER
      # reads as equal to the 443 the copy converted it to; the storage class has to match too.
      private def self.v39_same(column : String) : String
        "o.#{column} IS n.#{column} AND typeof(o.#{column}) = typeof(n.#{column})"
      end

      private def self.v39_copy_mismatch(what : String) : NoReturn
        raise Gori::Error.new("schema v39: the rebuilt History table does not match the original " \
                              "(#{what}); the upgrade was rolled back and nothing was changed")
      end

      # Compare each rebuild's copy with the table it replaces, BEFORE any original is dropped,
      # and raise on any difference: `migrate!` then rolls the whole upgrade back and the project
      # stays on the version it had, whole. A DROP is the one statement here nobody can take
      # back, so a bug in a copy must not reach it.
      #
      # The column names first, both tables against the rebuild's list. Then totals (row count,
      # lowest and highest id, the summed `length()` of every column), which name WHAT differs.
      # Then every row, since these tables are small: joined on id, each column compared the way
      # V39's check compares (`v39_same`: `IS` and the same storage class), so a NULL matches
      # only a NULL and a BLOB compares by its bytes. With the counts equal and `id` unique on
      # both sides, every row matching is the whole table matching.
      def self.verify_rebuilt_copies(conn : DB::Connection, rebuilds : Enumerable(TableRebuild), version : Int32) : Nil
        rebuilds.each do |r|
          # The list is the copy's AND the comparison's, so a column missing from it would vanish
          # unnoticed.
          {r.table, r.temp}.each do |t|
            names = conn.query_all("SELECT name FROM pragma_table_info(?) ORDER BY cid", t, as: String)
            rebuild_mismatch(version, r.table, "#{t} has columns #{names}") unless names == r.columns
          end
          totals = "COUNT(*), MIN(id), MAX(id), " + r.columns.join(", ") { |c| "SUM(length(#{c}))" }
          before = int_row(conn, "SELECT #{totals} FROM #{r.table}")
          after = int_row(conn, "SELECT #{totals} FROM #{r.temp}")
          unless before == after
            rebuild_mismatch(version, r.table, "totals #{before} became #{after}")
          end
          same = r.columns.join(" AND ") { |c| v39_same(c) }
          equal = conn.scalar("SELECT COUNT(*) FROM #{r.table} o JOIN #{r.temp} n ON n.id = o.id WHERE #{same}").as(Int64)
          count = before.first || 0_i64
          rebuild_mismatch(version, r.table, "#{count - equal} of #{count} rows differ") unless equal == count
        end
      end

      private def self.int_row(conn : DB::Connection, sql : String) : Array(Int64?)
        row = [] of Int64?
        conn.query_one(sql) { |rs| rs.column_count.times { row << rs.read(Int64?) } }
        row
      end

      private def self.rebuild_mismatch(version : Int32, table : String, what : String) : NoReturn
        raise Gori::Error.new("schema v#{version}: the rebuilt #{table} table does not match the original " \
                              "(#{what}); the upgrade was rolled back and nothing was changed")
      end
    end
  end
end

# `sqlite3_db_config` is variadic and the shard binds none of it. Additive, like ScopeMatch's.
lib LibSQLite3
  fun db_config = sqlite3_db_config(SQLite3, Int32, ...) : Int32
end

class SQLite3::Connection
  private DBCONFIG_DEFENSIVE = 1010

  # Set SQLITE_DBCONFIG_DEFENSIVE on this connection and return what it was, so a caller can
  # put it back. Only the in-place AUTOINCREMENT edit (V39, V40, V41) lifts it (see
  # `Schema.autoincrement_in_place`).
  def gori_swap_defensive(on : Bool) : Bool
    was = 0
    LibSQLite3.db_config(@db, DBCONFIG_DEFENSIVE, -1, pointerof(was))
    LibSQLite3.db_config(@db, DBCONFIG_DEFENSIVE, on ? 1 : 0, Pointer(Int32).null)
    was != 0
  end
end
