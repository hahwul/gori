require "db"

module Gori
  class Store
    # Tiny `PRAGMA user_version` migration runner. Each entry in MIGRATIONS is a
    # list of statements taking the DB from version N to N+1. New subsystems
    # (FTS5 for QL, a tags table, a connections table) arrive as *later*
    # migrations — which is exactly why none of them exist in v1 (P0).
    module Schema
      VERSION = 8

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
        "CREATE VIRTUAL TABLE flows_fts USING fts5(req, resp)",
        <<-SQL,
        INSERT INTO flows_fts(rowid, req, resp)
        SELECT id,
               substr(CAST(request_body AS TEXT), 1, 65536),
               substr(CAST(response_body AS TEXT), 1, 65536)
        FROM flows
        SQL
      ]

      MIGRATIONS = [V1, V2, V3, V4, V5, V6, V7, V8]

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
