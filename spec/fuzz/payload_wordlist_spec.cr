require "../spec_helper"
require "file_utils"

# Fix #24 — `gori run fuzz -w <path>` must surface a missing / unusable wordlist as a
# clean Gori::Error (→ "gori run fuzz: wordlist …"), not a raw File::NotFoundError
# backtrace leaking out of File.each_line / File.open.
describe Gori::Fuzz::WordlistFile do
  it "raises a clean Gori::Error for a missing wordlist path (not a raw File error)" do
    wl = Gori::Fuzz::WordlistFile.new("/no/such/gori-wordlist-#{Random::Secure.hex(4)}.txt")
    expect_raises(Gori::Error, /wordlist not found/) { wl.size }          # preflight open-check path
    expect_raises(Gori::Error, /wordlist not found/) { wl.open_iterator } # run-time cursor path
  end

  it "rejects a directory given as a wordlist" do
    dir = File.tempname("gori-wl-dir")
    Dir.mkdir_p(dir)
    begin
      wl = Gori::Fuzz::WordlistFile.new(dir)
      expect_raises(Gori::Error, /directory/) { wl.size }
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  it "counts and iterates a real wordlist unchanged" do
    path = File.tempname("gori-wl")
    File.write(path, "alpha\nbeta\ngamma\n")
    begin
      wl = Gori::Fuzz::WordlistFile.new(path)
      wl.size.should eq(3_i64)
      it = wl.open_iterator
      values = [it.next_value, it.next_value, it.next_value, it.next_value]
      values.should eq(["alpha", "beta", "gamma", nil])
      it.close
    ensure
      File.delete(path) rescue nil
    end
  end
end

# A ONE-SHOT wordlist path (`-w /dev/stdin`, a pipe, a FIFO) must be consumed at most
# once. The lazy source used to open it twice — `size` (the preflight `· N requests ·`)
# drained the stream and the send pass then read an empty one, so the run printed N and
# put ZERO payloads on the wire, exit 0; a FIFO whose writer had already left blocked
# forever on the second open instead.
# Guard: on the old code the second `File.open` never returns, so a plain call here
# would wedge the suite rather than fail it.
private def collect_within(wl, seconds) : Array(String)?
  ch = Channel(Array(String)).new(1)
  spawn do
    values = [] of String
    it = wl.open_iterator
    begin
      while v = it.next_value
        values << v
      end
    ensure
      it.close
    end
    ch.send(values)
  end
  select
  when got = ch.receive
    got
  when timeout(seconds.seconds)
    nil
  end
end

describe Gori::Fuzz::WordlistFile do
  it "counts and iterates a FIFO whose writer has already exited (one read, no hang)" do
    path = File.tempname("gori-wl-fifo")
    Process.run("mkfifo", [path]).success?.should be_true
    begin
      spawn { File.open(path, "w") { |f| f.puts("alpha"); f.puts("beta"); f.puts("gamma") } }
      wl = Gori::Fuzz::WordlistFile.new(path)
      wl.size.should eq(3_i64)
      collect_within(wl, 5).should eq(["alpha", "beta", "gamma"])
    ensure
      File.delete(path) rescue nil
    end
  end

  # macOS resolves `/dev/stdin` to `/dev/fd/N`, which reports type File yet DUPS the
  # descriptor: both opens share one offset, so even `-w /dev/stdin < wordlist.txt` was
  # counted and then read empty. `/dev/fd/N` reproduces that without touching real stdin.
  it "agrees between size and iteration on a /dev/fd path" do
    path = File.tempname("gori-wl-fd")
    File.write(path, "alpha\nbeta\ngamma\n")
    begin
      File.open(path) do |f|
        wl = Gori::Fuzz::WordlistFile.new("/dev/fd/#{f.fd}")
        wl.size.should eq(3_i64)
        collect_within(wl, 5).should eq(["alpha", "beta", "gamma"])
      end
    ensure
      File.delete(path) rescue nil
    end
  end

  # …and a plain seekable wordlist keeps the lazy two-pass: counting a multi-GB file
  # without materializing it is the whole point, so the cursor must still re-read the
  # path rather than replay an Array captured at count time.
  it "does not materialize a regular wordlist file" do
    path = File.tempname("gori-wl-lazy")
    File.write(path, "alpha\nbeta\n")
    begin
      wl = Gori::Fuzz::WordlistFile.new(path)
      wl.size.should eq(2_i64)
      File.write(path, "alpha\nbeta\ngamma\n")
      values = [] of String
      wl.each { |v| values << v }
      values.should eq(["alpha", "beta", "gamma"])
    ensure
      File.delete(path) rescue nil
    end
  end
end
