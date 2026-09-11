require "./spec_helper"

# `Gori::TtyPath.terminal?` — the shared answer to "does this operator-supplied PATH name a
# terminal?", asked by the three wordlist loaders and by the CLI's file reader before they
# read a path they were handed (#1034). A terminal never ends, echoes every byte typed into
# the scrollback, and flushes rather than EOFs on `^D`, so `--wordlist /dev/tty` hung outright.
describe Gori::TtyPath do
  describe ".terminal?" do
    it "is false for a regular file — the ordinary wordlist and request path" do
      path = File.tempname("gori-tty", ".txt")
      begin
        File.write(path, "a\nb\n")
        Gori::TtyPath.terminal?(path).should be_false
      ensure
        File.delete?(path)
      end
    end

    # The reason for the `character_device?` pre-check, and the case that must never be
    # OPENED to be answered: opening a FIFO for reading BLOCKS until a writer arrives, and a
    # readability probe that waits on one has broken the very source the lazy wordlist reader
    # exists to serve. `mkfifo` and then ask with no writer anywhere — the answer has to come
    # back immediately.
    it "is false for a FIFO, and answers without opening it" do
      dir = File.tempname("gori-fifo")
      Dir.mkdir_p(dir)
      path = File.join(dir, "wl")
      begin
        Process.run("mkfifo", [path])
        pending! "mkfifo unavailable" unless File.exists?(path)
        File.info(path).type.pipe?.should be_true
        done = Channel(Bool).new
        spawn { done.send(Gori::TtyPath.terminal?(path)) }
        select
        when answer = done.receive
          answer.should be_false
        when timeout(2.seconds)
          fail "terminal? blocked on a FIFO with no writer — the pre-check did not hold"
        end
      ensure
        File.delete?(path)
        Dir.delete(dir) if Dir.exists?(dir)
      end
    end

    it "is false for a path that does not exist, and for a directory" do
      Gori::TtyPath.terminal?(File.join(Dir.tempdir, "gori-nope-#{Random.rand(1_000_000)}"))
        .should be_false
      Gori::TtyPath.terminal?(Dir.tempdir).should be_false
    end

    # A character device that is NOT a terminal still has to come back false, or `/dev/null`
    # (a legitimate empty wordlist) would be refused.
    it "is false for a character device that is not a terminal" do
      pending! "no /dev/null on this box" unless File.exists?("/dev/null")
      File.info("/dev/null").type.character_device?.should be_true
      Gori::TtyPath.terminal?("/dev/null").should be_false
    end

    # And true for a real one. `/dev/ptmx` allocates a pty master, for which `isatty(3)` is
    # true on both Linux and Darwin — the same probe `stdin_terminal_spec.cr` uses.
    it "is true for a terminal" do
      probe = File.open("/dev/ptmx", "r+") rescue nil
      pending! "no usable /dev/ptmx on this box" if probe.nil?
      tty = probe.not_nil!.tty?
      probe.not_nil!.close
      pending! "/dev/ptmx is not a tty on this box" unless tty
      Gori::TtyPath.terminal?("/dev/ptmx").should be_true
    end
  end
end
