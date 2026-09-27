require "../../spec_helper"

# Not bound by the stdlib: the objects (certificates, CRLs) an X509 store holds.
lib LibCrypto
  fun x509_store_get0_objects = X509_STORE_get0_objects(store : X509_STORE) : Void*
end

private def store_object_count(ctx : OpenSSL::SSL::Context) : Int32
  store = LibSSL.ssl_ctx_get_cert_store(ctx.to_unsafe)
  objects = LibCrypto.x509_store_get0_objects(store)
  objects.null? ? 0 : LibCrypto.sk_num(objects)
end

describe Gori::Proxy::Tls::ContextFactory do
  describe ".lean_server" do
    # The lean context re-spells what the stdlib's `Server.new` sets, minus the system CA
    # bundle. Compared against a live stdlib context so a Crystal upgrade that changes those
    # defaults fails here instead of quietly diverging.
    it "matches a stdlib Server.new context in everything but the verify paths" do
      lean = Gori::Proxy::Tls::ContextFactory.lean_server
      stdlib = OpenSSL::SSL::Context::Server.new
      lean.options.should eq(stdlib.options)
      lean.modes.should eq(stdlib.modes)
      lean.verify_mode.should eq(stdlib.verify_mode)
      lean.security_level.should eq(stdlib.security_level)
    end

    it "does not load a CA store into the context" do
      store_object_count(Gori::Proxy::Tls::ContextFactory.lean_server).should eq(0)
    end
  end

  describe ".server_context" do
    it "builds a leaf context on the lean base that still serves a verified handshake" do
      root, root_key = Gori::Proxy::Tls::CertBuilder.build_root("gori ctx spec")
      leaf, leaf_key = Gori::Proxy::Tls::CertBuilder.build_leaf("ctx.test", root, root_key)
      ctx = Gori::Proxy::Tls::ContextFactory.server_context(leaf, leaf_key, ca_cert: root, advertise_h2: true)
      store_object_count(ctx).should eq(0)

      server = TCPServer.new("127.0.0.1", 0)
      port = server.local_address.port
      done = Channel(String).new(2)
      spawn do
        ssl = OpenSSL::SSL::Socket::Server.new(server.accept, ctx, sync_close: true)
        done.send(ssl.alpn_protocol || "none")
        ssl.close
      rescue ex
        done.send("server-error: #{ex.message}")
      end

      client_ctx = OpenSSL::SSL::Context::Client.new
      LibCrypto.x509_store_add_cert(LibSSL.ssl_ctx_get_cert_store(client_ctx.to_unsafe), root.handle)
      client_ctx.alpn_protocol = "h2"
      begin
        ssl = OpenSSL::SSL::Socket::Client.new(TCPSocket.new("127.0.0.1", port), context: client_ctx,
          sync_close: true, hostname: "ctx.test")
        ssl.close rescue nil
      rescue ex
        done.send("client-error: #{ex.message}")
      end
      done.receive.should eq("h2")
      server.close
    end
  end
end
