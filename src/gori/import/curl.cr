require "base64"
require "random/secure"
require "./shell"
require "./builder"
require "../proxy/codec/http1"

module Gori
  module Import
    # A pasted `curl` command, turned into the request it describes (#1244) — the inverse of
    # `Export::Curl`, and the two are held to a round trip: a request exported as curl and
    # imported back is the same bytes (`spec/curl_round_trip_spec.cr`).
    #
    # It PARSES and never runs anything. `Shell` splits the text into words; this maps curl's
    # flags onto a request head and body, following CURL's meaning of each flag, not
    # `gori run send`'s: there `-b` is a body, here it is a cookie, because Chrome's "Copy as
    # cURL" emits cookies with `-b` and a pasted browser command must not have its cookies
    # turned into a request body.
    #
    # WHAT COMES OUT is the request curl would put on the wire, minus the two headers curl adds
    # to identify ITSELF (`User-Agent: curl/…`, `Accept: */*`). Those describe the client that
    # ran the command, not the request the command describes — and the round trip needs them
    # gone: a capture without a User-Agent exports without a `-H` for one, and must not come
    # back carrying curl's. Everything a flag says is kept, measured against curl 8.7.1 on a
    # raw listener:
    #
    #   -H 'N: v'      the line exactly as typed, in argv order — spacing included (P7)
    #   -H 'N:'        curl's "do not send N": drops a header gori would otherwise add
    #   -H 'N;'        N with an empty value (`N:` on the wire)
    #   -d/--data*     the body; several are joined with `&`; POST unless -X says otherwise;
    #                  `Content-Type: application/x-www-form-urlencoded` after Content-Length
    #                  when no -H names one
    #   --json         the body joined with nothing, plus Content-Type/Accept: application/json
    #   -F/--form-string  a multipart body with a fresh boundary
    #   -G             the data goes to the query instead, as a GET
    #   -u, URL user:pass  `Authorization: Basic …`; a -H Authorization wins
    #   -A -e -b -r --compressed --oauth2-bearer  the header each one means
    #   -X             the method, verbatim — curl validates nothing here and neither does this
    #   --request-target  the request-target, verbatim
    #
    # Every header lands in the order its flag appears, with `Host:` synthesized first when
    # none is given and `Content-Length` synthesized last. That is the operator's order (the
    # browser's, for a copied command), and it is what makes the round trip exact.
    #
    # REFUSED, with the reason: a URL curl itself would refuse (whitespace, a control byte),
    # a non-http scheme, and anything that reads a LOCAL FILE (`-d @f`, `-F n=@f`, `-T`, `-K`,
    # `-H @f`) — the paste does not carry the file, and inventing its contents is not an option.
    #
    # IGNORED, and named: transport and output flags (`-k`, `-s`, `-L`, `-x`, `--resolve`,
    # timeouts…). gori sends through its own network settings, so these change nothing about
    # the request; each import reports which were dropped.
    module Curl
      # What one curl invocation would put on the wire, as gori stores it.
      class Request
        getter method : String
        getter scheme : String
        # Bracket-free (an IPv6 literal is `::1`, not `[::1]`), as every stored host is.
        getter host : String
        getter port : Int32
        getter target : String
        getter http_version : String
        getter head : Bytes
        getter body : Bytes?
        getter notes : Array(String)

        def initialize(@method, @scheme, @host, @port, @target, @http_version, @head, @body, @notes)
        end

        # `--http2` / `--http2-prior-knowledge`: send it over HTTP/2.
        def http2? : Bool
          @http_version == "HTTP/2"
        end

        # The whole request, head then body — what a Repeater session stores.
        def bytes : Bytes
          b = @body
          return @head if b.nil? || b.empty?
          io = IO::Memory.new(@head.size + b.size)
          io.write(@head)
          io.write(b)
          io.to_slice
        end

        def text : String
          String.new(bytes)
        end

        # `scheme://host[:port]` — the dial origin, the default port left out.
        def origin : String
          "#{@scheme}://#{Builder.host_header(@scheme, @host, @port)}"
        end

        # The origin plus the request-target, for a line that names the request.
        def url : String
          @target.starts_with?('/') ? "#{origin}#{@target}" : "#{origin}/#{@target}"
        end
      end

      # Every request the paste held, the refusals for the commands that could not become one
      # (in paste order), and the notes about the paste itself rather than any one request.
      record Parsed, requests : Array(Request), skipped : Array(String), notes : Array(String)

      # What a curl command line is taken to begin with: `curl`, a path to it, or Windows'
      # `curl.exe`.
      def self.curl_word?(word : String?) : Bool
        return false unless word
        base = word.split('/').last
        base == "curl" || base.compare("curl.exe", case_insensitive: true) == 0
      end

      # Does `text` start with a curl command? The first word, past a pasted `$ ` prompt.
      # For a surface that wants to route a paste; `parse` answers everything else.
      def self.command?(text : String) : Bool
        first = text.lstrip.lchop("$ ").lstrip
        curl_word?(first.split(/\s/, 2).first?)
      end

      # Every request in `text`. A paste that holds no curl command at all is accepted in one
      # shape more: a lone URL or bare host (`https://acme.test/p`, `acme.test`), taken as a GET
      # — `https://` when no scheme is written, the way `gori run import --urls` reads one
      # (curl itself would guess `http://`, and does so inside a curl command here too).
      #
      # `boundary` pins the multipart boundary, for a spec; otherwise each `-F` request gets a
      # fresh one, as curl does.
      def self.parse(text : String, boundary : String? = nil) : Parsed
        refuse_windows_cmd(text)
        commands = Shell.commands(text)
        requests = [] of Request
        skipped = [] of String
        notes = [] of String
        saw_curl = false
        commands.each do |cmd|
          words = cmd.words
          words = words[1..] if words.first?.in?("$", "%") # a pasted shell prompt
          first = words.first?
          next unless first
          unless curl_word?(first)
            notes << "ignored `#{first}` — not a curl command"
            next
          end
          saw_curl = true
          notes << "ignored a redirection (> file) — gori stores the request, it writes no output" if cmd.redirected
          begin
            split_next(words[1..]).each do |args|
              requests.concat(Invocation.new(args, boundary).requests)
            end
          rescue ex : Gori::Error
            skipped << (ex.message || "not a usable curl command")
          end
        end
        return Parsed.new(requests, skipped, notes) if saw_curl
        bare_url(commands) || raise Gori::Error.new("not a curl command — paste a command starting with `curl` (or a single URL)")
      end

      # The ONE request a paste must hold — the Repeater shape, where a session is one request.
      # The paste-level notes ride on it. Raises with the reason when there is none, or more
      # than one, or when any command in the paste was refused (half a paste is not the paste).
      def self.parse_one(text : String, boundary : String? = nil) : Request
        parsed = parse(text, boundary)
        if why = parsed.skipped.first?
          raise Gori::Error.new(why)
        end
        req = parsed.requests.first? || raise Gori::Error.new("the curl command names no URL")
        if parsed.requests.size > 1
          raise Gori::Error.new("the paste holds #{parsed.requests.size} requests — a Repeater session is one; " \
                                "paste one command (or import them all into History)")
        end
        req.notes.concat(parsed.notes)
        req
      end

      # Chrome's "Copy as cURL (cmd)" quotes with `^"` and continues lines with `^`, which a
      # POSIX splitter would read as a pile of carets. Refused by name rather than half-parsed.
      private def self.refuse_windows_cmd(text : String) : Nil
        return unless text.includes?("^\"") || text.each_line.any?(&.rstrip.ends_with?(" ^"))
        raise Gori::Error.new("this is Windows cmd syntax (^\" quoting, ^ line ends) — copy the request " \
                              "as \"cURL (bash)\" instead")
      end

      # `curl a --next -d x b` is two requests, each with its own options (curl's `-:`/`--next`).
      private def self.split_next(args : Array(String)) : Array(Array(String))
        groups = [[] of String]
        args.each do |a|
          if a == "--next" || a == "-:"
            groups << [] of String
          else
            groups.last << a
          end
        end
        groups.reject(&.empty?)
      end

      private def self.bare_url(commands : Array(Shell::Command)) : Parsed?
        return nil unless commands.size == 1 && commands[0].words.size == 1
        word = commands[0].words[0]
        return nil if word.starts_with?('-')
        inv = Invocation.new([word], nil, default_scheme: "https")
        Parsed.new(inv.requests, [] of String, [] of String)
      end

      # --- one invocation ------------------------------------------------------------------

      enum Op
        Url; Method; Header; Cookie; Data; DataBinary; DataRaw; DataUrlencode; Json
        Form; FormString; UrlQuery; Get; Head; User; UserAgent; Referer; Compressed; Range
        Bearer; Http10; Http11; Http2; Http2Prior; Http3; RequestTarget; PathAsIs; Globoff
        AuthOther; ReadsFile; Location; Ignore
      end

      record Spec, op : Op, arg : Bool

      # Every short option curl 8 has, so a cluster (`-sSLk`) and an attached value (`-XPOST`)
      # split where curl splits them. An option this table does not know is ignored AND named.
      SHORT = {
        '0' => Spec.new(Op::Http10, false), '1' => Spec.new(Op::Ignore, false),
        '2' => Spec.new(Op::Ignore, false), '3' => Spec.new(Op::Ignore, false),
        '4' => Spec.new(Op::Ignore, false), '6' => Spec.new(Op::Ignore, false),
        '#' => Spec.new(Op::Ignore, false), 'a' => Spec.new(Op::Ignore, false),
        'A' => Spec.new(Op::UserAgent, true), 'b' => Spec.new(Op::Cookie, true),
        'B' => Spec.new(Op::Ignore, false), 'c' => Spec.new(Op::Ignore, true),
        'C' => Spec.new(Op::Ignore, true), 'd' => Spec.new(Op::Data, true),
        'D' => Spec.new(Op::Ignore, true), 'e' => Spec.new(Op::Referer, true),
        'E' => Spec.new(Op::Ignore, true), 'f' => Spec.new(Op::Ignore, false),
        'F' => Spec.new(Op::Form, true), 'g' => Spec.new(Op::Globoff, false),
        'G' => Spec.new(Op::Get, false), 'h' => Spec.new(Op::Ignore, false),
        'H' => Spec.new(Op::Header, true), 'i' => Spec.new(Op::Ignore, false),
        'I' => Spec.new(Op::Head, false), 'j' => Spec.new(Op::Ignore, false),
        'J' => Spec.new(Op::Ignore, false), 'k' => Spec.new(Op::Ignore, false),
        'K' => Spec.new(Op::ReadsFile, true), 'l' => Spec.new(Op::Ignore, false),
        'L' => Spec.new(Op::Location, false), 'm' => Spec.new(Op::Ignore, true),
        'M' => Spec.new(Op::Ignore, false), 'n' => Spec.new(Op::Ignore, false),
        'N' => Spec.new(Op::Ignore, false), 'o' => Spec.new(Op::Ignore, true),
        'O' => Spec.new(Op::Ignore, false), 'p' => Spec.new(Op::Ignore, false),
        'P' => Spec.new(Op::Ignore, true), 'q' => Spec.new(Op::Ignore, false),
        'Q' => Spec.new(Op::Ignore, true), 'r' => Spec.new(Op::Range, true),
        'R' => Spec.new(Op::Ignore, false), 's' => Spec.new(Op::Ignore, false),
        'S' => Spec.new(Op::Ignore, false), 't' => Spec.new(Op::Ignore, true),
        'T' => Spec.new(Op::ReadsFile, true), 'u' => Spec.new(Op::User, true),
        'U' => Spec.new(Op::Ignore, true), 'v' => Spec.new(Op::Ignore, false),
        'V' => Spec.new(Op::Ignore, false), 'w' => Spec.new(Op::Ignore, true),
        'x' => Spec.new(Op::Ignore, true), 'X' => Spec.new(Op::Method, true),
        'y' => Spec.new(Op::Ignore, true), 'Y' => Spec.new(Op::Ignore, true),
        'z' => Spec.new(Op::Ignore, true), 'Z' => Spec.new(Op::Ignore, false),
      }

      # The long options that MEAN something for the request.
      LONG_MAPPED = {
        "url" => Spec.new(Op::Url, true), "request" => Spec.new(Op::Method, true),
        "header" => Spec.new(Op::Header, true), "cookie" => Spec.new(Op::Cookie, true),
        "data" => Spec.new(Op::Data, true), "data-ascii" => Spec.new(Op::Data, true),
        "data-binary" => Spec.new(Op::DataBinary, true), "data-raw" => Spec.new(Op::DataRaw, true),
        "data-urlencode" => Spec.new(Op::DataUrlencode, true), "json" => Spec.new(Op::Json, true),
        "form" => Spec.new(Op::Form, true), "form-string" => Spec.new(Op::FormString, true),
        "url-query" => Spec.new(Op::UrlQuery, true), "get" => Spec.new(Op::Get, false),
        "head" => Spec.new(Op::Head, false), "user" => Spec.new(Op::User, true),
        "user-agent" => Spec.new(Op::UserAgent, true), "referer" => Spec.new(Op::Referer, true),
        "compressed" => Spec.new(Op::Compressed, false), "range" => Spec.new(Op::Range, true),
        "oauth2-bearer" => Spec.new(Op::Bearer, true), "http1.0" => Spec.new(Op::Http10, false),
        "http1.1" => Spec.new(Op::Http11, false), "http2" => Spec.new(Op::Http2, false),
        "http2-prior-knowledge" => Spec.new(Op::Http2Prior, false),
        "http3" => Spec.new(Op::Http3, false), "http3-only" => Spec.new(Op::Http3, false),
        "request-target" => Spec.new(Op::RequestTarget, true),
        "path-as-is" => Spec.new(Op::PathAsIs, false), "globoff" => Spec.new(Op::Globoff, false),
        "basic" => Spec.new(Op::Ignore, false), "digest" => Spec.new(Op::AuthOther, false),
        "ntlm" => Spec.new(Op::AuthOther, false), "ntlm-wb" => Spec.new(Op::AuthOther, false),
        "negotiate" => Spec.new(Op::AuthOther, false), "anyauth" => Spec.new(Op::AuthOther, false),
        "aws-sigv4" => Spec.new(Op::AuthOther, true), "location" => Spec.new(Op::Location, false),
        "location-trusted" => Spec.new(Op::Location, false),
        "config" => Spec.new(Op::ReadsFile, true), "upload-file" => Spec.new(Op::ReadsFile, true),
      }

      # Transport, TLS, proxy, output and retry options that take a VALUE — they change how
      # curl runs, not what it sends, and gori dials through its own settings. Listed so their
      # value is not mistaken for the URL.
      LONG_IGNORED_ARG = %w[
        abstract-unix-socket alt-svc cacert capath cert cert-type ciphers connect-timeout
        connect-to continue-at cookie-jar create-file-mode crlfile curves delegation
        dns-interface dns-ipv4-addr dns-ipv6-addr dns-servers doh-url dump-header ech egd-file
        engine etag-compare etag-save expect100-timeout ftp-account ftp-alternative-to-user
        ftp-method ftp-port ftp-ssl-ccc-mode happy-eyeballs-timeout-ms haproxy-clientip
        hostpubmd5 hostpubsha256 hsts interface ip-tos ipfs-gateway keepalive-time key key-type
        krb libcurl limit-rate local-port login-options mail-auth mail-from mail-rcpt
        max-filesize max-redirs max-time netrc-file noproxy output output-dir parallel-max pass
        pinnedpubkey preproxy proto proto-default proto-redir proxy proxy-cacert proxy-capath
        proxy-cert proxy-cert-type proxy-ciphers proxy-crlfile proxy-header proxy-key
        proxy-key-type proxy-pass proxy-pinnedpubkey proxy-service-name proxy-tls13-ciphers
        proxy-tlsauthtype proxy-tlspassword proxy-tlsuser proxy-user proxy1.0 pubkey quote
        random-file rate resolve retry retry-delay retry-max-time sasl-authzid service-name
        socks4 socks4a socks5 socks5-gssapi-service socks5-hostname speed-limit speed-time
        stderr telnet-option tftp-blksize time-cond tls-max tls13-ciphers tlsauthtype
        tlspassword tlsuser trace trace-ascii trace-config unix-socket variable write-out
      ]

      # The same, taking no value.
      LONG_IGNORED_FLAG = %w[
        append ca-native cert-status clobber compressed-ssh create-dirs crlf disable
        disable-eprt disable-epsv disallow-username-in-url doh-cert-status doh-insecure
        fail fail-early fail-with-body false-start ftp-create-dirs ftp-pasv ftp-pret
        ftp-skip-pasv-ip ftp-ssl-control help http0.9 ignore-content-length include insecure
        ipv4 ipv6 junk-session-cookies list-only manual mptcp netrc netrc-optional
        no-alpn no-buffer no-clobber no-keepalive no-npn no-progress-meter no-sessionid
        parallel parallel-immediate progress-bar proxy-anyauth proxy-basic proxy-ca-native
        proxy-digest proxy-http2 proxy-insecure proxy-negotiate proxy-ntlm
        proxy-ssl-allow-beast proxy-ssl-auto-client-cert proxytunnel raw remote-header-name
        remote-name remote-name-all remove-on-error retry-all-errors retry-connrefused
        sasl-ir show-error silent skip-existing socks5-basic socks5-gssapi socks5-gssapi-nec
        ssl ssl-allow-beast ssl-auto-client-cert ssl-no-revoke ssl-reqd ssl-revoke-best-effort
        sslv2 sslv3 styled-output suppress-connect-headers tcp-fastopen tcp-nodelay
        tftp-no-options tlsv1 tlsv1.0 tlsv1.1 tlsv1.2 tlsv1.3 tr-encoding trace-ids trace-time
        use-ascii verbose version xattr
      ]

      def self.long_spec(name : String) : Spec?
        LONG_MAPPED[name]? ||
          (LONG_IGNORED_ARG.includes?(name) ? Spec.new(Op::Ignore, true) : nil) ||
          (LONG_IGNORED_FLAG.includes?(name) ? Spec.new(Op::Ignore, false) : nil)
      end

      # One multipart part: already-escaped name, optional filename/content-type, extra header
      # lines, and the content bytes.
      record FormPart, name : String, value : Bytes, type : String? = nil,
        filename : String? = nil, headers : Array(String) = [] of String

      # One header the command states, in argv order. `synth` marks one a FLAG implies (-A, -b,
      # --compressed …), which a `-H` naming the same field overrides, as it does in curl.
      record Item, name : String, line : String, synth : Bool

      # One curl invocation's options (a `--next` group), turned into its requests — one per
      # URL, since curl sends the same options to each.
      class Invocation
        @urls = [] of String
        @method : String? = nil
        @head = false
        @get = false
        @items = [] of Item
        @removed = Set(String).new
        @cookies = [] of String
        @cookie_slot : Int32? = nil
        @user : String? = nil
        @user_slot : Int32? = nil
        @auth_other = false
        @data = [] of Bytes
        @json = false
        @form = [] of FormPart
        @queries = [] of String
        @version = "HTTP/1.1"
        @request_target : String? = nil
        @path_as_is = false
        @globoff = false
        @ignored = [] of String
        @unknown = [] of String
        @notes = [] of String
        @follows_redirects = false

        def initialize(args : Array(String), @boundary : String? = nil, @default_scheme : String = "http")
          read(args)
        end

        def requests : Array(Request)
          raise Gori::Error.new("the curl command names no URL") if @urls.empty?
          if !@data.empty? && !@form.empty?
            raise Gori::Error.new("the command mixes -d and -F — curl refuses that too (one body shape per request)")
          end
          @urls.map { |u| build(u) }
        end

        private def read(args : Array(String)) : Nil
          i = 0
          only_urls = false
          while i < args.size
            a = args[i]
            i += 1
            if only_urls || !a.starts_with?('-') || a == "-"
              @urls << a
            elsif a == "--"
              only_urls = true
            elsif a.starts_with?("--")
              i = read_long(a, args, i)
            else
              i = read_short(a, args, i)
            end
          end
        end

        # `--name [value]`, or `--no-name` for a flag that takes none. curl has no `--name=value`
        # spelling, so neither does this. Returns the index of the next unread word.
        private def read_long(a : String, args : Array(String), i : Int32) : Int32
          name = a.byte_slice(2)
          spec = Curl.long_spec(name)
          negated = false
          if spec.nil? && name.starts_with?("no-") && (s = Curl.long_spec(name.byte_slice(3))) && !s.arg
            spec = s
            negated = true
          end
          unless spec
            @unknown << a
            return i
          end
          value = nil
          if spec.arg
            value = args[i]? || raise Gori::Error.new("#{a} needs a value")
            i += 1
          end
          apply(spec.op, a, value, negated)
          i
        end

        # A short cluster: `-sSk`, `-XPOST`, `-HX-A:1`. The first option that takes a value
        # takes the rest of the word, or the next word when nothing is left.
        private def read_short(a : String, args : Array(String), i : Int32) : Int32
          bytes = a.to_slice
          (1...bytes.size).each do |j|
            flag = "-#{bytes[j].unsafe_chr}"
            spec = SHORT[bytes[j].unsafe_chr]?
            unless spec
              @unknown << flag
              next
            end
            unless spec.arg
              apply(spec.op, flag, nil)
              next
            end
            rest = a.byte_slice(j + 1)
            if rest.empty?
              rest = args[i]? || raise Gori::Error.new("#{flag} needs a value")
              i += 1
            end
            apply(spec.op, flag, rest)
            break
          end
          i
        end

        private def apply(op : Op, flag : String, value : String?, negated : Bool = false) : Nil
          v = value || ""
          case op
          in Op::Url           then @urls << v
          in Op::Method        then @method = v
          in Op::Header        then header(v)
          in Op::Cookie        then cookie(v)
          in Op::Data          then @data << data_bytes(v, flag)
          in Op::DataBinary    then @data << data_bytes(v, flag)
          in Op::DataRaw       then @data << v.to_slice
          in Op::DataUrlencode then @data << Curl.urlencode_data(v, flag).to_slice
          in Op::Json          then json(v, flag)
          in Op::Form          then @form << Curl.form_part(v, @notes)
          in Op::FormString    then @form << Curl.form_string(v)
          in Op::UrlQuery      then @queries << Curl.url_query(v)
          in Op::Get           then @get = !negated
          in Op::Head          then @head = !negated
          in Op::User          then user(v)
          in Op::UserAgent     then v.empty? ? @removed << "user-agent" : synth("User-Agent", v)
          in Op::Referer       then synth("Referer", v.rchop(";auto"))
          in Op::Compressed    then synth("Accept-Encoding", "deflate, gzip") unless negated
          in Op::Range         then synth("Range", "bytes=#{v}")
          in Op::Bearer        then synth("Authorization", "Bearer #{v}")
          in Op::Http10        then @version = "HTTP/1.0"
          in Op::Http11        then @version = "HTTP/1.1"
          in Op::Http2         then @version = "HTTP/2"
          in Op::Http2Prior    then @version = "HTTP/2"
          in Op::Http3
            @version = "HTTP/1.1"
            @notes << "#{flag}: gori does not send HTTP/3 — imported as HTTP/1.1"
          in Op::RequestTarget then @request_target = v
          in Op::PathAsIs      then @path_as_is = !negated
          in Op::Globoff       then @globoff = !negated
          in Op::AuthOther
            @auth_other = true
            @notes << "#{flag}: that authentication scheme needs the server's challenge, so -u was not turned into a header"
          in Op::ReadsFile
            raise Gori::Error.new("#{flag} reads a local file, which the paste does not carry — " \
                                  "put its contents in the command instead")
          in Op::Location
            @ignored << flag unless @ignored.includes?(flag)
            @follows_redirects = true
          in Op::Ignore then @ignored << flag unless @ignored.includes?(flag)
          end
        end

        # `-H 'N: v'` keeps the line as typed. A blank value is curl's "don't send N"; `N;` is
        # N sent empty; a word with neither colon nor `;` is not a header, and curl drops it.
        private def header(v : String) : Nil
          if v.starts_with?('@')
            raise Gori::Error.new("-H #{v} reads headers from a local file, which the paste does not carry")
          end
          name, sep, rest = v.partition(':')
          if sep.empty?
            if v.ends_with?(';') && v.size > 1
              n = v.rchop(';')
              @items << Item.new(n.strip, "#{n}:", false)
            else
              @notes << "ignored -H #{v.inspect} — not `Name: value` (curl drops it too)"
            end
            return
          end
          if rest.strip(" \t").empty?
            @removed << name.strip.downcase
            return
          end
          @items << Item.new(name.strip, v, false)
        end

        # Every `-b` joins ONE Cookie header (`;`, no space — curl's join), placed at the first.
        # A `-b` without `=` names a cookie-jar FILE to read, which is not a request header.
        private def cookie(v : String) : Nil
          unless v.includes?('=')
            @notes << "ignored -b #{v.inspect} — that is a cookie-jar file, not a cookie"
            return
          end
          @cookies << v
          @cookie_slot ||= begin
            @items << Item.new("Cookie", "", true)
            @items.size - 1
          end
        end

        private def user(v : String) : Nil
          @user = v
          @user_slot ||= begin
            @items << Item.new("Authorization", "", true)
            @items.size - 1
          end
        end

        private def synth(name : String, value : String) : Nil
          @items << Item.new(name, "#{name}: #{value}", true)
        end

        private def json(v : String, flag : String) : Nil
          @data << data_bytes(v, flag)
          return if @json
          @json = true
          synth("Content-Type", "application/json")
          synth("Accept", "application/json")
        end

        # `-d @file` / `--data-binary @file` read a file; literally, the bytes are the body.
        private def data_bytes(v : String, flag : String) : Bytes
          if v.starts_with?('@')
            raise Gori::Error.new("#{flag} #{v} reads the body from a local file, which the paste does " \
                                  "not carry — put the body in the command (or use --data-raw for a literal @)")
          end
          v.to_slice
        end

        private def build(raw_url : String) : Request
          notes = @notes.dup
          u = Curl.parse_url(raw_url, @default_scheme)
          url_notes(raw_url, u, notes)
          body, form_boundary = body_bytes
          target = request_target(u)
          method = @method || default_method(body)
          head = String.build do |io|
            io << method << ' ' << target << ' ' << @version << "\r\n"
            header_lines(u, body, form_boundary, notes).each { |l| io << l << "\r\n" }
            io << "\r\n"
          end
          run_notes(notes)
          Request.new(method, u.scheme, u.host, u.port, target, @version, head.to_slice, body, notes)
        end

        # What curl would have done to this URL that gori does not.
        private def url_notes(raw_url : String, u : Curl::Url, notes : Array(String)) : Nil
          if !@globoff && raw_url.each_char.any?(&.in?('[', ']', '{', '}')) && !u.ipv6?
            notes << "the URL holds [ ] or { }: curl would expand them as a glob unless -g; gori takes the URL literally"
          end
          if !@path_as_is && u.dot_segments?
            notes << "the path holds . or .. segments: curl would collapse them unless --path-as-is; gori keeps the path as written"
          end
        end

        # What the command asked of curl's RUN that the stored request cannot carry.
        private def run_notes(notes : Array(String)) : Nil
          notes << "redirects are not followed (-L) — this is the first request only" if @follows_redirects
          unless @ignored.empty?
            notes << "ignored (gori sends through its own network settings): #{@ignored.join(", ")}"
          end
          @unknown.uniq.each { |f| notes << "ignored unknown option #{f}" }
        end

        # --request-target verbatim, else the URL's, with -G data and --url-query appended.
        private def request_target(u : Curl::Url) : String
          if verbatim = @request_target
            return verbatim
          end
          query = @get && !@data.empty? ? [String.new(joined_data)] + @queries : @queries
          return u.target if query.empty?
          "#{u.target}#{u.target.includes?('?') ? '&' : '?'}#{query.join('&')}"
        end

        # -I is HEAD, -G is GET, a body is POST, and nothing is GET — when -X said nothing.
        private def default_method(body : Bytes?) : String
          return "HEAD" if @head
          return "GET" if @get
          body ? "POST" : "GET"
        end

        # {body, multipart boundary}. -G moves the data to the query, so there is no body then.
        private def body_bytes : {Bytes?, String?}
          unless @form.empty?
            b = @boundary || Curl.new_boundary
            return {Curl.multipart(@form, b), b}
          end
          return {nil, nil} if @data.empty? || @get
          {joined_data, nil}
        end

        private def joined_data : Bytes
          sep = @json ? "" : "&"
          io = IO::Memory.new
          @data.each_with_index do |d, i|
            io << sep if i > 0
            io.write(d)
          end
          io.to_slice
        end

        # Host first (unless stated or removed), URL-userinfo auth next, every argv header in
        # order, then the body's framing. A header a FLAG implies loses to a -H of the same name.
        private def header_lines(u : Curl::Url, body : Bytes?, boundary : String?, notes : Array(String)) : Array(String)
          stated = @items.reject(&.synth).map(&.name.downcase).to_set
          omitted = ->(name : String) { stated.includes?(name) || @removed.includes?(name) }
          lines = [] of String
          lines << "Host: #{Builder.host_header(u.scheme, u.host, u.port)}" unless omitted.call("host")
          if (ui = u.userinfo) && @user.nil? && !@auth_other && !omitted.call("authorization")
            lines << "Authorization: Basic #{Base64.strict_encode(ui)}"
          end
          @items.each_with_index do |it, idx|
            next if it.synth && omitted.call(it.name.downcase)
            line = item_line(it, idx, boundary, notes)
            lines << line if line
          end
          body_framing(lines, body, boundary, stated, omitted)
          lines
        end

        # One argv header's line: the joined Cookie / the -u Basic at their slots, a stated
        # multipart Content-Type given the body's boundary, or the line as typed.
        private def item_line(it : Item, idx : Int32, boundary : String?, notes : Array(String)) : String?
          return "Cookie: #{@cookies.join(';')}" if it.synth && idx == @cookie_slot
          return (@auth_other ? nil : basic_line(notes)) if it.synth && idx == @user_slot
          if boundary && !it.synth && it.name.downcase == "content-type" && !it.line.includes?("boundary=")
            notes << "-F: the stated multipart Content-Type got the body's boundary, as curl adds it"
            return "#{it.line}; boundary=#{boundary}"
          end
          it.line
        end

        # Content-Length, then curl's default Content-Type — after every stated header, which is
        # where curl writes them.
        private def body_framing(lines : Array(String), body : Bytes?, boundary : String?,
                                 stated : Set(String), omitted : Proc(String, Bool)) : Nil
          return unless body
          unless omitted.call("content-length") || stated.includes?("transfer-encoding")
            lines << "Content-Length: #{body.size}"
          end
          return if omitted.call("content-type") || @json
          lines << (boundary ? "Content-Type: multipart/form-data; boundary=#{boundary}" : "Content-Type: application/x-www-form-urlencoded")
        end

        private def basic_line(notes : Array(String)) : String
          cred = @user || ""
          unless cred.includes?(':')
            notes << "-u #{cred.inspect} has no password: curl would prompt for one; encoded with an empty password"
            cred = "#{cred}:"
          end
          "Authorization: Basic #{Base64.strict_encode(cred)}"
        end
      end

      # --- the URL, curl-style ----------------------------------------------------------------

      # The parts of a curl URL argument: scheme, bracket-free host, port, the request-target
      # (fragment gone — curl never sends it), the decoded `user:pass` if the authority held one.
      record Url, scheme : String, host : String, port : Int32, target : String, userinfo : String? do
        def ipv6? : Bool
          host.includes?(':')
        end

        def dot_segments? : Bool
          path = target.split('?', 2).first
          path.split('/').any? { |seg| seg == "." || seg == ".." }
        end
      end

      # Byte-wise, and the request-target is kept AS WRITTEN (no percent-encoding, no dot
      # collapse): those are the operator's bytes. What curl refuses is refused — a scheme that
      # is not http(s), a missing host, a bad port, whitespace or a control byte in the target.
      def self.parse_url(raw : String, default_scheme : String = "http") : Url
        scheme, s = split_scheme(raw, default_scheme)
        bytes = s.to_slice
        cut = bytes.index { |b| b == 0x2f_u8 || b == 0x3f_u8 || b == 0x23_u8 } || bytes.size
        authority = s.byte_slice(0, cut)
        userinfo = nil
        if at = authority.to_slice.rindex(0x40_u8)
          userinfo = URI.decode(authority.byte_slice(0, at))
          authority = authority.byte_slice(at + 1)
        end
        host, port_s = split_host_port(authority, raw)
        if host.empty? || !host.matches?(Builder::HOST_VALID)
          raise Gori::Error.new("no usable host in #{raw.inspect}")
        end
        port = url_port(port_s, scheme, raw)
        host = host[1..-2] if host.starts_with?('[') && host.ends_with?(']')
        Url.new(scheme, host, port, url_target(s.byte_slice(cut), raw), userinfo)
      end

      # {scheme, the rest}. A URL with no `scheme://` gets `default` — curl's guess is http.
      private def self.split_scheme(raw : String, default : String) : {String, String}
        scheme = default
        rest = raw
        if (sep = raw.byte_index("://")) && raw.byte_slice(0, sep).matches?(/\A[A-Za-z][A-Za-z0-9+.-]*\z/)
          scheme = raw.byte_slice(0, sep).downcase
          rest = raw.byte_slice(sep + 3)
        end
        unless scheme.in?("http", "https")
          raise Gori::Error.new("unsupported scheme #{scheme}:// in #{raw.inspect} — gori speaks http and https")
        end
        {scheme, rest}
      end

      private def self.url_port(port_s : String, scheme : String, raw : String) : Int32
        return scheme == "https" ? 443 : 80 if port_s.empty?
        port = port_s.to_i? if port_s.each_char.all?(&.ascii_number?)
        raise Gori::Error.new("invalid port in #{raw.inspect}") unless port && 1 <= port <= 65535
        port
      end

      # The path and query as the request-target: the fragment dropped (curl never sends it),
      # `/` for nothing, `/?q` for a bare query, and refused when it holds a byte that would
      # break the request line — curl refuses those URLs too.
      private def self.url_target(tail : String, raw : String) : String
        if frag = tail.byte_index('#')
          tail = tail.byte_slice(0, frag)
        end
        target = tail.empty? ? "/" : (tail.starts_with?('?') ? "/#{tail}" : tail)
        unless Proxy::Codec::Http1.request_token_safe?(target)
          raise Gori::Error.new("the URL #{raw.inspect} holds whitespace or a control byte, which curl " \
                                "refuses too — percent-encode it, or pass the exact bytes with --request-target")
        end
        target
      end

      private def self.split_host_port(authority : String, raw : String) : {String, String}
        if authority.starts_with?('[')
          close = authority.byte_index(']') || raise Gori::Error.new("unterminated IPv6 literal in #{raw.inspect}")
          rest = authority.byte_slice(close + 1)
          port = rest.starts_with?(':') ? rest.byte_slice(1) : ""
          raise Gori::Error.new("invalid port in #{raw.inspect}") unless rest.empty? || rest.starts_with?(':')
          return {authority.byte_slice(0, close + 1), port}
        end
        if colon = authority.to_slice.rindex(0x3a_u8)
          return {authority.byte_slice(0, colon), authority.byte_slice(colon + 1)}
        end
        {authority, ""}
      end

      # --- data encodings -----------------------------------------------------------------------

      # curl's --data-urlencode escaping, measured: A-Z a-z 0-9 - . _ ~ as themselves, a space
      # as `+`, every other byte as `%XX` (upper-case hex).
      def self.form_escape(bytes : Bytes) : String
        String.build do |io|
          bytes.each do |b|
            if (0x41_u8 <= b <= 0x5a_u8) || (0x61_u8 <= b <= 0x7a_u8) || (0x30_u8 <= b <= 0x39_u8) ||
               b == 0x2d_u8 || b == 0x2e_u8 || b == 0x5f_u8 || b == 0x7e_u8
              io.write_byte(b)
            elsif b == 0x20_u8
              io << '+'
            else
              io << '%' << b.to_s(16, upcase: true).rjust(2, '0')
            end
          end
        end
      end

      # `--data-urlencode`'s four shapes: `content`, `=content`, `name=content`, and the two
      # that read a file (`@f`, `name@f`), which are refused.
      def self.urlencode_data(v : String, flag : String) : String
        return form_escape(v.byte_slice(1).to_slice) if v.starts_with?('=')
        if eq = v.byte_index('=')
          return "#{v.byte_slice(0, eq)}=#{form_escape(v.byte_slice(eq + 1).to_slice)}"
        end
        if v.includes?('@')
          raise Gori::Error.new("#{flag} #{v} reads a local file, which the paste does not carry")
        end
        form_escape(v.to_slice)
      end

      # `--url-query`: --data-urlencode's shapes, plus `+content` for "already encoded".
      def self.url_query(v : String) : String
        return v.byte_slice(1) if v.starts_with?('+')
        urlencode_data(v, "--url-query")
      end

      # `-F name=content[;type=…][;filename=…][;headers=…]`. A value in double quotes may hold
      # `;`; an unquoted one ends at the first `;` and what follows is read as parameters, the
      # unknown ones dropped — curl sends `-F 'n=a;b'` as `a`. `@f` and `<f` read a file.
      def self.form_part(v : String, notes : Array(String)) : FormPart
        eq = v.byte_index('=') || raise Gori::Error.new("-F #{v.inspect} is not name=content")
        name = v.byte_slice(0, eq)
        content = v.byte_slice(eq + 1)
        if content.starts_with?('@') || content.starts_with?('<')
          raise Gori::Error.new("-F #{v} reads a local file, which the paste does not carry — " \
                                "give the part's content inline (or use --form-string)")
        end
        value, params = if content.starts_with?('"')
                          quoted_form_value(content)
                        else
                          semi = content.byte_index(';')
                          semi ? {content.byte_slice(0, semi), content.byte_slice(semi)} : {content, ""}
                        end
        type = nil
        filename = nil
        headers = [] of String
        params.split(';').each do |param|
          next if param.empty?
          key, _, val = param.partition('=')
          case key.strip.downcase
          when "type"     then type = val
          when "filename" then filename = val
          when "headers"  then headers << val
          when "encoder"  then nil
          else                 notes << "-F #{name}: dropped `;#{param}` (curl reads text after `;` as part parameters)"
          end
        end
        FormPart.new(form_name(name), value.to_slice, type, filename.try { |f| form_name(f) }, headers)
      end

      # `--form-string name=value`: the value verbatim, no parameter parsing, no file reading.
      def self.form_string(v : String) : FormPart
        eq = v.byte_index('=') || raise Gori::Error.new("--form-string #{v.inspect} is not name=value")
        FormPart.new(form_name(v.byte_slice(0, eq)), v.byte_slice(eq + 1).to_slice)
      end

      private def self.quoted_form_value(content : String) : {String, String}
        bytes = content.to_slice
        io = IO::Memory.new
        i = 1
        while i < bytes.size
          b = bytes[i]
          if b == 0x5c_u8 && i + 1 < bytes.size && (bytes[i + 1] == 0x22_u8 || bytes[i + 1] == 0x5c_u8)
            io.write_byte(bytes[i + 1])
            i += 2
            next
          end
          return {String.new(io.to_slice), content.byte_slice(i + 1)} if b == 0x22_u8
          io.write_byte(b)
          i += 1
        end
        raise Gori::Error.new("-F value #{content.inspect} has an unterminated quote")
      end

      # A part name or filename inside `name="…"`: a quote or line break percent-escaped, the
      # way curl (and browsers) write them.
      private def self.form_name(s : String) : String
        s.gsub('"', "%22").gsub('\r', "%0D").gsub('\n', "%0A")
      end

      # A boundary in curl's shape: 24 dashes and 22 random alphanumerics.
      def self.new_boundary : String
        alnum = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        "------------------------#{String.build { |io| 22.times { io << alnum[Random::Secure.rand(alnum.size)] } }}"
      end

      def self.multipart(parts : Array(FormPart), boundary : String) : Bytes
        io = IO::Memory.new
        parts.each do |part|
          io << "--" << boundary << "\r\n"
          io << "Content-Disposition: form-data; name=\"" << part.name << '"'
          part.filename.try { |f| io << "; filename=\"" << f << '"' }
          io << "\r\n"
          part.type.try { |t| io << "Content-Type: " << t << "\r\n" }
          part.headers.each { |h| io << h << "\r\n" }
          io << "\r\n"
          io.write(part.value)
          io << "\r\n"
        end
        io << "--" << boundary << "--\r\n"
        io.to_slice
      end
    end
  end
end
