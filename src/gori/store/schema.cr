require "db"

module Gori
  class Store
    # Tiny `PRAGMA user_version` migration runner. Each entry in MIGRATIONS is a
    # list of statements taking the DB from version N to N+1. New subsystems
    # (FTS5 for QL, a tags table, a connections table) arrive as *later*
    # migrations — which is exactly why none of them exist in v1 (P0).
    module Schema
      VERSION = 25

      # The migration that reclaims duplicated/low-value bytes already on disk (see V25).
      # Store.open runs a one-time VACUUM after an EXISTING db crosses this version so the
      # freed pages actually shrink the file. Pin it to the exact version (not `VERSION`)
      # so a later migration doesn't re-trigger the VACUUM.
      RECLAIM_VERSION = 25

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

      # Project-level hostname overrides (a per-project /etc/hosts): map a host to the
      # IP the proxy should DIAL for it, while SNI/cert/Host header keep the original
      # host. `host` is stored lowercased and UNIQUE (one IP per host — re-adding the
      # same host is rejected; edit the row to change its IP). Read on the proxy hot
      # path (Upstream.dial) via the Mutex-guarded HostOverrides model.
      V17 = [
        <<-SQL,
        CREATE TABLE host_overrides (
          id   INTEGER PRIMARY KEY,
          host TEXT NOT NULL UNIQUE,
          ip   TEXT NOT NULL
        )
        SQL
      ]

      # Sitemap path tags: a free-text memo pinned to a (host, path) node in the Sitemap
      # tree ("payment flow", "admin area"). Per-project, so it syncs across sessions
      # sharing the DB (reconciled on the data_version poll like findings). UNIQUE(host,
      # path) makes the write an upsert; an empty tag deletes the row.
      V18 = [
        <<-SQL,
        CREATE TABLE sitemap_tags (
          id   INTEGER PRIMARY KEY,
          host TEXT NOT NULL,
          path TEXT NOT NULL,
          tag  TEXT NOT NULL,
          UNIQUE(host, path)
        )
        SQL
      ]

      # Param-miner sessions: a persisted mining session (sub-tab under the Miner tab).
      # Mirrors fuzz_sessions, but stores the byte-exact `request` (BLOB) to re-run rather
      # than an editable template, and there is no runs/results table — mining results stay
      # in-memory per session (like Replay responses before V11). `config` is opaque JSON
      # managed by the frontend (locations, bucket sizes, concurrency, …).
      V19 = [
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
      ]

      # Prism passive/active scan issues, GROUPED by (code, host): one row per distinct
      # issue type per host, with the affected URLs accumulated in `affected` (JSON, capped)
      # and `hit_count` counting every observation. `category` is the lens used by both the
      # Prism filter and the project-level technology summary (category='tech'). Per-project,
      # so it syncs across sessions sharing the DB (reconciled on the data_version poll, like
      # findings/sitemap_tags). The Prism MODE itself lives in the generic `settings` table
      # (key "prism_mode"), not here.
      V20 = [
        <<-SQL,
        CREATE TABLE prism_issues (
          id             INTEGER PRIMARY KEY,
          code           TEXT    NOT NULL,
          category       TEXT    NOT NULL,
          host           TEXT    NOT NULL,
          title          TEXT    NOT NULL,
          severity       INTEGER NOT NULL,
          status         INTEGER NOT NULL DEFAULT 0,
          hit_count      INTEGER NOT NULL DEFAULT 1,
          affected       TEXT    NOT NULL DEFAULT '[]',
          sample_flow_id INTEGER,
          evidence       TEXT,
          first_seen     INTEGER NOT NULL,
          last_seen      INTEGER NOT NULL,
          UNIQUE(code, host)
        )
        SQL
        "CREATE INDEX idx_prism_issues_cat ON prism_issues (category, host)",
      ]

      # Cross-entity links: attach History/Replay/Fuzzer/Miner refs to a Finding or Note.
      # V21 also backfills existing findings.flow_id rows as flow links.
      V21 = [
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
        <<-SQL,
        INSERT INTO entity_links (owner_kind, owner_id, ref_kind, ref_id, created_at)
        SELECT 'finding', id, 'flow', flow_id, created_at
        FROM findings
        WHERE flow_id IS NOT NULL
        SQL
      ]

      # Replay tabs gain a per-tab MARK-transform toggle: when on, `§…§` markers in the
      # request carry inline Convert chains applied on send. Off (0) = byte-identical to
      # today, so existing rows backfill to disabled.
      V22 = [
        "ALTER TABLE replays ADD COLUMN mark_transform INTEGER NOT NULL DEFAULT 0",
      ]

      # Covering index over the two byte-size columns so the Project tab's
      # `total_size` (SUM(request_size + COALESCE(response_size,0))) and `size:`/
      # `reqsize:`/`respsize:` range filters are answered from a compact index scan
      # instead of a full-table scan. The `flows` rows carry the multi-MB req/resp
      # BLOBs inline, so a plain SUM scan pages through the ENTIRE table (~170ms /
      # 100k flows, measured); this narrow index is a few MB and scans in ~2ms.
      V23 = [
        "CREATE INDEX idx_flows_sizes ON flows (request_size, response_size)",
      ]

      # Rebuild flows_fts as a CONTENTLESS FTS5 index (content='') instead of the
      # default (which keeps a shadow %_content copy of the indexed body text). We
      # already store the raw bodies in flows.{request,response}_body, so that copy
      # was pure duplication — ~half of the FTS footprint, measured. Dropping it
      # roughly halves the index size with ZERO change to `body:` search semantics
      # (we only ever `MATCH` for rowids, never read columns back). contentless_delete=1
      # (SQLite >= 3.43; ours is 3.51) keeps prune's `DELETE ... WHERE rowid <= ?` and
      # the response-side re-index working. Contentless forbids UPDATE, so the writer
      # switched from `UPDATE flows_fts SET resp` to DELETE + re-INSERT (see update_one).
      # Backfill re-indexes every surviving row from the raw bodies (bounded by retention).
      V24 = [
        "DROP TABLE flows_fts",
        "CREATE VIRTUAL TABLE flows_fts USING fts5(req, resp, content='', contentless_delete=1, tokenize='trigram')",
        <<-SQL,
        INSERT INTO flows_fts(rowid, req, resp)
        SELECT id,
               substr(CAST(request_body AS TEXT), 1, 65536),
               substr(CAST(response_body AS TEXT), 1, 65536)
        FROM flows
        SQL
      ]

      # Reclaim the single biggest source of on-disk bloat: h2 DATA frames (type 0) stored
      # their payload in full even though the SAME bytes already live in flows.request_body/
      # response_body. In one real capture this raw-frame duplication was ~44% of the whole
      # DB. The frame-log detail view only ever renders the `length` column, never the
      # payload, so empty every historical DATA payload while leaving `length` (already the
      # true byte count) untouched. NEW inserts already store empty DATA payloads — see
      # Store#insert_h2_frame_one. Freed pages are returned to the OS by the one-time VACUUM
      # in Store.open (see RECLAIM_VERSION).
      #
      # NOTE: flows_fts is deliberately NOT rebuilt here. Its bloat comes from trigram-
      # indexing COMPRESSED text bodies (high-entropy → trigram explosion), which the write
      # path now skips going forward (Store#content_encoded?/#binary_content?). It can't be
      # reclaimed cheaply in place: flows_fts is contentless, so DELETE only adds tombstones
      # (grows it), and a SQL rebuild via CAST(body AS TEXT) truncates at the first NUL byte
      # — silently dropping search coverage the runtime (String.new) had indexed. So the
      # existing index is left to shrink naturally via retention rather than risk a lossy
      # auto-rebuild on everyone's data.
      V25 = [
        "UPDATE h2_frames SET payload = X'' WHERE type = 0",
      ]

      MIGRATIONS = [V1, V2, V3, V4, V5, V6, V7, V8, V9, V10, V11, V12, V13, V14, V15, V16, V17, V18, V19, V20, V21, V22, V23, V24, V25]

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
    end
  end
end
