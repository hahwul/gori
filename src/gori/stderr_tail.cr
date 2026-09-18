module Gori
  # What a child process has written to stderr so far, up to a capped amount. Readable at
  # any moment rather than only at EOF — a caller that only gets to inspect the buffer on
  # failure needs whatever was captured by then, because EOF may never arrive (a browser
  # that lives past its launch window) or arrive too late to matter (an agent child killed
  # by `stop`). Two callers share this shape today: `Browser` tails a launched browser's
  # stderr for the line that explains a refusal, and the agent child process (`claude -p`)
  # tails its stderr the same way.
  class StderrTail
    def initialize(@cap : Int32)
      @buf = IO::Memory.new
      @mutex = Mutex.new
    end

    # Past the cap we keep reading and discard — a long-lived child narrates warnings for
    # as long as it runs, and this buffer outlives whatever grace window the caller gives
    # it. One write can overshoot the cap: the rule is "keep writing while bytesize < cap",
    # not "truncate to cap", so the last write before the cap trips can land partially over
    # it.
    def <<(bytes : Bytes) : Nil
      @mutex.synchronize { @buf.write(bytes) if @buf.bytesize < @cap }
    end

    def text : String
      @mutex.synchronize { @buf.to_s }
    end

    def bytesize : Int32
      @mutex.synchronize { @buf.bytesize }
    end

    def empty? : Bool
      @mutex.synchronize { @buf.bytesize == 0 }
    end
  end
end
