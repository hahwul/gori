# The project a `gori run` command reads when it names none (#1387).
#
# It used to be "the most recently active project" and nothing else, so one write to another
# project (`notes create --project demo`) silently re-aimed every later command of a script
# that relied on the default — a notice on STDERR, which a script does not read, was the only
# trace. Two ways to PIN it now sit in front of that, in this order:
#
#   --db PATH / --project NAME   always win (they are not defaults)
#   GORI_PROJECT=NAME            the process's own pin — a script sets it once at the top
#   gori run project switch NAME the operator's standing pin, persisted beside the projects
#   most recently active         the old default, unchanged when neither pin is set
#
# A pin that names no project is REFUSED, never skipped: falling through to the most recent
# project is exactly the silent re-aim this exists to stop. This is `gori run` resolution
# alone — the TUI opens what the operator picks and `gori mcp` has its own binding
# (`GORI_MCP_PROJECT`, the workspace), so `ProjectRegistry.default_of` is left as it is.
module Gori
  module CLI
    module Run
      DEFAULT_PROJECT_ENV = "GORI_PROJECT"

      # Which rule chose the default. `announce_default_project` names it, so a pinned run
      # reads differently from one that fell through to the most recent project.
      enum DefaultSource
        Env
        Pinned
        Recent

        def phrase : String
          case self
          in Env    then "from #{DEFAULT_PROJECT_ENV}"
          in Pinned then "pinned by `gori run project switch`"
          in Recent then "most recently active"
          end
        end
      end

      # The file `project switch` writes: the pinned project's short id (its slug for a legacy
      # project with none), which survives a rename. A dot-name, so `ProjectRegistry#list`
      # never mistakes it for a project.
      def self.default_pin_path : String
        File.join(Paths.projects_dir, ".cli-default")
      end

      def self.read_default_pin : String?
        File.read(default_pin_path).strip.presence
      rescue File::Error
        nil
      end

      # The default project and the rule that chose it; the refusal sentence for a pin that
      # names nothing (or two things); nil when there is no project at all. Pure over its
      # inputs, so the precedence is pinned by a spec rather than by the environment.
      def self.default_project(registry : ProjectRegistry, env : String?, pin : String?) : {Project, DefaultSource} | String?
        unless env.nil?
          name = env.strip
          return "#{DEFAULT_PROJECT_ENV} is set but empty — unset it, or name a project" if name.empty?
          return pinned_project(registry, name, DefaultSource::Env) do
            "#{DEFAULT_PROJECT_ENV}=#{CLI::Output.term_safe(name).inspect} names no project#{have_projects(registry)}"
          end
        end
        if p = pin
          return pinned_project(registry, p, DefaultSource::Pinned) do
            "the default project pinned by `gori run project switch` (#{CLI::Output.term_safe(p).inspect}) " \
            "no longer exists — pin another with `gori run project switch NAME`, or clear the pin " \
            "with `gori run project switch --clear`"
          end
        end
        ProjectRegistry.default_of(registry.list).try { |project| {project, DefaultSource::Recent} }
      end

      private def self.pinned_project(registry : ProjectRegistry, name : String, source : DefaultSource,
                                      & : -> String) : {Project, DefaultSource} | String
        found = registry.find(name)
        found ? {found, source} : yield
      rescue ex : ProjectRegistry::Ambiguous
        "#{source.env? ? DEFAULT_PROJECT_ENV : "the pinned default project"}: #{ex.message}"
      end

      private def self.have_projects(registry : ProjectRegistry) : String
        projects = registry.list
        return "" if projects.empty?
        " (have: #{projects.map { |project| CLI::Output.term_safe(project.name) }.join(", ")})"
      end

      # `gori run project switch [NAME | --clear]`.
      private def self.cmd_project_switch(args : Array(String)) : Nil
        clear = false
        format = :text
        positional = [] of String
        parser = OptionParser.new do |p|
          p.banner = "Usage: gori run project switch NAME\n" \
                     "       gori run project switch --clear\n" \
                     "       gori run project switch\n\n" \
                     "Pin the project every `gori run` command reads when it is given no --project or\n" \
                     "--db, instead of the most recently active one (which a single write elsewhere\n" \
                     "moves). With no NAME, print the current default and what chose it.\n" \
                     "#{DEFAULT_PROJECT_ENV}=NAME in the environment wins over this pin; --project and\n" \
                     "--db win over both."
          p.on("--clear", "Remove the pin — the default goes back to the most recently active project") { clear = true }
          format_flag(p, [:text, :json], "Output: text (default) | json") { |f| format = f }
          p.on("-h", "--help", "Show this help") { puts p; exit 0 }
          p.unknown_args { |before, after| positional = before + after }
          p.invalid_option { |f| abort "gori run project switch: unknown option: #{f}\n#{p}" }
          p.missing_option { |f| abort "gori run project switch: missing value for #{f}" }
        end
        parser.parse(args)
        abort "gori run project switch: too many arguments (expected one NAME)" if positional.size > 1
        abort "gori run project switch: pass NAME or --clear, not both" if clear && !positional.empty?
        registry = ProjectRegistry.new(Paths.projects_dir)
        if clear
          File.delete?(default_pin_path)
        elsif name = positional.first?
          pin_default_project(registry, name)
        end
        report_default_project(registry, format)
      end

      private def self.pin_default_project(registry : ProjectRegistry, name : String) : Nil
        project = begin
          registry.find(name)
        rescue ex : ProjectRegistry::Ambiguous
          abort "gori run project switch: #{ex.message}"
        end
        abort "gori run project switch: no project matching '#{CLI::Output.term_safe(name)}'#{have_projects(registry)}" unless project
        # Written to a sibling and renamed, so a concurrent reader sees the old pin or the new
        # one, never half of either.
        tmp = "#{default_pin_path}.#{Process.pid}.tmp"
        File.write(tmp, "#{registry.id_of(project) || registry.slug_of(project)}\n")
        File.rename(tmp, default_pin_path)
      rescue ex : File::Error
        abort "gori run project switch: could not write #{default_pin_path}: #{ex.message}"
      end

      private def self.report_default_project(registry : ProjectRegistry, format : Symbol) : Nil
        chosen = default_project(registry, ENV[DEFAULT_PROJECT_ENV]?, read_default_pin)
        if format == :json
          puts(JSON.build do |j|
            j.object do
              case chosen
              in Tuple
                j.field "project", chosen[0].name
                j.field "id", registry.id_of(chosen[0])
                j.field "source", chosen[1].to_s.downcase
              in String
                j.field "project", nil
                j.field "error", chosen
              in Nil
                j.field "project", nil
              end
              j.field "pinned", read_default_pin
            end
          end)
        else
          case chosen
          in Tuple  then puts "Default project: #{CLI::Output.term_safe(chosen[0].name)} (#{chosen[1].phrase})"
          in String then puts "No default project: #{chosen}"
          in Nil    then puts "No default project: no projects yet"
          end
          # Said, because the pin just written is not what a command in THIS shell would read.
          if ENV.has_key?(DEFAULT_PROJECT_ENV) && read_default_pin
            puts "note: #{DEFAULT_PROJECT_ENV} is set in this environment, so it wins over the pin"
          end
        end
        exit 1 if chosen.is_a?(String)
      end

      # Whether `project` is the one `project switch` pinned. Asked BEFORE a `project delete`,
      # which then clears the pin once the delete succeeded — so the next command is told there
      # is no pin, rather than that the pinned project vanished.
      private def self.default_pinned?(registry : ProjectRegistry, project : Project) : Bool
        pin = read_default_pin || return false
        found = registry.find(pin) rescue nil
        !found.nil? && found.dir == project.dir
      end
    end
  end
end
