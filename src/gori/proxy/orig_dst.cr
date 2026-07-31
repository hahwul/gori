require "socket"
require "log"

# The ORIGINAL DESTINATION of a transparently-redirected connection, read from the kernel.
#
# A transparent listener sees a connection whose destination the kernel already rewrote: the
# socket's local address is gori's, not the address the client dialled. Both redirectors keep
# the pre-NAT tuple and will hand it back, through two entirely different interfaces:
#
#   - Linux (iptables / nft REDIRECT) — `getsockopt(SOL_IP, SO_ORIGINAL_DST)`, answered out of
#     conntrack, and `SOL_IPV6 / IP6T_SO_ORIGINAL_DST` for a v6 connection.
#   - macOS (pf rdr) — `ioctl(/dev/pf, DIOCNATLOOK)` with the POST-NAT 4-tuple, which returns
#     the pre-NAT one.
#
# nil means "no answer", and that is ordinary rather than an error. It happens on a platform
# with no lookup at all, on a kernel with no NAT entry for this connection (someone dialled the
# listener directly instead of being redirected to it), and — the common case on macOS —
# because `/dev/pf` is mode 0600 root:wheel, so the lookup only works when gori itself runs as
# root. The caller falls back to deriving the destination from the `Host` header or the TLS
# SNI, which is what gori did everywhere before this existed.
#
# WHAT THIS DOES NOT SOLVE. The kernel answers with an ADDRESS; the client's `Host`/SNI answers
# with a NAME, and the two are not interchangeable. gori keeps using the name when it has one —
# it is what the certificate is minted for, what scope rules match, and what History shows — so
# a dial to a named destination is still re-resolved through DNS and can still land somewhere
# other than the address the client reached. What the lookup does remove is the port (the
# kernel's is definitive, so `target_port` and a client-supplied port both stop deciding it) and
# the no-name case (a `Host`-less request, a TLS ClientHello with no SNI), which previously had
# no destination at all. Pinning the DIAL of a NAMED destination to the kernel's address needs
# the TLS tunnel seam to carry an address separately from the certificate name; see #503.
module Gori::Proxy::OrigDst
  {% if flag?(:linux) %}
    # include/uapi/linux/netfilter_ipv4.h and .../netfilter_ipv6/ip6_tables.h. Both are 80,
    # which is a coincidence of two independent headers rather than one shared constant.
    SO_ORIGINAL_DST      = 80
    IP6T_SO_ORIGINAL_DST = 80
  {% end %}
end

{% if flag?(:darwin) %}
  # net/pfvar.h. Laid out for the APPLE-EXTENSIONS build of pf, which is what ships on macOS:
  # each port there is a `union pf_state_xport` (16-bit port / 16-bit call id / 32-bit SPI), so
  # the port fields are 4 bytes wide, not 2. Getting that wrong shifts everything after `saddr`.
  lib LibPf
    struct PfAddr
      v : StaticArray(UInt8, 16)
    end

    union PfStateXport
      port : UInt16
      call_id : UInt16
      spi : UInt32
    end

    struct PfiocNatlook
      saddr : PfAddr
      daddr : PfAddr
      rsaddr : PfAddr
      rdaddr : PfAddr
      sxport : PfStateXport
      dxport : PfStateXport
      rsxport : PfStateXport
      rdxport : PfStateXport
      af : UInt8
      proto : UInt8
      proto_variant : UInt8
      direction : UInt8
    end

    # Not bound by the stdlib (it binds only what termios needs). Darwin's request argument is
    # an `unsigned long`, and the third argument is variadic.
    fun ioctl(fd : LibC::Int, request : LibC::ULong, ...) : LibC::Int
  end
{% end %}

