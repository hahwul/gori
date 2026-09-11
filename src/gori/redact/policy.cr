require "json"
require "../redact"
require "../settings"
require "../store"

module Gori
  module Redact
    # Which profile an invocation actually redacts with, folded out of the two scopes a profile
    # can live in — settings.json (`Settings.redaction_profiles`) and the open project's own row
    # (`Store::REDACTION_KEY`) — plus whatever the invocation itself asked for.
    #
    # One resolver rather than a rule per surface, for `Rules.merged`'s reason: `gori run show`,
    # a TUI copy and an MCP read must sanitize the same flow the same way, or an operator who
    # checked the export in one place has checked nothing about the other.
    module Policy
      # The project half of the fold, parsed from its row. Absent row / unparseable row = all
      # three empty, which is exactly "this project adds nothing", so a corrupt row degrades to
      # the global config instead of taking an export down.
      record ProjectScope,
        active : String = "",
        default : Bool? = nil,
        profiles : Array(Profile) = [] of Profile

      def self.project_scope(store : Store?) : ProjectScope
        raw = store.try(&.setting(Store::REDACTION_KEY)) || return ProjectScope.new
        node = begin
          JSON.parse(raw)
        rescue JSON::ParseException
          return ProjectScope.new
        end
        h = node.as_h? || return ProjectScope.new
        ProjectScope.new(
          active: h["active"]?.try(&.as_s?).try(&.strip) || "",
          default: h["default"]?.try(&.as_bool?),
          profiles: Profile.list_from_json(h["profiles"]?))
      end

      # Persist the project half. The whole object is rewritten, so a caller changing one field
      # reads the current scope first (see `gori run redact`); a partial write here would be a
      # second merge policy on top of the one `Settings.save` already has.
      def self.write_project_scope(store : Store, scope : ProjectScope) : Bool
        if scope.active.empty? && scope.default.nil? && scope.profiles.empty?
          return store.delete_setting(Store::REDACTION_KEY)
        end
        store.set_setting(Store::REDACTION_KEY, JSON.build do |j|
          j.object do
            j.field "active", scope.active unless scope.active.empty?
            scope.default.try { |d| j.field "default", d }
            unless scope.profiles.empty?
              j.field "profiles" do
                j.array { scope.profiles.each(&.build_json(j)) }
              end
            end
          end
        end)
      end

      # Every profile available here, most specific first: the project's, then settings.json's,
      # then the built-ins. First match wins by NAME, so a project profile shadows a global one
      # of the same name and a global one shadows a built-in — the same precedence a project
      # network override already has over the global value.
      def self.profiles(store : Store?) : Array(Profile)
        seen = Set(String).new
        all = [] of Profile
        {project_scope(store).profiles, Settings.redaction_profiles, BUILTIN_PROFILES}.each do |list|
          list.each { |p| all << p if seen.add?(p.name) }
        end
        all
      end

      def self.profile(store : Store?, name : String) : Profile?
        wanted = name.strip
        return nil if wanted.empty?
        profiles(store).find { |p| p.name == wanted }
      end

      def self.names(store : Store?) : Array(String)
        profiles(store).map(&.name)
      end

      # What a surface should do about redaction for THIS invocation.
      #
      # `matcher` nil with no `error` means "not redacting, and that is fine" — the caller emits
      # the captured bytes and says nothing. `error` set means the invocation asked for
      # something that does not exist; the caller refuses rather than silently exporting raw,
      # because "your profile name was a typo, here are the secrets" is the one outcome this
      # feature exists to prevent.
      record Choice,
        matcher : Matcher? = nil,
        error : String? = nil,
        salt_persisted : Bool = true do
        def on? : Bool
          !matcher.nil?
        end
      end

      # `requested` is the profile named on the invocation (`--redact=NAME`), `on` the tri-state
      # the flags produce: true from `--redact`, false from `--no-redact`, nil when neither was
      # given and the configured default decides.
      def self.resolve(store : Store?, requested : String? = nil, on : Bool? = nil) : Choice
        return Choice.new if on == false
        scope = project_scope(store)
        name = requested.try(&.strip).presence
        # Naming a profile IS asking for redaction; requiring `--redact --redact=x` would be a
        # trap with no upside.
        wanted = on.nil? ? (!name.nil? || default_on?(scope)) : on
        return Choice.new unless wanted
        chosen = name || scope.active.presence || Settings.redaction_active.presence
        profile = if chosen
                    profile(store, chosen) || return Choice.new(error: unknown(store, chosen))
                  else
                    DEFAULT_PROFILE
                  end
        if profile.empty?
          return Choice.new(error: "redaction profile #{profile.name.inspect} has no rules, " \
                                   "so it would sanitize nothing — add fields to it or use --no-redact")
        end
        Choice.new(matcher: Matcher.new(profile), salt_persisted: Settings.arm_redaction)
      end

      # Does the configuration say "sanitize without being asked"? The project's answer wins
      # when it has one, including an explicit `false` that turns a global default off for one
      # engagement — which is why the project field is a nilable Bool and not a Bool.
      def self.default_on?(scope : ProjectScope) : Bool
        d = scope.default
        d.nil? ? Settings.redaction_default? : d
      end

      # The matcher for a surface that has NO per-invocation flag to offer — a TUI copy, an MCP
      # read. `--redact` has no analogue in a keystroke or a tool call, so "is redaction on by
      # default here" is the whole question, and `nil` means the surface hands over the captured
      # bytes exactly as it always has.
      def self.ambient(store : Store?) : Matcher?
        resolve(store).matcher
      end

      def self.unknown(store : Store?, name : String) : String
        "no redaction profile named #{name.inspect} (have: #{names(store).join(", ")})"
      end
    end
  end
end
