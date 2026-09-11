require "json"
require "random/secure"
require "../redact"

# REDACTION section (settings.json "redaction"): the named profiles safe evidence export
# applies, which one is active, whether it applies without being asked, and the per-install
# secret behind every placeholder tag (#1035). See settings.cr for the load/save/serialize
# orchestration, and `Gori::Redact` for what a profile means.
#
# Global here, per-project in the project DB (`Store::REDACTION_KEY` — see
# `Redact::Policy`): a profile is engagement CONFIG, and both scopes are real. "never export a
# `password` field" belongs to the operator and follows them everywhere; "this target calls it
# `pwd_hash` and the account number lives at `/data/acct`" belongs to one engagement and must
# not follow them into the next.
module Gori::Settings
  # User-defined profiles, in the order they were written. A profile whose NAME matches a
  # built-in replaces it (see `redaction_profile`) — that is how an operator edits the default
  # list, and the built-in's contents are printed by `gori run redact profiles` so there is
  # something to copy.
  class_property redaction_profiles : Array(Redact::Profile) = [] of Redact::Profile

  # Which profile a safe export uses when the invocation does not name one. Empty = the
  # built-in `default`.
  class_property redaction_active : String = ""

  # Apply the active profile to shareable output WITHOUT a per-invocation flag.
  #
  # Off at the factory, and that is a deliberate choice against the issue's "explicit opt-in
  # path for raw output" read literally: flipping the default under an install that already
  # has scripts reading `gori run show --format raw` would silently change what those scripts
  # get, and a body that comes back with `[REDACTED:…]` where a signature used to be is a
  # debugging session nobody asked for. So the SETTING is the opt-in, once, per install — and
  # from then on `--no-redact` is the explicit path back to raw, exactly as asked.
  class_property? redaction_default : Bool = false

  # The HMAC key behind every placeholder tag lives in `Redact.salt` and NOWHERE else — this
  # section reads it on load, writes it on save, and mints it on first use. One variable rather
  # than a persisted copy beside the engine's live one, because the two can only ever disagree
  # in the direction that matters: a stale copy here would write the wrong key to disk, and the
  # placeholders in every artifact after that would stop correlating with the ones before it.
  #
  # It is a SECRET, kept in settings.json beside `env`'s token values on the same terms (the
  # tree is 0700 and the file 0600). One consequence worth stating where the value is declared:
  # `gori settings export --sections redaction` carries it, so a profile shared that way also
  # shares the ability to re-derive every tag this install has ever written. Export the profiles
  # alone (`gori run redact profiles --format json`) to hand somebody the RULES without the key.

  # 32 bytes. The tag is 32 bits of an HMAC-SHA256 and the salt only has to be unguessable;
  # this is simply a comfortable margin over the digest's block-fill.
  REDACTION_SALT_BYTES = 32

  # Arm the redaction engine for this process: make sure a salt exists, minting and persisting
  # one if not. Every surface about to sanitize calls this first.
  #
  # Returns whether the salt is on DISK. `false` means this process minted one it could not
  # write (a read-only config, a partial load `save` refuses — see `Settings.save`), so the
  # placeholders it is about to produce are internally consistent and will NOT correlate with
  # any other session's. That is a fact worth a line on STDERR, not a reason to refuse the
  # export, so it is reported rather than raised. A salt already in memory reads as persisted:
  # the only way one gets there is a load from disk or a save from here.
  def self.arm_redaction : Bool
    return true unless Redact.salt.empty?
    Redact.salt = Random::Secure.hex(REDACTION_SALT_BYTES)
    save
  end

  # Tolerant parse, like every other list section: a non-object node keeps the current values,
  # an entry with no usable name is dropped, and a field of the wrong JSON type is skipped
  # rather than raising — a hand-edited file must not be able to take the whole load down (see
  # `@@load_partial`).
  private def self.parse_redaction(node : JSON::Any?) : Nil
    h = node.try(&.as_h?) || return
    h["active"]?.try(&.as_s?).try { |v| self.redaction_active = v.strip }
    self.redaction_default = load_bool_h(h, "default", redaction_default?)
    h["salt"]?.try(&.as_s?).try(&.strip).try { |v| Redact.salt = v unless v.empty? }
    h["profiles"]?.try(&.as_a?).try { self.redaction_profiles = Redact::Profile.list_from_json(h["profiles"]) }
  end

  # Factory reset for this section (dispatched by Settings.reset_to_factory).
  #
  # The SALT is deliberately kept, which is why it is not named here. Resetting settings is "put
  # the tool back the way it shipped"; discarding the salt would additionally break every
  # placeholder in every artifact already written, silently and with no way back, which is not
  # something a reset should be able to do.
  private def self.reset_redaction : Nil
    self.redaction_profiles = [] of Redact::Profile
    self.redaction_active = ""
    self.redaction_default = false
  end

  # Omitted entirely at the factory default, like the other optional sections, so an untouched
  # install keeps a settings.json free of values nobody chose. A minted salt alone is enough to
  # write the section: it is the one value in here gori chooses for itself, and losing it would
  # cost the operator the correlation between yesterday's export and today's.
  private def self.serialize_redaction(j : JSON::Builder) : Nil
    return if redaction_profiles.empty? && redaction_active.empty? &&
              !redaction_default? && Redact.salt.empty?
    j.field "redaction" do
      j.object do
        j.field "active", redaction_active unless redaction_active.empty?
        j.field "default", true if redaction_default?
        j.field "salt", Redact.salt unless Redact.salt.empty?
        unless redaction_profiles.empty?
          j.field "profiles" do
            j.array { redaction_profiles.each(&.build_json(j)) }
          end
        end
      end
    end
  end
end
