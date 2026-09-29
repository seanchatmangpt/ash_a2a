defmodule AshA2A.Egress.EndpointPolicyTest do
  use ExUnit.Case, async: true
  alias AshA2A.Egress.EndpointPolicy

  test "admits a public literal over https and pins request to the IP with original host" do
    assert {:ok, admitted} = EndpointPolicy.admit("https://93.184.216.34:8443/base")
    opts = EndpointPolicy.request_options(admitted, "/ocel/events")
    assert opts[:url] == "https://93.184.216.34:8443/base/ocel/events"
    assert opts[:redirect] == false
    assert {"host", "93.184.216.34:8443"} in opts[:headers]
  end

  test "resolved hostnames are pinned to the admitted address, hostname kept for TLS" do
    resolver = fn
      _h, :inet -> {:ok, [{93, 184, 216, 34}]}
      _h, :inet6 -> {:error, :nxdomain}
    end

    assert {:ok, admitted} =
             EndpointPolicy.admit("https://collector.example/x", resolver: resolver)

    opts = EndpointPolicy.request_options(admitted, "/ocel/events")
    assert opts[:url] =~ "https://93.184.216.34/x/ocel/events"
    assert opts[:connect_options][:hostname] == "collector.example"
  end

  test "refuses when any resolved address is private (DNS rebinding mix)" do
    resolver = fn
      _h, :inet -> {:ok, [{93, 184, 216, 34}, {10, 0, 0, 5}]}
      _h, _ -> {:error, :nxdomain}
    end

    assert {:error, :refused_webhook_private_address, _} =
             EndpointPolicy.admit("https://mixed.example", resolver: resolver)
  end

  test "refuses non-string, userinfo, and http" do
    assert {:error, :refused_webhook_malformed, _} = EndpointPolicy.admit(nil)

    assert {:error, :refused_webhook_malformed, _} =
             EndpointPolicy.admit("https://u:p@93.184.216.34")

    assert {:error, :refused_webhook_scheme, _} = EndpointPolicy.admit("http://93.184.216.34")
  end
end

defmodule AshA2A.Egress.EndpointPolicyUserinfoTest do
  use ExUnit.Case, async: true
  alias AshA2A.Egress.EndpointPolicy

  test "userinfo is refused by default and, when allowed, moves to a Basic header off the URL" do
    assert {:error, :refused_webhook_malformed, _} =
             EndpointPolicy.admit("https://u:p@93.184.216.34")

    assert {:ok, a} = EndpointPolicy.admit("https://u:p@93.184.216.34", allow_userinfo: true)
    opts = EndpointPolicy.request_options(a, "/x")
    refute opts[:url] =~ "u:p"
    assert {"authorization", "Basic " <> Base.encode64("u:p")} in opts[:headers]
  end
end
