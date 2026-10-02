require "./jobs"

module Gori::Tui
  # Ring buffer of recent notifications (background-job results, alerts). Same
  # single-fiber invariant as Jobs — written only by controller drains on the main
  # fiber, no locks. Ephemeral per open project.
  class Notifications
    CAP = 100

    # A CLASS not a record: `read` flips via mark_read (a struct fetched from the array
    # would mutate a copy and lose it).
    class Note
      getter id : Int32
      getter level : Symbol # :info | :success | :warn | :error
      getter message : String
      getter created_at : Time::Instant
      getter goto : Jobs::Goto?
      # Who produced this note: "app" (default), "miner"/"fuzzer"/"probe" (background
      # engines), or "agent"/"agent:<name>" (an MCP co-pilot — rendered distinctly so the
      # human can see what the AI did). A String (not a Symbol like `level`) to carry the
      # open-ended agent:<name> form. (#124)
      getter source : String
      # The LONG form, when the producer had one (#1090). `message` is the one line the ring
      # row and Miss Ring's bubble show; this is what the operator opens to read — an agent's
      # reply body, the paragraph a one-line summary had to drop. nil for every note that is
      # only its summary, which is most of them, and the ring row says which is which.
      getter detail : String?
      # Written TO the operator rather than about something that happened: an agent's
      # `reply_to_operator` answer. Miss Ring holds these in her bubble until the next key or
      # click (Settings.companion_holds_replies?) instead of letting them go with the usual
      # few-second TTL. Not the same as `agent?`: the intercept bridge pushes `source: "agent"`
      # notes too, and "the agent forwarded #3" is a report, not something said to anyone.
      getter? addressed : Bool
      property read : Bool
      # The feed id of the `ask_operator` question this note announced (#1324), or nil for
      # every other note. ↵ on the row opens the answer card while `question_open?` holds.
      getter question_id : Int64?
      # How the question ended, once it has: `:answered`, `:dismissed`, `:expired`, or `:closed`
      # (another window answered it). nil while it is still open. Mutable because the note is announced before the answer exists, and the ring row
      # has to stop offering a card the moment another window or the expiry closes it.
      property question_state : Symbol?

      def initialize(@id, @level, @message, @goto = nil, @source = "app", @detail = nil,
                     @addressed = false, @question_id = nil)
        @created_at = Time.instant
        @read = false
        @question_state = nil
      end

      # A question that can still be answered from this note.
      def question_open? : Bool
        !@question_id.nil? && @question_state.nil?
      end

      # AI/agent-originated notes get a distinct marker in the overlay.
      def agent? : Bool
        @source.starts_with?("agent")
      end
    end

    def initialize
      @notes = [] of Note
      @next_id = 0
    end

    # `detail` is a TRAILING keyword with a default, so the ~200 pushes that only have a
    # summary keep compiling untouched — a note carries a long form only when its producer
    # had one to carry (see Note#detail).
    def push(level : Symbol, message : String, goto : Jobs::Goto? = nil, source : String = "app",
             detail : String? = nil, addressed : Bool = false, question_id : Int64? = nil) : Note
      n = Note.new((@next_id += 1), level, message, goto, source, detail, addressed, question_id)
      @notes << n
      # Drain to the live retention setting (CAP is the default; user may lower it).
      while @notes.size > Settings.notify_retention
        @notes.shift
      end
      # Terminal bell on non-info notes when enabled — a state-neutral `\a` tty write,
      # like the clipboard's OSC52, and to the same tty for the same reason (`TtyOut`:
      # STDOUT is not necessarily the device termisu draws on). This is the app's only
      # bell emit point.
      if Settings.notify_bell? && level != :info
        io = TtyOut.io
        io.print("\a")
        io.flush
      end
      n
    end

    # The newest note's id, or 0 when empty. O(1) and ALLOCATION-FREE — a per-tick
    # watcher (the Companion) diffs this, never `all`, which materialises a reversed copy
    # of the whole ring 20x/second. push trims with shift, so the tail is always the
    # newest; after `clear` this drops to 0, which a `id > seen` guard reads as "nothing
    # new" rather than re-announcing.
    def latest_id : Int32
      @notes.last?.try(&.id) || 0
    end

    # The newest note itself. Same reason as latest_id; read only on the tick where
    # latest_id actually moved.
    def latest : Note?
      @notes.last?
    end

    # The newest ADDRESSED note (an agent's reply) newer than `id`, or nil. For the Companion's
    # tick, which otherwise reads only `latest`: a reply and a job result that land in the
    # same tick would leave her announcing the result and the reply never said. Walks back
    # from the tail and stops at `id`, so it costs the handful of notes that just arrived.
    def latest_addressed_after(id : Int32) : Note?
      @notes.reverse_each do |n|
        break if n.id <= id
        return n if n.addressed?
      end
      nil
    end

    # Newest-first (the overlay renders top-down).
    def all : Array(Note)
      @notes.reverse
    end

    def unread : Int32
      @notes.count { |n| !n.read }
    end

    # The note that announced question `id`, while it is still in the ring.
    def for_question(id : Int64) : Note?
      @notes.find { |n| n.question_id == id }
    end

    def mark_all_read : Nil
      @notes.each(&.read=(true))
    end

    def clear : Nil
      @notes.clear
    end

    def empty? : Bool
      @notes.empty?
    end
  end
end
