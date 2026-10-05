# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.Test.CardVerifyFixture do
  @moduledoc """
  Real ETS-backed `Ash.Resource` fixture for
  `test/ash_a2a_client_card_verify_test.exs` (lane W9) — a genuine
  `Ash.Resource` with `extensions: [AshA2A]` and one real `a2a do skill ...
  end` declaration, plus its `Ash.Domain`, so `AshA2A.Info.agent_card/2`
  builds the card from the same compiled capability index the runtime
  serves. Defined inside the test file itself (owned-file constraint);
  no mocks anywhere.
  """

  use Ash.Resource,
    domain: AshA2A.Test.CardVerifyFixture.Domain,
    data_layer: Ash.DataLayer.Ets,
    extensions: [AshA2A]

  attributes do
    uuid_primary_key(:id)
    attribute(:utterance, :string, public?: true)
  end

  actions do
    defaults([:read])
  end

  a2a do
    skill(:echo, :read)
  end
end

defmodule AshA2A.Test.CardVerifyFixture.Domain do
  @moduledoc """
  Real fixture domain pairing `AshA2A.Test.CardVerifyFixture` so
  `AshA2A.Info.agent_card/2` has a real, verified capability index to build
  the card from.
  """

  use Ash.Domain, extensions: [AshA2A]

  resources do
    resource(AshA2A.Test.CardVerifyFixture)
  end
end

