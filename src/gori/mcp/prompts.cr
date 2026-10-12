module Gori
  module MCP
    # The docs playbooks as MCP prompts (#1596): templates the operator picks from the
    # client (`/mcp__gori__<name>` in Claude Code), so they cost no model context until then
    # and add nothing to the `tools/list` budget.
    #
    # Embedded at compile time, so `docs/content/playbooks/` is a BUILD input: the Nix source
    # filter and the Docker context keep that directory, and a playbook edit changes the
    # binary. Macros cannot glob, so every English playbook is named here or in SKIPPED, and
    # `spec/mcp/prompts_spec.cr` fails when one is in neither.
    module Prompts
      record Playbook, name : String, title : String, description : String, body : String

      DOCS_BASE = "https://gori.hahwul.com"

      RAW = {
        "set-up-an-engagement"     => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/set-up-an-engagement.md") }},
        "map-the-attack-surface"   => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/map-the-attack-surface.md") }},
        "intercept-and-modify"     => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/intercept-and-modify.md") }},
        "carry-a-session"          => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/carry-a-session.md") }},
        "fuzz-a-parameter"         => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/fuzz-a-parameter.md") }},
        "test-access-control"      => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/test-access-control.md") }},
        "attack-a-jwt"             => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/attack-a-jwt.md") }},
        "crack-and-forge-cookies"  => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/crack-and-forge-cookies.md") }},
        "grade-token-randomness"   => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/grade-token-randomness.md") }},
        "confirm-blind-vulns-oast" => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/confirm-blind-vulns-oast.md") }},
        "decode-and-transform"     => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/decode-and-transform.md") }},
        "triage-and-report"        => {{ read_file("#{__DIR__}/../../../docs/content/playbooks/triage-and-report.md") }},
      }

      # Playbooks deliberately not served, with the reason.
      SKIPPED = {
        "run-an-ai-co-pilot" => "the operator installing this MCP server, meaningless to the agent already on the other end of it",
      }

      # Said once, ahead of every playbook: the text is written for a human at the TUI and
      # `gori run`, and the agent has only `tools/list`.
      PREAMBLE = "The playbook below is written for a human operator using the gori TUI and " \
                 "`gori run`. Carry it out with this MCP server: map each step to the tool in " \
                 "tools/list that does the same thing, and never call a tool that is not in tools/list."

      @@by_name : Hash(String, Playbook)?

      private def self.by_name : Hash(String, Playbook)
        @@by_name ||= RAW.to_h { |name, raw| {name, parse(name, raw)} }
      end

      def self.all : Array(Playbook)
        by_name.values
      end

      def self.[]?(name : String) : Playbook?
        by_name[name]?
      end

      # Title and description are two `key = "…"` lines of the `+++` TOML block; the body is
      # everything after it, minus the screenshots and heading anchors only a browser can use,
      # with site-relative links made absolute. Nothing else is rewritten.
      def self.parse(name : String, raw : String) : Playbook
        _, front, body = raw.split("+++", 3)
        Playbook.new(name, front_value(front, "title"), front_value(front, "description"),
          body.gsub(/<figure\b.*?<\/figure>\n*/m, "")
            .gsub(/[ \t]*\{#[\w-]+\}[ \t]*$/m, "")
            .gsub("](/", "](#{DOCS_BASE}/")
            .strip)
      end

      private def self.front_value(front : String, key : String) : String
        front[/^#{key}[ \t]*=[ \t]*"([^\n]*)"[ \t]*$/m, 1].gsub(%(\\"), %("))
      end

      # The one `user` message `prompts/get` returns. `restriction` is the server's own
      # sentence about `--read-only` / `--tools` (Server#prompt_restriction); `focus` is the
      # operator's text, verbatim, on its own line.
      def self.message(pb : Playbook, *, ask_operator : Bool, restriction : String?, focus : String?) : String
        handoff = ask_operator ? " A step no listed tool can do goes to the operator through ask_operator." : " A step no listed tool can do is named and skipped."
        String.build do |s|
          s << PREAMBLE << handoff
          s << ' ' << restriction if restriction
          s << "\n\n" << pb.body
          s << "\n\nFocus: " << focus if focus
        end
      end
    end
  end
end
