require "../../spec_helper"

private alias Pool = Gori::Proxy::CopyBufPool

describe Gori::Proxy::CopyBufPool do
  it "lends a full-size buffer and takes it back for the next borrower" do
    first = Pool.lend { |b| b.size.should eq(Gori::Proxy::Codec::Body::BUFSIZE); b.to_unsafe }
    again = Pool.lend(&.to_unsafe)
    again.should eq(first) # the same block, not a fresh allocation
  end

  it "takes the buffer back when the block raises" do
    before = Pool.lend { Pool.idle_count } # drain-and-return: whatever sits idle outside a borrow
    expect_raises(IO::Error) { Pool.lend { raise IO::Error.new("peer reset") } }
    Pool.idle_count.should eq(before + 1)
  end

  it "never lends one buffer to two borrowers at once, across fibers" do
    held = Channel(Pointer(UInt8)).new
    release = Channel(Nil).new
    done = Channel(Nil).new
    spawn do
      Pool.lend do |b|
        held.send(b.to_unsafe)
        release.receive # still inside the borrow while the other fiber asks
      end
      done.send(nil)
    end
    theirs = held.receive
    mine = Pool.lend(&.to_unsafe)
    mine.should_not eq(theirs)
    release.send(nil)
    done.receive
  end

  it "keeps at most MAX_IDLE buffers idle after a burst" do
    depth = Pool::MAX_IDLE + 8
    nest = uninitialized Proc(Int32, Nil)
    nest = ->(n : Int32) { n == 0 ? nil : Pool.lend { nest.call(n - 1) } }
    nest.call(depth) # `depth` buffers out at once, returned as the borrows unwind
    Pool.idle_count.should eq(Pool::MAX_IDLE)
  end
end
