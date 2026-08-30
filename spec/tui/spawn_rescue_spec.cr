require "../spec_helper"

# Every background fiber the TUI starts must rescue.
#
# Not a style rule — a raise inside `spawn` kills only that fiber and prints its backtrace to
# STDERR, which under the TUI is the ALTERNATE SCREEN (#411). Both halves of that are bad and
# neither is visible as a bug:
#
#   - the display garbles, and the operator reads it as a rendering glitch;
#   - the work stops with no terminal event, so whatever the main fiber was waiting for never
#     arrives. Measured cases: a Discover/Miner/Sequencer run whose bottom-bar job spins for
#     the rest of the session (`jobs.finish` is only reached from a Done/Error drain, so the
#     exit prompt keeps counting a run that already died), the Authorize passive watcher whose
#     `ensure` also stops its catch-up sweep, and the statusline worker that leaves the row
#     frozen at its last value.
#
# WHAT THIS DOES AND DOES NOT CHECK. It asserts only that a `rescue` appears somewhere inside
# each spawn block — that the decision was MADE. Where the rescue belongs, and how wide it is,
# stays a per-fiber judgement: `rescue Channel::ClosedError` is exactly right for a fiber whose
# only expected end is its feed closing, and exactly wrong for one doing store reads. So a
# narrow rescue passes here, and a rescue inside a nested `begin` passes here. Neither is an
# oversight; both are cases where a mechanical rule would be wrong more often than right. This
# catches the one thing that is never right — a spawn block with no answer at all — and the
# reviewing eye covers the rest.
#
# The TUI alone: a proxy relay fiber unwinding is ordinary per-connection teardown, and the
# alternate-screen argument above is what makes this universal here.
describe "TUI background fibers" do
  it "rescue, so a raise cannot land on the alternate screen" do
    root = File.expand_path(File.join(__DIR__, "..", ".."))
    offenders = [] of String

    # `src/gori/tui.cr` as well as the directory: the module's own file holds terminal
    # construction, and a glob of the directory alone would never look at it.
    paths = Dir.glob(File.join(root, "src", "gori", "tui", "**", "*.cr"))
    paths << File.join(root, "src", "gori", "tui.cr")

    paths.sort.each do |path|
      relative = Path[path].relative_to(root).to_s
      lines = File.read_lines(path)
      lines.each_with_index do |line, index|
        stripped = line.strip
        next unless stripped.starts_with?("spawn(") || stripped.starts_with?("spawn ")

        indent = line.size - line.lstrip.size
        # The three forms a spawn can take. A brace block opened and closed on one line is that
        # line; anything else runs to the first `end` / `}` sitting at the spawn's own indent.
        closer =
          if stripped.matches?(/\bdo(\s*\|[^|]*\|)?$/)
            "end"
          elsif stripped.count('{') > stripped.count('}')
            "}"
          end

        body =
          if closer
            close = ((index + 1)...lines.size).find do |i|
              l = lines[i]
              l.strip == closer && (l.size - l.lstrip.size) == indent
            end
            unless close
              offenders << "#{relative}:#{index + 1}: spawn block has no `#{closer}` at its own indent"
              next
            end
            lines[index..close].join("\n")
          else
            line
          end

        offenders << "#{relative}:#{index + 1}: #{stripped}" unless body.includes?("rescue")
      end
    end

    fail("TUI spawn without a rescue (a raise here lands on the alternate screen):\n#{offenders.join("\n")}") unless offenders.empty?
  end
end