module Gori::Proxy::OrigDst
  {% if flag?(:darwin) %}
    # DIOCNATLOOK = _IOWR('D', 23, struct pfioc_natlook). Computed from `sizeof` rather than
    # written out as 0xC0544417: the size is encoded INTO the ioctl number, so a hand-written
    # constant and a mis-sized struct would disagree silently and the ioctl would just fail.
    IOC_INOUT    = 0xC000_0000_u32
    IOCPARM_MASK =      0x1fff_u32
    DIOCNATLOOK  = (IOC_INOUT | ((sizeof(LibPf::PfiocNatlook).to_u32 & IOCPARM_MASK) << 16) |
                    ('D'.ord.to_u32 << 8) | 23_u32).to_u64

    PF_OUT      =  2_u8 # enum pf_dir
    AF_INET_PF  =  2_u8
    AF_INET6_PF = 30_u8 # darwin's AF_INET6, which is NOT Linux's 10
    IPPROTO_TCP =  6_u8
    PF_DEVICE   = "/dev/pf"
  {% end %}

  # The address the client originally dialled, or nil when the kernel has no answer.
  #
  # A result equal to the socket's OWN local address is treated as no answer. That is not
  # paranoia: Linux answers `SO_ORIGINAL_DST` out of conntrack, and a tracked-but-not-NATted
  # connection (someone connected straight to the transparent listener) yields the local
  # address — which gori would then dial, connecting to itself and burning a connection slot per
  # attempt until the listener wedges (`upstream.cr:100-119`). Falling back to derivation there
  # is also simply correct: nothing redirected this connection, so there is no earlier
  # destination to recover.
  def self.lookup(client : ::Socket) : ::Socket::IPAddress?
    local = (client.local_address.as?(::Socket::IPAddress) rescue nil)
    found = lookup_raw(client, local)
    return nil unless found
    return nil if local && same_socket?(found, local)
    found
  end

  # Whether two addresses name the SAME socket, folding the v4-mapped spelling — which is the
  # only reason this is not a raw `==`, and it is the case the self-address guard above exists
  # for rather than an exotic one. `lookup_raw` picks the socket option by the LOCAL address's
  # family, and its own comment says why: a v4-mapped connection on a dual-stack socket was
  # redirected by iptables (v4), so the v4 option holds the answer. That option answers out of
  # a `sockaddr_in`, so `found` renders as a plain dotted quad while the socket's local address
  # on a `::` listener renders `::ffff:` — and `"192.168.1.5" != "::ffff:192.168.1.5"`. A raw
  # compare therefore let the guard miss exactly the pairing the file is built around, and gori
  # dialled its own listener once per connection until the accept loop wedged.
  def self.same_socket?(a : ::Socket::IPAddress, b : ::Socket::IPAddress) : Bool
    a.port == b.port && dial_host(a) == dial_host(b)
  end

  # The interface the answer came through, for the line that tells the operator which source
  # decided a destination. Naming it matters as much as the yes/no: the two mechanisms fail for
  # entirely different reasons, so the operator's next move differs.
  def self.mechanism : String
    {% if flag?(:linux) %}
      "SO_ORIGINAL_DST"
    {% elsif flag?(:darwin) %}
      "pf DIOCNATLOOK"
    {% else %}
      "no supported mechanism"
    {% end %}
  end

  # Whether a lookup can work at all in this process, as a sentence for the operator. nil when
  # it can. Deliberately not a Bool: "unavailable" has three quite different causes and the
  # operator's next move differs for each (change platform / run as root / nothing to do).
  def self.unavailable_reason : String?
    {% if flag?(:linux) %}
      nil
    {% elsif flag?(:darwin) %}
      pf_device ? nil : "cannot open #{PF_DEVICE} (it is root-only, and gori is not running as root)"
    {% else %}
      "no original-destination lookup on this platform (Linux SO_ORIGINAL_DST / macOS pf only)"
    {% end %}
  end

  {% if flag?(:linux) %}
    private def self.lookup_raw(client : ::Socket, local : ::Socket::IPAddress?) : ::Socket::IPAddress?
      # Pick the option by the family of the socket we are ACCEPTING on, not the peer's: a
      # v4-mapped connection on a dual-stack socket was redirected by iptables (v4), so the v4
      # option is the one holding the answer even though the socket is INET6.
      v6 = local ? !v4ish?(local) : client.family == ::Socket::Family::INET6
      if v6
        getsockopt_in6(client.fd) || getsockopt_in(client.fd)
      else
        getsockopt_in(client.fd) || getsockopt_in6(client.fd)
      end
    end

    private def self.getsockopt_in(fd : Int32) : ::Socket::IPAddress?
      sa = uninitialized LibC::SockaddrIn
      len = LibC::SocklenT.new(sizeof(LibC::SockaddrIn))
      return nil unless LibC.getsockopt(fd, LibC::IPPROTO_IP, SO_ORIGINAL_DST,
                          pointerof(sa).as(Void*), pointerof(len)) == 0
      ::Socket::IPAddress.from(pointerof(sa).as(LibC::Sockaddr*), len)
    rescue
      nil
    end

    private def self.getsockopt_in6(fd : Int32) : ::Socket::IPAddress?
      sa = uninitialized LibC::SockaddrIn6
      len = LibC::SocklenT.new(sizeof(LibC::SockaddrIn6))
      return nil unless LibC.getsockopt(fd, LibC::IPPROTO_IPV6, IP6T_SO_ORIGINAL_DST,
                          pointerof(sa).as(Void*), pointerof(len)) == 0
      ::Socket::IPAddress.from(pointerof(sa).as(LibC::Sockaddr*), len)
    rescue
      nil
    end
  {% elsif flag?(:darwin) %}
    # pf answers a lookup, not a socket option: hand it the POST-NAT tuple it can see
    # (client address/port, our local address/port) in the OUT direction and it returns the
    # PRE-NAT destination in rdaddr/rdxport. Same call squid and relayd make.
    private def self.lookup_raw(client : ::Socket, local : ::Socket::IPAddress?) : ::Socket::IPAddress?
      return nil unless dev = pf_device
      return nil unless local
      return nil unless remote = (client.remote_address.as?(::Socket::IPAddress) rescue nil)
      v6 = !v4ish?(local)
      return nil if v6 != !v4ish?(remote) # a mixed pair cannot be one pf state

      nl = LibPf::PfiocNatlook.new
      nl.af = v6 ? AF_INET6_PF : AF_INET_PF
      nl.proto = IPPROTO_TCP
      nl.direction = PF_OUT
      nl.saddr = pf_addr(remote, v6)
      nl.daddr = pf_addr(local, v6)
      # Whole-union assignment, not `nl.sxport.port = …`: reading a lib struct's nested value
      # field yields a COPY, so the field form would set the port on a temporary and send pf a
      # zero.
      nl.sxport = pf_xport(remote.port)
      nl.dxport = pf_xport(local.port)

      return nil unless LibPf.ioctl(dev.fd, DIOCNATLOOK, pointerof(nl)) == 0
      port = ntoh16(nl.rdxport.port)
      return nil unless 1 <= port <= 65535
      ::Socket::IPAddress.new(pf_addr_to_s(nl.rdaddr, v6), port)
    rescue
      nil
    end

    # Opened once and kept: the ioctl is per-call state, so one descriptor serves every
    # connection, and a FAILED open is cached too — retrying it per connection would put a
    # guaranteed-failing syscall on the accept path of every unprivileged run.
    @@pf_device : File? = nil
    @@pf_tried = false

    private def self.pf_device : File?
      return @@pf_device if @@pf_tried
      dev = (File.open(PF_DEVICE, "r") rescue nil)
      @@pf_device = dev
      @@pf_tried = true
      dev
    end

    # `struct pf_addr` is a 16-byte union whose v4 arm occupies the first 4 bytes, so both
    # families are the same "zero it, then write the raw network-order address at offset 0".
    private def self.pf_addr(addr : ::Socket::IPAddress, v6 : Bool) : LibPf::PfAddr
      slot = LibPf::PfAddr.new
      sa = addr.to_unsafe
      if v6
        src = sa.as(LibC::SockaddrIn6*).value.sin6_addr
        pointerof(src).as(UInt8*).copy_to(pointerof(slot).as(UInt8*), 16)
      else
        src = sa.as(LibC::SockaddrIn*).value.sin_addr
        pointerof(src).as(UInt8*).copy_to(pointerof(slot).as(UInt8*), 4)
      end
      slot
    end

    private def self.pf_addr_to_s(addr : LibPf::PfAddr, v6 : Bool) : String
      b = addr.v
      return "#{b[0]}.#{b[1]}.#{b[2]}.#{b[3]}" unless v6
      groups = (0...8).map { |i| ((b[i * 2].to_u16 << 8) | b[i * 2 + 1]).to_s(16) }
      ::Socket::IPAddress.new(groups.join(':'), 0).address
    end

    private def self.pf_xport(port : Int32) : LibPf::PfStateXport
      x = LibPf::PfStateXport.new
      x.port = hton16(port)
      x
    end

    # Host <-> network order without a byte-order compile flag: `IO::ByteFormat::NetworkEndian`
    # already knows which way this machine points, so let it do the swap and reinterpret the two
    # bytes. pf carries every port in network order, in both directions.
    private def self.hton16(port : Int32) : UInt16
      buf = uninitialized UInt8[2]
      IO::ByteFormat::NetworkEndian.encode(port.to_u16!, buf.to_slice)
      buf.to_unsafe.as(UInt16*).value
    end

    private def self.ntoh16(v : UInt16) : Int32
      buf = uninitialized UInt8[2]
      buf.to_unsafe.as(UInt16*).value = v
      IO::ByteFormat::NetworkEndian.decode(UInt16, buf.to_slice).to_i
    end
  {% else %}
    private def self.lookup_raw(client : ::Socket, local : ::Socket::IPAddress?) : ::Socket::IPAddress?
      nil
    end
  {% end %}

  # An IPv4 address, or the v4-mapped v6 form of one. Crystal renders the latter in RFC 5952
  # mixed notation ("::ffff:127.0.0.1"), which is also the form that has to be unwrapped before
  # the address is dialled or shown.
  def self.v4ish?(addr : ::Socket::IPAddress) : Bool
    addr.family == ::Socket::Family::INET || addr.address.starts_with?("::ffff:")
  end

  # The address as something to dial: a v4-mapped v6 literal unwrapped to its dotted form, so a
  # dual-stack listener does not hand "::ffff:10.0.0.5" to the resolver and to History.
  def self.dial_host(addr : ::Socket::IPAddress) : String
    a = addr.address
    a.starts_with?("::ffff:") && a.count('.') == 3 ? a.lchop("::ffff:") : a
  end
end
