require "../../spec_helper"
require "../../support/probe_harness"

private def xdomain(store, body : String)
  probe_analyze(store, resp_head: "HTTP/1.1 200 OK\r\nContent-Type: text/xml\r\n\r\n",
    content_type: "text/xml", body: body)
end

describe Gori::Probe::Passive::OpenCrossDomainPolicy do
  it "flags a wildcard Flash cross-domain policy" do
    with_store do |store|
      body = %(<?xml version="1.0"?><cross-domain-policy><allow-access-from domain="*"/></cross-domain-policy>)
      probe_codes_of(xdomain(store, body)).should contain("open_cross_domain_policy")
    end
  end

  it "flags a wildcard Silverlight client-access policy" do
    with_store do |store|
      body = %(<access-policy><cross-domain-access><policy><allow-from><domain uri="*"/></allow-from></policy></cross-domain-access></access-policy>)
      probe_codes_of(xdomain(store, body)).should contain("open_cross_domain_policy")
    end
  end

  it "does not flag a policy scoped to specific origins" do
    with_store do |store|
      body = %(<cross-domain-policy><allow-access-from domain="*.example.com"/><allow-access-from domain="cdn.trusted.test"/></cross-domain-policy>)
      probe_codes_of(xdomain(store, body)).should_not contain("open_cross_domain_policy")
    end
  end

  it "does not flag a page that merely mentions crossdomain in prose" do
    with_store do |store|
      probe_codes_of(probe_analyze_html(store,
        %(<p>We serve a crossdomain.xml with domain="*" for legacy clients — see docs.</p>)))
        .should_not contain("open_cross_domain_policy")
    end
  end
end
