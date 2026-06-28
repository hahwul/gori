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
      property read : Bool

      def initialize(@id, @level, @message, @goto = nil)
        @created_at = Time.instant
        @read = false
      end
    end

    def initialize
      @notes = [] of Note
      @next_id = 0
    end

    def push(level : Symbol, message : String, goto : Jobs::Goto? = nil) : Note
      n = Note.new((@next_id += 1), level, message, goto)
      @notes << n
      @notes.shift if @notes.size > CAP
      n
    end

    # Newest-first (the overlay renders top-down).
    def all : Array(Note)
      @notes.reverse
    end

    def recent(limit : Int32) : Array(Note)
      all.first({limit, 0}.max)
    end

    def unread : Int32
      @notes.count { |n| !n.read }
    end

    def mark_read(id : Int32) : Nil
      @notes.find { |n| n.id == id }.try(&.read=(true))
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