defmodule AshA2A.Protocol.ClientCardVerifyTest do
  @moduledoc """
  Real end-to-end court for client-side card signature verification on the
  `AshA2A.Protocol.Client.discover/2` path (lane W9): a REAL Bandit HTTP
  server serves a REAL signed card — a card built from a real fixture
  resource's capability index and signed with
  `AshA2A.Protocol.CardSigning.sign/3` — over the wire, and the real `Req`
  client verifies it post-decode. Zero mocks.
  """

  use ExUnit.Case, async: false

  @moduletag :serial
  @moduletag :serial_shard

  alias AshA2A.Protocol.CardSigning
  alias AshA2A.Protocol.Client
  alias AshA2A.Test.EphemeralHttp

  @resource AshA2A.Test.CardVerifyFixture

  @key :crypto.strong_rand_bytes(32)
  @wrong_key :crypto.strong_rand_bytes(32)

  defmodule Store do
    @moduledoc """
    Real shared server state: the serving mode (`:signed`, `:tampered`, or
    `:unsigned`) and the signed card each mode serves from.
    """

    defstruct [:signed_card, mode: :signed]
  end

  defmodule CardServer do
    @moduledoc """
    Real Plug.Router serving the agent card. In `:tampered` mode the card is
    re-encoded with one byte of its description flipped AFTER signing, so the
    wire body no longer matches the signature's digest. In `:unsigned` mode
    the `signatures` member is stripped from the wire body entirely.
    """

    use Plug.Router

    plug(:match)
    plug(:dispatch)

    get "/.well-known/agent-card.json" do
      %{mode: mode, signed_card: signed_card} =
        Agent.get(AshA2A.Protocol.ClientCardVerifyTest.Store, & &1)

      body_map =
        case mode do
          :tampered ->
            [skill | rest] = signed_card.skills

            tampered = %{
              signed_card
              | description: AshA2A.Protocol.ClientCardVerifyTest.flip_byte(signed_card.description),
                skills: [
                  %{skill | description: AshA2A.Protocol.ClientCardVerifyTest.flip_byte(skill.description)}
                  | rest
                ]
            }

            AshA2A.Protocol.JSON.encode_agent_card(tampered, url: tampered.url)

          :unsigned ->
            signed_card
            |> AshA2A.Protocol.JSON.encode_agent_card(url: signed_card.url)
            |> Map.drop(["signatures"])

          :signed ->
            AshA2A.Protocol.JSON.encode_agent_card(signed_card, url: signed_card.url)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body_map))
    end

    match _ do
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(404, Jason.encode!(%{"error" => "not_found"}))
    end
  end

  # Flips one byte (the case of the first ASCII letter) of a description
  # string — a minimal post-signing content mutation that still decodes.
  def flip_byte(<<first::utf8, rest::binary>>) do
    flipped =
      cond do
        first in ?a..?z -> first - 32
        first in ?A..?Z -> first + 32
        true -> first
      end

    <<flipped::utf8, rest::binary>>
  end

  setup do
    # NOTE (cross-lane finding): the v1.0 wire codec (`AshA2A.Protocol.JSON
    # .encode_agent_card/2` in lib/ash_a2a/protocol/json.ex) does not emit a
    # top-level `protocolVersion` member -- it lives only inside
    # `supportedInterfaces[].protocolVersion` -- so `decode_agent_card`
    # restores `protocol_version: nil` on the client. Signing the runtime
    # card with protocol_version "1.0" therefore produces a card whose
    # signature can never verify post-decode (digest_mismatch on exactly
    # that field). Until the codec preserves the member end to end, the
    # fixture signs the card in its wire-stable shape (protocol_version nil,
    # i.e. exactly the content the wire carries and the client decodes).
    card =
      @resource
      |> AshA2A.Info.agent_card(name: "card_verify_fixture_agent")
      |> then(&%{&1 | protocol_version: nil})
      |> CardSigning.sign(@key)

    assert [%{"protected" => _, "signature" => _}] = card.signatures

    start_supervised!(
      %{
        id: Store,
        start: {Agent, :start_link, [fn -> %Store{signed_card: card} end, [name: Store]]}
      },
      shutdown: 1_000
    )

    server = EphemeralHttp.start!(CardServer)

    %{card: card, server: server, url: server.base_url}
  end

  defp set_mode(mode) do
    Agent.update(Store, &%{&1 | mode: mode})
  end

  describe "discover/2 with verify_card_signature over REAL HTTP" do
    test "right key verifies the real signed card served over the wire", %{url: url} do
      assert {:ok, card} = Client.discover(url, verify_card_signature: @key)
      assert [%{"protected" => _, "signature" => _}] = card.signatures
      assert CardSigning.verify(card, @key) == :ok
    end

    test "wrong key is fail-closed {:error, {:card_signature, {:bad_signature, %{index: 0}}}}", %{
      url: url
    } do
      assert {:error, {:card_signature, {:bad_signature, %{index: 0}}}} =
               Client.discover(url, verify_card_signature: @wrong_key)
    end

    test "tampered body (description byte flipped post-signing) is {:error, {:card_signature, {:digest_mismatch, _}}}", %{
      url: url
    } do
      set_mode(:tampered)

      assert {:error, {:card_signature, {:digest_mismatch, %{index: 0}}}} =
               Client.discover(url, verify_card_signature: @key)
    end

    test "no opt returns {:ok, card} regardless — legacy behavior unchanged", %{url: url} do
      # Signed server: passes without verification.
      assert {:ok, card} = Client.discover(url)
      assert [%{"protected" => _, "signature" => _}] = card.signatures

      # Even a TAMPERED body is returned as-is when no verification was
      # requested (fail-open legacy contract preserved exactly).
      set_mode(:tampered)
      assert {:ok, _card} = Client.discover(url)
    end

    test "unsigned card with verification requested is fail-closed {:error, {:card_signature, {:malformed, :no_signatures}}}", %{
      url: url
    } do
      set_mode(:unsigned)

      assert {:error, {:card_signature, {:malformed, :no_signatures}}} =
               Client.discover(url, verify_card_signature: @key)
    end
  end

  describe "new/2 verify_card_signature default + client-targeted discover" do
    test "client configured with the right key verifies via Client.discover(client)", %{url: url} do
      client = Client.new(url, verify_card_signature: @key)
      assert {:ok, card} = Client.discover(client)
      assert CardSigning.verify(card, @key) == :ok

      # Per-call opt overrides the client default.
      assert {:error, {:card_signature, {:bad_signature, %{index: 0}}}} =
               Client.discover(client, verify_card_signature: @wrong_key)
    end

    test "client configured with the wrong key is fail-closed", %{url: url} do
      client = Client.new(url, verify_card_signature: @wrong_key)
      assert {:error, {:card_signature, {:bad_signature, %{index: 0}}}} = Client.discover(client)
    end

    test "client without the option keeps legacy behavior", %{url: url} do
      client = Client.new(url)
      assert {:ok, _card} = Client.discover(client)
    end

    test "new/2 does not leak the opt into Req options", %{url: url} do
      client = Client.new(url, verify_card_signature: @key)
      assert is_map(client.req.options)
      refute Map.has_key?(client.req.options, :verify_card_signature)
    end
  end
end
