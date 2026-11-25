require "termisu"

# A Termisu that replays a script instead of reading a tty, for driving a screen that runs its
# OWN event loop (the project picker, the setup wizard) through that loop. Build it with
# `allocate`: a real one needs a terminal, so no initializer runs, and the script is therefore
# class-level. Pair it with a MemoryBackend, since drawing through Termisu itself needs the tty.
class ScriptedTerminal < Termisu
  alias Step = Termisu::Event::Any | Proc(Nil)

  @@script = Deque(Step).new
  @@exit = [] of Termisu::Event::Any
  @@idle = 0

  # `exit` is what the loop gets once the script runs out, cycled, until it returns: the
  # screen's own way out.
  def self.load(steps : Array(Step), exit : Array(Termisu::Event::Any)) : Nil
    @@script = Deque(Step).new(steps)
    @@exit = exit
    @@idle = 0
  end

  def size : {Int32, Int32}
    {120, 34}
  end

  def set_cursor(x : Int32, y : Int32, visible : Bool? = true, blink : Bool? = nil,
                 shape : Terminal::Cursor::Shape? = nil)
  end

  def hide_cursor
  end

  # The script first (a Proc step records state and moves on), then the way out.
  def poll_event(timeout_ms : Int32) : Termisu::Event::Any?
    while step = @@script.shift?
      return step if step.is_a?(Termisu::Event::Any)
      step.call
    end
    @@idle += 1
    raise "the screen never returned" if @@idle > 50
    @@exit[(@@idle - 1) % @@exit.size]
  end
end
