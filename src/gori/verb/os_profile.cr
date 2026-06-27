module Gori
  module Verb
    # Per-OS default keymap selection. The verb files (verbs/*.cr) hold the COMMON
    # default chords; this layer lets a specific OS swap a verb's defaults on top of
    # them, and lets the user pin a profile at runtime via Settings.keymap_os.
    #
    # Honest status: the OVERRIDES tables ship EMPTY. In a terminal, plain Ctrl+letter
    # reaches the app on macOS/Linux/Windows alike — the genuinely hazardous keys are
    # the terminal-reserved control chars (^C/^S/^Q/^Z/^\…), which Verb::Reserved blocks
    # regardless of OS. So gori's defaults don't actually need to diverge today. What
    # this delivers is the MECHANISM (compile-time native default + a runtime override +
    # a place to add per-OS divergence), so a future per-terminal clash can be fixed
    # without touching dispatch. Don't invent divergence we don't need.
    module OsProfile
      enum Os
        Darwin
        Linux
        Windows
      end

      # The platform this binary was built for (Crystal's Windows flag is :win32).
      COMPILE_DEFAULT =
        {% if flag?(:darwin) %}
          Os::Darwin
        {% elsif flag?(:win32) %}
          Os::Windows
        {% else %}
          Os::Linux
        {% end %}

      # verb-id → replacement chords, per OS. Ships empty (see the note above); ready
      # to populate if a real per-terminal clash ever appears.
      OVERRIDES = {
        Os::Darwin  => Hash(String, Array(Chord)).new,
        Os::Linux   => Hash(String, Array(Chord)).new,
        Os::Windows => Hash(String, Array(Chord)).new,
      }

      def self.overrides_for(os : Os) : Hash(String, Array(Chord))
        OVERRIDES[os]
      end

      # Resolve a settings string to a concrete Os. "auto"/unknown → the build's native
      # default; an explicit name lets e.g. a Linux binary adopt the Windows profile.
      def self.resolve(setting : String) : Os
        case setting
        when "darwin"  then Os::Darwin
        when "linux"   then Os::Linux
        when "windows" then Os::Windows
        else                COMPILE_DEFAULT
        end
      end

      # The active profile per the persisted setting.
      def self.active : Os
        resolve(Gori::Settings.keymap_os)
      end
    end
  end
end
