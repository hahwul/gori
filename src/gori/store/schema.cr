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

      MIGRATIONS = [V1, V2]

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
