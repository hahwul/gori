require "db"

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
        # indexed. Query terms must be >=3 chars (QL falls back to a BLOB LIKE scan below that).
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
        #  - fuzz_results: per-request rows (metrics + optional captured bytes for the
        #    matched/kept results), so a finished run can be reopened and inspected. The
        #    frontends persist selectively per keep_bodies (a billion-row cluster bomb is
        #    never stored whole).
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
      # refused the way the TUI's editor already refuses it (read-only there, `binary?`
      # gating `read_only_selection?`). Same 0-default rationale as `head_only`: a per-session
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
      # `sequencer_sessions` is NOT rebuilt. `LinkRefKind.parse` accepts only
      # flow|repeater|fuzz|miner, so nothing can reference a sequencer session and there is no
      # id to protect today — `delete_sequencer_session` takes the cascade pre-emptively, and
      # its comment says that whoever adds a `Sequencer` variant needs this rebuild too.
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
      # the request bytes on every load (`WsEngine.upgrade_request?` — an `Upgrade:` header),
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

      MIGRATIONS = [V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15]

      def self.migrate!(db : DB::Database) : Nil
        db.using_connection do |conn|
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
            MIGRATIONS[current..]?.try &.each_with_index(offset: current) do |statements, idx|
              statements.each { |sql| conn.exec(sql) }
              conn.exec("PRAGMA user_version = #{idx + 1}")
            end
            conn.exec("COMMIT")
          rescue ex
            conn.exec("ROLLBACK") rescue nil
            raise ex
          end
        end
      end
    end
  end
end
