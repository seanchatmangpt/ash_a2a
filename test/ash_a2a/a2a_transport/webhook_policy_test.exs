defmodule AshA2A.A2ATransport.WebhookPolicyTest do
  @moduledoc """
  SSRF admission for push webhook URLs. IP-literal hosts and `localhost`
  exercise the real `:inet` resolver. One test injects a fixed resolver
  function: real DNS answers for a public name are nondeterministic and
  network-dependent, and the property under test (a name whose *any* answer
  is private is refused) needs a pinned multi-address answer.
  """
  use ExUnit.Case, async: true

  alias AshA2A.A2ATransport.WebhookPolicy

  test "public https IP literal is admitted with its address" do
    assert {:ok, %{addresses: [{93, 184, 215, 14}]}} =
             WebhookPolicy.admit("https://93.184.215.14/hook")
  end

  test "http is refused unless allow_http" do
    assert {:error, :refused_webhook_scheme, _} = WebhookPolicy.admit("http://93.184.215.14/hook")
    assert {:ok, _} = WebhookPolicy.admit("http://93.184.215.14/hook", allow_http: true)
  end

  for ip <-
        ~w(127.0.0.1 10.9.9.9 172.16.0.1 172.31.255.255 192.168.1.1 169.254.169.254 100.64.0.1 0.0.0.0 224.0.0.1 255.255.255.255) do
    test "IPv4 #{ip} is refused" do
      assert {:error, :refused_webhook_private_address, _} =
               WebhookPolicy.admit("https://#{unquote(ip)}/")
    end
  end

  for ip <- ~w(::1 :: fe80::1 fd00::1 ::ffff:127.0.0.1 ::ffff:10.0.0.1 ff02::1) do
    test "IPv6 #{ip} is refused" do
      assert {:error, :refused_webhook_private_address, _} =
               WebhookPolicy.admit("https://[#{unquote(ip)}]/")
    end
  end

  test "172.32.0.1 (outside 172.16/12) is public" do
    assert {:ok, _} = WebhookPolicy.admit("https://172.32.0.1/")
  end

  test "localhost resolves (real resolver) to loopback and is refused" do
    assert {:error, :refused_webhook_private_address, _} =
             WebhookPolicy.admit("https://localhost/")
  end

  test "allow_cidrs admits exactly the listed range" do
    assert {:ok, _} =
             WebhookPolicy.admit("http://127.0.0.1:4000/",
               allow_http: true,
               allow_cidrs: ["127.0.0.1/32"]
             )

    assert {:error, :refused_webhook_private_address, _} =
             WebhookPolicy.admit("http://127.0.0.2:4000/",
               allow_http: true,
               allow_cidrs: ["127.0.0.1/32"]
             )
  end

  test "a name with any private answer is refused (pinned resolver)" do
    resolver = fn
      ~c"mixed.example", :inet -> {:ok, [{93, 184, 215, 14}, {10, 0, 0, 1}]}
      _, _ -> {:error, :nxdomain}
    end

    assert {:error, :refused_webhook_private_address, detail} =
             WebhookPolicy.admit("https://mixed.example/", resolver: resolver)

    assert detail =~ "10.0.0.1"
  end

  test "unresolvable, userinfo, hostless and non-string URLs are refused" do
    resolver = fn _, _ -> {:error, :nxdomain} end

    assert {:error, :refused_webhook_unresolvable, _} =
             WebhookPolicy.admit("https://nope.invalid/", resolver: resolver)

    assert {:error, :refused_webhook_malformed, _} =
             WebhookPolicy.admit("https://u:p@93.184.215.14/")

    assert {:error, :refused_webhook_malformed, _} = WebhookPolicy.admit("https:///path")
    assert {:error, :refused_webhook_malformed, _} = WebhookPolicy.admit(nil)

    assert {:error, :refused_webhook_malformed, _} =
             WebhookPolicy.admit("https://1.1.1.1/", allow_cidrs: ["bogus"])
  end

  test "every returned refusal code is classified (S42)" do
    classified = WebhookPolicy.__sa2a_refusal_codes__()

    for code <-
          ~w(refused_webhook_malformed refused_webhook_scheme refused_webhook_unresolvable refused_webhook_private_address)a do
      assert Map.has_key?(classified, code)
    end
  end
end
