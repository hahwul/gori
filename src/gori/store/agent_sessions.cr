require "db"

module Gori
  class Store
    # --- agent conversations and their transcripts (V29, #1093) --------------

    # Ceiling on ONE transcript line's `text`.
    #
    # A tool result can be a whole file, a `curl` dump, a 40 MB response body the agent read
    # back — and the transcript is written straight off the backend's stdout, so nothing
    # upstream of this bounds it. Without a cap one frame can put more bytes into the project
    # database than the entire capture history beside it, and the pane that renders it has to
    # walk every one of them.
    #
    # 256 KiB is far past any line a human reads and still small enough that a runaway session
    # costs megabytes rather than gigabytes. Applied at the SINK (`insert_agent_message`), not
    # at the several producers that will feed it, for the reason `insert_event` gives about
    # level normalization: a rule enforced per-caller is a rule the next caller does not get.
    AGENT_MESSAGE_MAX_BYTES = 256 * 1024

    # Start a conversation. Returns the new row's id, or 0 when the write never committed
    # (store closing, or SQLite busy) — the caller decides what an unstartable session means.
    #
    # `session_uuid` is the uuid of the spawn that is starting NOW. It is UNIQUE, so inserting
    # a uuid this project has already seen fails the batch and answers 0 rather than quietly
    # creating a second row for one conversation; `resumed_from` is how a spawn that continues
    # an existing conversation is recorded, and that case updates the existing row instead
    # (see `update_agent_session`).
    def insert_agent_session(session_uuid : String, backend : String, model : String?,
                             title : String, resumed_from : String? = nil) : Int64
      exec_task ->(c : DB::Connection) {
        c.exec(
          "INSERT INTO agent_sessions (session_uuid, resumed_from, backend, model, title, " \
          "draft, started_at, ended_at, cost_usd, turns) VALUES (?,?,?,?,?,'',?,NULL,0,0)",
          session_uuid, resumed_from, backend, model, title, now_us)
        nil
      }
    end

    # Update only the fields that were named. Returns whether the write committed.
    #
    # Every field is separately optional because the five producers each know exactly one
    # thing: the spawn reports its uuid (and what it resumed), the first user turn decides the
    # title, a tab switch persists the draft, and the turn-done frame carries cost and turn
    # count. A whole-row update would make each of them overwrite the other four with whatever
    # they last read — and the draft is the one the operator would notice, because the value
    # being clobbered is text they typed and have not sent.
    #
    # `nil` therefore means "leave it alone", and there is deliberately no way to spell "set
    # this back to NULL": no caller wants one, and giving `model`/`resumed_from` a clearing
    # form would make every ordinary update able to erase them by omission.
    #
    # A call with nothing to update is `true` WITHOUT a write. It is the common case (a tab
    # switch on an untouched draft), and sending an empty SET to the writer fiber would put
    # every one of them in a transaction for the privilege of changing nothing.
    def update_agent_session(id : Int64, *, session_uuid : String? = nil,
                             resumed_from : String? = nil, model : String? = nil,
                             title : String? = nil, draft : String? = nil,
                             cost_usd : Float64? = nil, turns : Int32? = nil) : Bool
      sets = [] of String
      args = [] of DB::Any
      # `if v = …` is the right test for every one of these because only `nil` and `false` are
      # falsey in Crystal: `cost_usd: 0.0` and `turns: 0` — the values a conversation that has
      # not answered yet carries — are truthy and do get written. A Bool field here would need
      # `.nil?` instead (the `if b = as_bool?` trap, #1036); there is none, and adding one
      # means not extending this loop.
      {% for field in %w[session_uuid resumed_from model title draft cost_usd turns] %}
        if v = {{ field.id }}
          sets << "{{ field.id }} = ?"
          args << v
        end
      {% end %}
      return true if sets.empty?
      args << id
      sql = "UPDATE agent_sessions SET #{sets.join(", ")} WHERE id = ?"
      exec_task_ok ->(c : DB::Connection) {
        c.exec(sql, args: args)
        nil
      }
    end

    # Stamp the conversation as over. Idempotent by design — it writes `now_us` unconditionally
    # rather than only on a NULL `ended_at`, so a second call moves the stamp forward instead
    # of failing. "When did this last stop" is the question the pane asks; "when did it first
    # stop" is one nothing needs, and a conditional update would additionally have to answer
    # `false` for an already-finished session, which reads as a failed write.
    def finish_agent_session(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("UPDATE agent_sessions SET ended_at = ? WHERE id = ?", now_us, id)
        nil
      }
    end

    # Append one transcript line. Returns the new row's id, or 0 on a write that never
    # committed.
    #
    # The `truncated` ARGUMENT is what the producer already knows (a backend that told us it
    # cut a frame itself); the cap below can only ever turn it on. A caller passing `false`
    # for text this method had to cut would otherwise store a line that silently claims to be
    # whole — the report-after-the-side-effect shape (#906), where the field meant to describe
    # the write is computed before it.
    def insert_agent_message(session_id : Int64, seq : Int32, role : String, kind : String,
                             text : String, payload : String? = nil,
                             truncated : Bool = false) : Int64
      stored = text
      cut = false
      if text.bytesize > AGENT_MESSAGE_MAX_BYTES
        stored = Store.truncate_utf8(text, AGENT_MESSAGE_MAX_BYTES)
        cut = true
      end
      # The payload (a tool call's input) is bounded the same way: the wire line above it is
      # capped at a megabyte, four times this, and a row is not the place to keep the excess.
      if (pl = payload) && pl.bytesize > AGENT_MESSAGE_MAX_BYTES
        payload = Store.truncate_utf8(pl, AGENT_MESSAGE_MAX_BYTES)
        cut = true
      end
      flag = (truncated || cut) ? 1_i64 : 0_i64
      exec_task ->(c : DB::Connection) {
        c.exec(
          "INSERT INTO agent_messages (session_id, seq, role, kind, text, payload, truncated, " \
          "created_at) VALUES (?,?,?,?,?,?,?,?)",
          session_id, seq.to_i64, role, kind, stored, payload, flag, now_us)
        nil
      }
    end

    # Drop a conversation and its transcript. Messages go FIRST, in the same transaction, so a
    # partial failure can never leave transcript rows pointing at an id that is gone — and,
    # with `agent_sessions.id` AUTOINCREMENT, can never leave them to be adopted by the next
    # conversation the operator starts.
    def delete_agent_session(id : Int64) : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM agent_messages WHERE session_id = ?", id)
        c.exec("DELETE FROM agent_sessions WHERE id = ?", id)
        nil
      }
    end

    # Empty the tab. The human-facing counterpart to `trim_agent_sessions`, and unqualified on
    # purpose: an operator clearing the pane means all of it. AUTOINCREMENT keeps the high-water
    # mark in `sqlite_sequence`, so a conversation started after this can never inherit the id
    # of one that was cleared — the property `clear_events` relies on for the same reason.
    def clear_agent_sessions : Bool
      exec_task_ok ->(c : DB::Connection) {
        c.exec("DELETE FROM agent_messages")
        c.exec("DELETE FROM agent_sessions")
        nil
      }
    end

    # Cut `text` to at most `max` BYTES without splitting a UTF-8 character.
    #
    # `String#byte_slice` alone would happily cut mid-sequence, and the result is a String
    # whose bytes are not valid UTF-8 — which SQLite stores, and which then comes back out
    # through a `rs.read(String)` into a renderer that has no way to cope. Backing off the
    # continuation bytes (`10xxxxxx`) lands the cut on a boundary; the trailing `scrub` covers
    # the case where the INPUT was already invalid, which is possible here because a transcript
    # line is bytes off another process's stdout.
    def self.truncate_utf8(text : String, max : Int32) : String
      return text if text.bytesize <= max
      bytes = text.to_slice
      cut = max
      while cut > 0 && (bytes[cut] & 0xC0) == 0x80
        cut -= 1
      end
      String.new(bytes[0, cut]).scrub
    end
  end
end
