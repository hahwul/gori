require "../spec_helper"

# A fake `claude -p --input-format stream-json --output-format stream-json`, for driving
# `Agent::Session` specs without a real API key, network access, or the real CLI installed.
# Four `kind`s cover the shapes a real run can take: a normal turn/result exchange that
# replays a recorded fixture (`:replay`), a child that never answers a turn (`:hang`,
# proving `stop` doesn't block on it), one that dies before producing any output
# (`:crash`), and one that swallows a turn silently (`:silent_exit`, a child that dies
# mid-turn without a `result` frame).
module FakeClaude
  # Yields the path of an executable shell script that imitates `claude -p --input-format
  # stream-json --output-format stream-json`. Removed after the block.
  def self.with_script(kind : Symbol, fixture : String? = nil, & : String -> Nil) : Nil
    dir = File.tempname("fake-claude")
    Dir.mkdir_p(dir)
    path = File.join(dir, "claude.sh")
    File.write(path, script_for(kind, fixture))
    File.chmod(path, 0o755)
    begin
      yield path
    ensure
      FileUtils.rm_rf(dir)
    end
  end

  private def self.script_for(kind : Symbol, fixture : String?) : String
    case kind
    when :replay
      raise ArgumentError.new("FakeClaude: :replay needs a fixture path") unless fixture
      replay_script(fixture)
    when :hang
      HANG_SCRIPT
    when :crash
      CRASH_SCRIPT
    when :silent_exit
      SILENT_EXIT_SCRIPT
    else
      raise ArgumentError.new("FakeClaude: unknown kind #{kind}")
    end
  end

  # One user turn on stdin replays fixture lines from the last printed position through
  # the next "type":"result" frame (real Claude Code re-emits a fresh "system"/"init" frame
  # per turn, and ends every turn with exactly one "result" frame — the boundary this
  # slices on). A "type":"control_request" frame — a permission prompt — is printed, then
  # the script blocks on ONE more stdin line (the matching control_response) before
  # continuing, exactly like the real CLI waiting on a permission decision. When stdin
  # still has a line but the fixture has no more turns, it exits clean rather than hanging.
  private def self.replay_script(fixture : String) : String
    <<-SH
      #!/bin/sh
      trap 'exit 143' TERM

      fixture="#{fixture}"
      pos=0

      while :; do
        IFS= read -r _user_turn || exit 0

        next_result=$(awk -v start="$((pos + 1))" \\
          'NR >= start && /"type":"result"/ { print NR; exit }' "$fixture")
        [ -z "$next_result" ] && exit 0

        i=$((pos + 1))
        while [ "$i" -le "$next_result" ]; do
          line=$(sed -n "${i}p" "$fixture")
          printf '%s\\n' "$line"
          case "$line" in
            *'"type":"control_request"'*)
              IFS= read -r _ctrl_response || exit 0
              ;;
          esac
          i=$((i + 1))
        done

        pos=$next_result
      done
      SH
  end

  # Reads one stdin turn, then blocks forever — proving `Session#stop` doesn't wait on a
  # child that refuses to exit. `sleep` is backgrounded and reaped explicitly on TERM: a
  # foregrounded `wait` is what keeps the trap responsive instead of queued behind the
  # child, and killing the child ourselves avoids orphaning it once the script exits.
  HANG_SCRIPT = <<-SH
    #!/bin/sh
    trap 'kill "$child" 2>/dev/null; exit 143' TERM
    IFS= read -r _user_turn
    sleep 300 &
    child=$!
    wait "$child"
    SH

  # Dies before reading anything — the child that never really started.
  CRASH_SCRIPT = <<-SH
    #!/bin/sh
    echo "fake claude: boom" >&2
    exit 1
    SH

  # Reads one turn and exits clean without ever emitting a "result" frame — a child that
  # died mid-turn.
  SILENT_EXIT_SCRIPT = <<-SH
    #!/bin/sh
    IFS= read -r _user_turn
    exit 0
    SH
end
