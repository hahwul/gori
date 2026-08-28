require "./spec_helper"

# A tiny executable script on disk, for the paths that need a real child.
private def with_hook(body : String, &)
  dir = File.tempname("gori-hook")
  Dir.mkdir_p(dir)
  path = File.join(dir, "hook.sh")
  File.write(path, "#!/bin/sh\n#{body}\n")
  File.chmod(path, 0o755)
  begin
    yield path
  ensure
    FileUtils.rm_rf(dir)
  end
end

describe Gori::ProcessHook do
  describe ".parse_argv" do
    it "splits on whitespace and honours quotes and backslash escapes" do
      Gori::ProcessHook.parse_argv(%q{./tool --flag "a b" 'c d' e\ f})
        .should eq ["./tool", "--flag", "a b", "c d", "e f"]
    end

    it "keeps an empty quoted argument" do
      Gori::ProcessHook.parse_argv(%q{./tool "" x}).should eq ["./tool", "", "x"]
    end

    it "is NOT a shell - metacharacters are ordinary bytes in an argv element" do
      # The whole security property of invariant 3 in one example: nothing here is a pipeline, a
      # redirection, a command substitution or a glob. They are arguments.
      Gori::ProcessHook.parse_argv(%q{./tool $HOME *.txt `id` a;b c&&d > e | f})
        .should eq ["./tool", "$HOME", "*.txt", "`id`", "a;b", "c&&d", ">", "e", "|", "f"]
    end

    it "keeps a backslash inside double quotes unless it escapes a quote or a backslash" do
      # A POSIX shell does the same. Deleting it made a regex argument (`"a\d+"`) and a Windows
      # path silently different from what the operator read back in the editor.
      Gori::ProcessHook.parse_argv(%q{./tool "a\d+"}).should eq ["./tool", %q{a\d+}]
      Gori::ProcessHook.parse_argv(%q{./sign --key "C:\tools\dev.pem"})
        .should eq ["./sign", "--key", %q{C:\tools\dev.pem}]
      Gori::ProcessHook.parse_argv(%q{./tool "say \"hi\""}).should eq ["./tool", %q{say "hi"}]
      Gori::ProcessHook.parse_argv(%q{./tool "a\\b"}).should eq ["./tool", %q{a\b}]
    end

    it "reports why a spec cannot be tokenized instead of guessing" do
      Gori::ProcessHook.parse_argv(%q{./tool "oops}).should eq "unterminated double quote"
      Gori::ProcessHook.parse_argv(%q{./tool 'oops}).should eq "unterminated single quote"
      Gori::ProcessHook.parse_argv("./tool \\").should eq "trailing backslash"
      Gori::ProcessHook.parse_argv("   ").should eq "no command"
    end

    it "refuses a NUL, which execvp would silently truncate into a different command" do
      Gori::ProcessHook.parse_argv("./tool a\u0000b").should eq "argument contains a NUL byte"
    end
  end

  describe ".run" do
    it "pipes stdin through the command and returns its stdout verbatim" do
      res = Gori::ProcessHook.run(["/bin/cat"], "hello".to_slice)
      res.ok?.should be_true
      String.new(res.stdout).should eq "hello"
      res.failure.should be_nil
    end

    it "passes binary through untouched (P7 - no re-encoding around the hook)" do
      raw = Bytes[0x00, 0xff, 0xfe, 0x41, 0x0a, 0x80]
      res = Gori::ProcessHook.run(["/bin/cat"], raw)
      res.ok?.should be_true
      res.stdout.should eq raw
    end

    it "exec's argv directly - an argument that looks like a shell pipeline is just an argument" do
      with_hook(%q{printf '%s' "$1"}) do |path|
        res = Gori::ProcessHook.run([path, "; rm -rf /nope"], Bytes.empty)
        res.ok?.should be_true
        String.new(res.stdout).should eq "; rm -rf /nope"
      end
    end

    it "hands the given env to the child, on top of the inherited one" do
      with_hook(%q{printf '%s' "$GORI_HOOK"}) do |path|
        res = Gori::ProcessHook.run([path], Bytes.empty, env: {"GORI_HOOK" => "spec"})
        String.new(res.stdout).should eq "spec"
      end
    end

    # --- the three failure paths P6 turns on ------------------------------------------------

    it "reports a NON-ZERO EXIT as not-ok, with the reason and the child's stderr" do
      with_hook("echo 'went wrong' >&2; exit 3") do |path|
        res = Gori::ProcessHook.run([path], Bytes.empty)
        res.ok?.should be_false
        res.status.should eq 3
        res.timed_out.should be_false
        res.failure.not_nil!.should contain "exited 3"
        res.failure.not_nil!.should contain "went wrong"
      end
    end

    it "TIMES OUT and returns within the budget rather than waiting on the child" do
      started = Time.instant
      res = Gori::ProcessHook.run(["/bin/sleep", "30"], Bytes.empty, 400.milliseconds)
      elapsed = Time.instant - started
      res.ok?.should be_false
      res.timed_out.should be_true
      res.failure.not_nil!.should contain "timed out"
      # The whole P6 contract in one assertion: bounded by the timeout plus the graces, not by
      # how long the child felt like running.
      elapsed.should be < (400.milliseconds + Gori::ProcessHook::KILL_GRACE +
                           Gori::ProcessHook::COLLECT_GRACE * 2)
    end

    it "reports a SPAWN FAILURE instead of raising it onto the data path" do
      res = Gori::ProcessHook.run(["/nonexistent/gori-hook-spec"], Bytes.empty)
      res.ok?.should be_false
      res.spawn_error.should_not be_nil
      res.failure.not_nil!.should contain "/nonexistent/gori-hook-spec"
    end

    it "treats OVERSIZED OUTPUT as a failure rather than handing back a truncated body" do
      # `yes` is unbounded; the cap has to stop it, and half a body is corruption, not output.
      res = Gori::ProcessHook.run(["/bin/sh", "-c", "yes gorigorigorigorigorigori"],
        Bytes.empty, 30.seconds)
      res.ok?.should be_false
      res.truncated.should be_true
      res.stdout.size.should be <= Gori::ProcessHook::MAX_OUTPUT
      res.failure.not_nil!.should contain "stdout"
    end

    it "survives a hook that never reads its stdin" do
      with_hook("printf 'ignored'") do |path|
        res = Gori::ProcessHook.run([path], Bytes.new(4 * 1024 * 1024, 0x41_u8))
        res.ok?.should be_true
        String.new(res.stdout).should eq "ignored"
      end
    end

    it "names the command in a notice by argv[0] alone, never by its arguments" do
      # An argument can carry a captured token; an event row is read back by agents.
      res = Gori::ProcessHook.run(["/nonexistent/gori-hook-spec", "eyJhbGciOi-secret"], Bytes.empty)
      res.failure.not_nil!.should_not contain "secret"
    end
  end
end
