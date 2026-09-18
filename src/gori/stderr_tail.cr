# STUB — replaced by the real file lifted out of browser.cr in feat/agent-tab-core; do not merge this version
module Gori
  class StderrTail
    def initialize(@cap : Int32)
      @buf = IO::Memory.new
      @mutex = Mutex.new
    end

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
      bytesize == 0
    end
  end
end
