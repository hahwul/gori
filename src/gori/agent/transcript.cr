require "json"
require "./event"

module Gori::Agent
  # One row of a conversation, as the tab draws it and the store keeps it (#1093).
  #
  # `role`/`kind` are the free strings the `agent_messages` table stores — `user|assistant|
  # tool|system` × `text|thinking|tool_use|tool_result|permission|result|error|raw` — rather
  # than enums, because the table is the contract and a reader of an older gori must be able
  # to show a kind it does not know as its `text`. `seq` is the position in the conversation
  # and the key the fold state and the store row share.
  struct Message
    getter seq : Int32
    getter role : String
    getter kind : String
    getter text : String
    getter payload : String?
    getter? truncated : Bool
    getter created_at : Int64
    getter tool_name : String?
    getter tool_use_id : String?
    getter? is_error : Bool

    def initialize(@seq : Int32, @role : String, @kind : String, @text : String, *,
                   @payload : String? = nil, @truncated : Bool = false, @created_at : Int64 = 0,
                   @tool_name : String? = nil, @tool_use_id : String? = nil, @is_error : Bool = false)
    end
  end

  # The conversation as DISPLAY LINES, kept incrementally (#1093). Pure: no Process, no
  # Store, no Tui — `Session` appends to it, `AgentView` reads `size`/`line_at` through a
  # `ReadPane`, and each is spec'd alone.
  #
  # Two halves. `stable` is every finished message flattened to logical lines and appended
  # once; `tail` is the ONE in-flight assistant block, re-split on every streamed delta.
  # A delta therefore costs the tail, never the document — a 10k-line transcript does not
  # re-flatten because the model typed a word. `version` moves on any change the pane must
  # notice, and the view re-points its source when it sees a new number: one `source` call
  # per frame at most, which is the cost `ReadPane` documents as the trap.
  #
  # Tool calls FOLD. A `tool_use` and the `tool_result` that answers it draw as one line each
  # by default (`▸ Bash(git status)` / `  ✓ 12 lines`); expanding the call (keyed by its
  # tool_use_id, so both halves open together) shows the input and the output, capped. The
  # transcript is the operator's view of what the agent DID, and a page of `ls` output between
  # every two sentences buries that.
  class Transcript
    # Bytes of `text` one message may carry. The same order as `Store::AGENT_MESSAGE_MAX_BYTES`
    # so a row that was cut here is cut the same way on disk; the wire line itself is capped
    # earlier, by `Session::MAX_LINE`.
    MAX_MESSAGE_BYTES = 256 * 1024

    # Messages kept in memory. Past this the OLDEST go — they are still in the store and
    # reachable through the history picker; the live pane is for the conversation's present.
    MAX_MESSAGES = 2000

    # Lines an expanded tool input/output may occupy before an elision line.
    EXPANDED_LINE_CAP = 200

    # Columns of a folded call's argument preview.
    PREVIEW_COLS = 72

    getter messages : Array(Message)
    getter version : Int32
    # The streamed-but-unfinished assistant text; empty between blocks.
    getter tail : String

    def initialize
      @messages = [] of Message
      @stable = [] of String
      @tail = ""
      @tail_lines = [] of String
      @expanded = Set(String).new
      @version = 0
      @next_seq = 0
    end

    def next_seq : Int32
      @next_seq
    end

    # Append a finished message. `text` is cut to MAX_MESSAGE_BYTES on a character boundary
    # and the message marked `truncated` — the wire had more, the row says so.
    def append(role : String, kind : String, text : String, *, payload : String? = nil,
               created_at : Int64 = 0, tool_name : String? = nil, tool_use_id : String? = nil,
               is_error : Bool = false, truncated : Bool = false) : Message
      text, cut = Transcript.cap(text, MAX_MESSAGE_BYTES)
      msg = Message.new(@next_seq, role, kind, text, payload: payload, truncated: truncated || cut,
        created_at: created_at, tool_name: tool_name, tool_use_id: tool_use_id, is_error: is_error)
      @next_seq += 1
      @messages << msg
      @stable.concat(lines_of(msg))
      if @messages.size > MAX_MESSAGES
        @messages.shift(@messages.size - MAX_MESSAGES)
        rebuild
      end
      clear_tail
      bump
      msg
    end

    # Load rows read back from the store (history, or the live session's earlier turns).
    def load(rows : Array(Message)) : Nil
      @messages = rows.dup
      @next_seq = (rows.last?.try(&.seq) || -1) + 1
      rebuild
      bump
    end

    # A streamed delta: extends the in-flight block only.
    def push_delta(text : String) : Nil
      return if text.empty?
      # Capped like a finished message, and split INCREMENTALLY: only the last line can grow,
      # so a long streamed answer costs one line per delta rather than the whole tail again.
      return if @tail.bytesize >= MAX_MESSAGE_BYTES
      @tail += text
      last = @tail_lines.pop? || ""
      (last + text).split('\n') { |l| @tail_lines << l }
      bump
    end

    def clear_tail : Nil
      return if @tail.empty?
      @tail = ""
      @tail_lines.clear
      bump
    end

    # ---- the pane's source -------------------------------------------------------------

    def size : Int32
      @stable.size + @tail_lines.size
    end

    def line_at(i : Int32) : String
      return @stable[i] if i < @stable.size
      @tail_lines[i - @stable.size]? || ""
    end

    def lines : Array(String)
      @stable + @tail_lines
    end

    # ---- folding -----------------------------------------------------------------------

    def expanded?(tool_use_id : String) : Bool
      @expanded.includes?(tool_use_id)
    end

    def toggle(tool_use_id : String) : Nil
      @expanded.includes?(tool_use_id) ? @expanded.delete(tool_use_id) : @expanded.add(tool_use_id)
      rebuild
      bump
    end

    # The tool call a display line belongs to, so a click or `↵` on either folded line opens
    # the pair. nil on prose.
    def tool_use_id_at(line : Int32) : String?
      return nil if line < 0 || line >= @stable.size
      at = 0
      @messages.each do |m|
        n = lines_of(m).size
        return m.tool_use_id if line < at + n && (m.kind == "tool_use" || m.kind == "tool_result")
        return nil if line < at + n
        at += n
      end
      nil
    end

    # ---- rendering ---------------------------------------------------------------------

    # The logical lines one message occupies. Public so the view's colouring can ask the
    # same function what a line's role is.
    def lines_of(m : Message) : Array(String)
      case m.kind
      when "text"        then m.role == "user" ? prefix_lines(m.text, "› ", "  ") : plain_lines(m.text)
      when "thinking"    then [] of String
      when "tool_use"    then tool_use_lines(m)
      when "tool_result" then tool_result_lines(m)
      when "permission"  then ["⚑ #{m.text}"]
      when "result"      then [""] # a turn boundary: one blank line, so turns read as paragraphs
      when "error"       then prefix_lines(m.text, "! ", "  ")
      when "raw"         then prefix_lines(m.text, "? ", "  ")
      else                    plain_lines(m.text)
      end
    end

    private def tool_use_lines(m : Message) : Array(String)
      name = m.tool_name || "tool"
      if (id = m.tool_use_id) && @expanded.includes?(id)
        ["▾ #{name}"] + indent_capped(pretty(m.payload || "{}"))
      else
        ["▸ #{name}(#{Transcript.preview(name, m.payload)})"]
      end
    end

    private def tool_result_lines(m : Message) : Array(String)
      body = m.text
      n = body.empty? ? 0 : body.count('\n') + 1
      count = "#{n} line#{n == 1 ? "" : "s"}"
      cut = m.truncated? ? " (cut)" : ""
      mark = m.is_error? ? "✗" : "✓"
      if (id = m.tool_use_id) && @expanded.includes?(id)
        ["  #{mark} #{m.is_error? ? "error" : "ok"} · #{count}#{cut}"] + indent_capped(plain_lines(body))
      elsif m.is_error?
        ["  #{mark} error: #{Transcript.first_line(body)}#{cut}"]
      else
        ["  #{mark} #{count}#{cut}"]
      end
    end

    # A one-line argument preview for a folded call: the field a human would name it by
    # (`command` for Bash, `file_path` for the file tools, `pattern` for Grep), else the
    # compact JSON. Cut to PREVIEW_COLS characters.
    def self.preview(name : String, payload : String?) : String
      return "" unless payload
      s = (preview_field(payload) || payload).gsub('\n', "⏎")
      s.size > PREVIEW_COLS ? s[0, PREVIEW_COLS - 1] + "…" : s
    end

    PREVIEW_FIELDS = %w[command file_path pattern query url path description]

    private def self.preview_field(payload : String) : String?
      h = JSON.parse(payload).as_h?
      return nil unless h
      PREVIEW_FIELDS.each { |k| (v = h[k]?.try(&.as_s?)) && return v }
      nil
    rescue JSON::ParseException
      nil
    end

    def self.first_line(s : String) : String
      s.each_line.first? || ""
    end

    # Cut `s` to at most `max` BYTES on a character boundary. {text, cut?}.
    def self.cap(s : String, max : Int32) : {String, Bool}
      return {s, false} if s.bytesize <= max
      {String.new(s.to_slice[0, max]).scrub.rchop('�'), true}
    end

    private def plain_lines(text : String) : Array(String)
      text.empty? ? [] of String : text.split('\n')
    end

    private def prefix_lines(text : String, first : String, rest : String) : Array(String)
      return [first.rstrip] if text.empty?
      text.split('\n').map_with_index { |l, i| (i == 0 ? first : rest) + l }
    end

    private def indent_capped(body : Array(String)) : Array(String)
      shown = body.first(EXPANDED_LINE_CAP).map { |l| "    " + l }
      shown << "    … #{body.size - EXPANDED_LINE_CAP} more lines" if body.size > EXPANDED_LINE_CAP
      shown
    end

    private def pretty(json : String) : Array(String)
      JSON.parse(json).to_pretty_json.split('\n')
    rescue JSON::ParseException
      [json]
    end

    private def rebuild : Nil
      @stable = @messages.flat_map { |m| lines_of(m) }
    end

    private def bump : Nil
      @version &+= 1
    end
  end
end
