require "db"

module Gori
  class Store
    # Tiny `PRAGMA user_version` migration runner. Each entry in MIGRATIONS is a
    # list of statements taking the DB from version N to N+1. New subsystems
    # (FTS5 for QL, a tags table, a connections table) arrive as *later*
    # migrations — which is exactly why none of them exist in v1 (P0).
    module Schema
      VERSION = 17

      V1 = [
        <<-SQL,
        CREATE TABLE flows (
          id            INTEGER PRIMARY KEY,
          created_at    INTEGER NOT NULL,
          scheme        TEXT    NOT NULL,
          host          TEXT    NOT NULL,
          port          INTEGER NOT NULL,
          method        TEXT    NOT NULL,
          target        TEXT    NOT NULL,
          http_version  TEXT    NOT NULL,
          sni           TEXT,
          alpn          TEXT,
          tls_version   TEXT,
          request_head  BLOB    NOT NULL,
          request_body  BLOB,
          response_head BLOB,
          response_body BLOB,
          status        INTEGER,
          reason        TEXT,
          content_type  TEXT,
          request_size  INTEGER NOT NULL DEFAULT 0,
          response_size INTEGER,
          state         INTEGER NOT NULL,
          ttfb_us       INTEGER,
          duration_us   INTEGER,
          error         TEXT
        )
        SQL
        "CREATE INDEX idx_flows_created_at ON flows (created_at)",
      ]

      V2 = [
        <<-SQL,
        CREATE TABLE ws_messages (
          id         INTEGER PRIMARY KEY,
          flow_id    INTEGER NOT NULL,
          created_at INTEGER NOT NULL,
          direction  TEXT    NOT NULL,
          opcode     INTEGER NOT NULL,
          payload    BLOB    NOT NULL
        )
        SQL
        "CREATE INDEX idx_ws_messages_flow ON ws_messages (flow_id)",
      ]

      # Scope (display lens) + Findings (human-confirmed vuln records).
      V3 = [
        "CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)",
        "CREATE TABLE scope_rules (id INTEGER PRIMARY KEY, pattern TEXT NOT NULL UNIQUE)",
        <<-SQL,
        CREATE TABLE findings (
          id         INTEGER PRIMARY KEY,
          created_at INTEGER NOT NULL,
          updated_at INTEGER NOT NULL,
          title      TEXT    NOT NULL,
          severity   INTEGER NOT NULL,
          host       TEXT,
          flow_id    INTEGER,
          notes      TEXT    NOT NULL DEFAULT ''
        )
        SQL
        "CREATE INDEX idx_findings_severity ON findings (severity)",
      ]

      # Match&Replace lens: literal head rewrites applied to in-flight traffic.
      V4 = [
        <<-SQL,
        CREATE TABLE match_rules (
          id          INTEGER PRIMARY KEY,
          enabled     INTEGER NOT NULL DEFAULT 1,
          target      TEXT    NOT NULL,
          pattern     TEXT    NOT NULL,
          replacement TEXT    NOT NULL DEFAULT '',
          position    INTEGER NOT NULL DEFAULT 0
        )
        SQL
      ]

      # HTTP/2: raw frame log per connection (the truth, P7) + a decoded
      # projection (streams become rows in `flows`, added by a later slice).
      V5 = [
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
      ]

      # Link a flow (decoded h2 projection) back to its raw frame log so the
      # detail view can show the underlying frames.
      V6 = [
        "ALTER TABLE flows ADD COLUMN h2_conn_id INTEGER",
        "ALTER TABLE flows ADD COLUMN h2_stream_id INTEGER",
      ]

      # Capture cap (P-stability): the stored body BLOB may be truncated to a
      # size ceiling so a huge transfer can't OOM the proxy or bloat one row;
      # request_size/response_size keep the TRUE wire size, these flag the cut.
      V7 = [
        "ALTER TABLE flows ADD COLUMN request_body_truncated INTEGER NOT NULL DEFAULT 0",
        "ALTER TABLE flows ADD COLUMN response_body_truncated INTEGER NOT NULL DEFAULT 0",
      ]

      # Query scalability: a status index (the one projection filter with useful
      # cardinality + range queries) and a compact full-text index over body text
      # so `body:` doesn't CAST+scan every BLOB. The FTS rowid is flows.id; the
      # indexed text per side is capped (Store::FTS_INDEX_MAX) so a big body can't
      # bloat the index. Existing rows are backfilled. host/path stay substring
      # LIKE (unindexable) but are now bounded by retention.
      V8 = [
        "CREATE INDEX idx_flows_status ON flows (status)",
        # Index h2_conn_id so the retention sweep's orphan-h2 cleanup doesn't
        # full-scan flows.
        "CREATE INDEX idx_flows_h2_conn ON flows (h2_conn_id)",
        # trigram tokenizer => case-insensitive SUBSTRING matching (like the old
        # body: LIKE), just indexed. Query terms must be >=3 chars (QL falls back
        # to a BLOB LIKE scan below that).
        "CREATE VIRTUAL TABLE flows_fts USING fts5(req, resp, tokenize='trigram')",
        <<-SQL,
        INSERT INTO flows_fts(rowid, req, resp)
        SELECT id,
               substr(CAST(request_body AS TEXT), 1, 65536),
               substr(CAST(response_body AS TEXT), 1, 65536)
        FROM flows
        SQL
      ]

      # Replay workbench tabs, persisted so they survive a reopen AND sync across
      # sessions sharing the project (the TUI reconciles by `id` on the
      # data_version poll). The editable request is stored here; the last send
      # response is added in V11 (scroll + focus stay transient). `flow_id` is the
      # source History flow for a `^R`-opened tab (NULL for a hand-authored `^N`).
      V9 = [
        <<-SQL,
        CREATE TABLE replays (
          id                  INTEGER PRIMARY KEY,
          created_at          INTEGER NOT NULL,
          updated_at          INTEGER NOT NULL,
          target              TEXT    NOT NULL,
          request             TEXT    NOT NULL,
          http2               INTEGER NOT NULL DEFAULT 0,
          auto_content_length INTEGER NOT NULL DEFAULT 1,
          flow_id             INTEGER,
          position            INTEGER NOT NULL DEFAULT 0
        )
        SQL
        "CREATE INDEX idx_replays_position ON replays (position, id)",
      ]

      # Sitemap index: `SELECT DISTINCT host, method, target ... ORDER BY host,
      # target` is the Sitemap tab's query (re-run on tab-enter AND the live poll).
      # Without an index it full-scans + sorts every flow — ~25ms at 100k rows. This
      # covering index lets SQLite walk it in order and emit distinct endpoints
      # directly (~1.8ms at 100k, verified).
      V10 = [
        "CREATE INDEX idx_flows_sitemap ON flows (host, target, method)",
      ]

      # Persist a replay tab's LAST send result so it survives a reopen (and shows
      # on a fresh open) instead of starting empty. Full bytes (head + body, like
      # the captured-flow BLOBs); `response_error` + `response_duration_us` let
      # restore() rebuild the Replay::Result faithfully — including an errored send.
      # All NULL until the first send. Scroll/focus/diff-baseline stay transient.
      V11 = [
        "ALTER TABLE replays ADD COLUMN response_head BLOB",
        "ALTER TABLE replays ADD COLUMN response_body BLOB",
        "ALTER TABLE replays ADD COLUMN response_error TEXT",
        "ALTER TABLE replays ADD COLUMN response_duration_us INTEGER",
      ]

      # Findings gain a triage STATUS axis (separate from severity): open /
      # confirmed / false-positive / resolved. Additive, backfilled to 0 (Open) so
      # existing findings stay valid. Lets a false positive be a reversible state
      # instead of a delete.
      V12 = [
        "ALTER TABLE findings ADD COLUMN status INTEGER NOT NULL DEFAULT 0",
      ]

      # Scope rules gain a KIND (include/exclude) + MATCH_TYPE (host/string/regex)
      # so scope is a real include/exclude lens with substring & regex matching (not
      # just host globs). Rebuild the table to move UNIQUE onto the (kind,match_type,
      # pattern) triple (same pattern can now be both an include and an exclude, or a
      # host rule and a string rule). Pre-V13 rows were bare host include patterns →
      # migrated as include/host. INSERT OR IGNORE is defensive (old pattern was
      # already UNIQUE, so the triples can't collide). migrate! wraps this list in one
      # transaction, so the rename/insert/drop is atomic.
      V13 = [
        "ALTER TABLE scope_rules RENAME TO scope_rules_old",
        <<-SQL,
        CREATE TABLE scope_rules (
          id         INTEGER PRIMARY KEY,
          kind       TEXT NOT NULL DEFAULT 'include',
          match_type TEXT NOT NULL DEFAULT 'host',
          pattern    TEXT NOT NULL,
          UNIQUE(kind, match_type, pattern)
        )
        SQL
        "INSERT OR IGNORE INTO scope_rules (kind, match_type, pattern) SELECT 'include', 'host', pattern FROM scope_rules_old",
        "DROP TABLE scope_rules_old",
      ]

      # A replay tab can carry a custom NAME (the sub-tab chip label, set via rename).
      # NULL = derive the label from the request line (the default). Persisted so a
      # rename survives a reopen.
      V14 = [
        "ALTER TABLE replays ADD COLUMN name TEXT",
      ]

      # A replay tab can carry a custom SNI host — the name presented in the TLS
      # ClientHello, decoupled from the dialed target host (domain fronting / vhost
      # confusion / IP-direct sends). NULL = present the target host (the default).
      # Request-side config, so it syncs across sessions like target/request.
      V15 = [
        "ALTER TABLE replays ADD COLUMN sni TEXT",
      ]

      # Fuzzer / Intruder persistence:
      #  - fuzz_sessions: a saved template + opaque config JSON (the TUI manages its
      #    shape), mirroring `replays` so a Fuzzer tab survives reopen and syncs across
      #    sessions sharing the project (reconciled by `id` on the data_version poll).
      #  - fuzz_runs: one sweep's metadata (live counters + status), linked to a session.
      #  - fuzz_results: per-request rows (metrics + optional captured bytes for the
      #    matched/kept results), so a finished run can be reopened and inspected. The
      #    frontends persist selectively per keep_bodies (a billion-row cluster bomb is
      #    never stored whole).
      V16 = [
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
      ]

      # Sitemap path tags: a free-text memo pinned to a (host, path) node in the
      # Sitemap tree ("payment flow", "admin area"). Per-project, so it syncs across
      # sessions sharing the DB (reconciled on the data_version poll like findings).
      # UNIQUE(host, path) makes the write an upsert; an empty tag deletes the row.
      #
      # DDL defined once + IF NOT EXISTS so the V17 migration AND the version-independent
      # ensure_aux! guard create it identically. WHY the guard: this branch and the
      # hostname-overrides branch BOTH added a `V17` (sitemap_tags here, host_overrides
      # there) before either merged. A project DB advanced to user_version 17 by the OTHER
      # branch skips THIS migration (current already 17) and would never get sitemap_tags
      # — so writes fail silently. ensure_aux! repairs that on every open.
      SITEMAP_TAGS_DDL = <<-SQL
        CREATE TABLE IF NOT EXISTS sitemap_tags (
          id   INTEGER PRIMARY KEY,
          host TEXT NOT NULL,
          path TEXT NOT NULL,
          tag  TEXT NOT NULL,
          UNIQUE(host, path)
        )
        SQL

      V17 = [SITEMAP_TAGS_DDL]

      MIGRATIONS = [V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15, V16, V17]

      def self.migrate!(db : DB::Database) : Nil
        current = db.scalar("PRAGMA user_version").as(Int64).to_i
        MIGRATIONS[current..]?.try &.each_with_index(offset: current) do |statements, idx|
          db.transaction do |tx|
            conn = tx.connection
            statements.each { |sql| conn.exec(sql) }
            conn.exec("PRAGMA user_version = #{idx + 1}")
          end
        end
      end

      # Version-independent safety net for tables that may be missing because a DB was
      # advanced past their migration number by a SIBLING branch's same-numbered migration
      # (see SITEMAP_TAGS_DDL). Idempotent (IF NOT EXISTS), runs on every open after migrate!.
      def self.ensure_aux!(db : DB::Database) : Nil
        db.exec(SITEMAP_TAGS_DDL)
      end
    end
  end
end
