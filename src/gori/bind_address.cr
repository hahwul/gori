module Gori
  # One place that answers the two DIFFERENT questions a proxy bind address gets asked.
  # They read like the same question and stop being one the moment the bind is a wildcard:
  #
  #   display(host, port) — what to SHOW a human ("localhost:8070 (all interfaces)")
  #   dial_host(host)     — what a client on this machine must actually CONNECT to
  #
  # A wildcard bind ("0.0.0.0" / "::") means "answer on every interface". It is a fine
  # thing to bind and a useless thing to dial: nothing connects TO 0.0.0.0. So printing
  # "point your client's proxy at 0.0.0.0:8070" hands the user a string that cannot work,
  # and feeding it to a browser's --proxy-server launches a browser that proxies nothing
  # (the bug this module exists to kill). Both surfaces resolve a wildcard to loopback.
  #
  # Deliberately a leaf with NO requires: `capture_status` (a json-only sidecar read by
  # the project picker) and `proxy/conn/self_page` (deep inside the proxy) both need it,
  # and neither may grow a dependency on the other's subtree.
  module BindAddress
    # Appended to a wildcard bind's display. "localhost" alone is typeable but hides that
    # LAN devices can reach this listener too — and that reachability is the entire reason
    # anyone binds a wildcard (installing the CA on a phone, see 5b956ee).
    WILDCARD_NOTE = "all interfaces"

    # Every spelling of "bind to every interface" that Settings.bind_host_error accepts,
    # plus blank — blank is caller-defaulted to loopback (SetupWizard#effective_ip) and
    # is just as undialable as 0.0.0.0 until it is.
    def self.wildcard?(host : String) : Bool
      case normalize(host)
      when "", "0.0.0.0", "::", "::0", "0:0:0:0:0:0:0:0" then true
      else                                                    false
      end
    end

    # The concrete host a client ON THIS MACHINE should dial to reach a listener bound to
    # `host`. Only a wildcard moves, and it collapses to loopback OF THE SAME FAMILY:
    # 127.0.0.1 for an IPv4 wildcard, ::1 for an IPv6 one. Deliberately NOT "localhost" —
    # that name resolves to whichever family the resolver prefers, and a 0.0.0.0 listener
    # is unreachable over ::1 (a :: listener likewise over 127.0.0.1 unless the kernel is
    # dual-stack), so "localhost" reintroduces the classic wrong-family connect failure
    # at exactly the point we are trying to remove one.
    #
    # A concrete bind is already dialable and comes back unchanged, with brackets stripped
    # so callers needing a BARE host get one (Firefox's network.proxy.http pref takes the
    # port separately and must not see brackets); `authority` re-adds them.
    def self.dial_host(host : String) : String
      h = strip_brackets(host.strip)
      return h unless wildcard?(h)
      h.includes?(':') ? "::1" : "127.0.0.1"
    end

    # "host:port", bracketing an IPv6 literal. Call sites used to build this by hand with
    # bare interpolation, which renders a perfectly legal `::1` bind (bind_host_error
    # accepts it) as the unparseable "::1:8070".
    def self.authority(host : String, port : Int32) : String
      h = strip_brackets(host.strip)
      h.includes?(':') ? "[#{h}]:#{port}" : "#{h}:#{port}"
    end

    # The bind as a human should read it: a loopback spelling collapses to "localhost"
    # (what the user would actually type), an IPv6 literal is bracketed, and a wildcard
    # renders as the loopback address they CAN type plus a note that it is not only that.
    #
    # `terse` drops the note for width-constrained readouts (the top-bar listen chip, the
    # project-picker row). The ADDRESS is byte-identical either way — only the
    # parenthetical is budgeted — so no two surfaces can ever show the user a different
    # address to type, which is the whole point of routing every site through here.
    def self.display(host : String, port : Int32, *, terse : Bool = false) : String
      if wildcard?(host)
        base = "localhost:#{port}"
        terse ? base : "#{base} (#{WILDCARD_NOTE})"
      elsif localhost_alias?(host)
        "localhost:#{port}"
      else
        authority(host, port)
      end
    end

    # Only the CANONICAL loopback spellings become "localhost". A non-canonical 127.x
    # (127.0.0.2, a second loopback alias someone bound on purpose) stays literal: dialing
    # "localhost" would not reach it, so collapsing it would print an address that lies.
    private def self.localhost_alias?(host : String) : Bool
      case normalize(host)
      when "localhost", "127.0.0.1", "::1", "0:0:0:0:0:0:0:1" then true
      else                                                         false
      end
    end

    private def self.normalize(host : String) : String
      strip_brackets(host.strip).downcase
    end

    private def self.strip_brackets(h : String) : String
      h.starts_with?('[') && h.ends_with?(']') ? h[1...-1] : h
    end
  end
end
