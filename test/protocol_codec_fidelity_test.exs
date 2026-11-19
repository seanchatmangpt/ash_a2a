defmodule AshA2A.ProtocolCodecFidelityTest do
  @moduledoc """
  W2 codec fidelity court: typed OAuth flows, AgentCardSignature, Artifact and
  AgentCard required members, Message/Artifact extensions defaults.
  Reference: priv/a2a_v1_spec_corpus/a2a.proto. Real encode/decode round trips.
  """

  use ExUnit.Case, async: true

  alias AshA2A.Protocol.{Artifact, JSON, Message, Part}
  alias AshA2A.Protocol.SecurityScheme.{OAuth2, OAuthFlows}

  defp card_map(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "agent",
        "description" => "d",
        "version" => "1.0.0",
        "supportedInterfaces" => [
          %{
            "url" => "https://a.example",
            "protocolBinding" => "JSONRPC",
            "protocolVersion" => "1.0"
          }
        ],
        "capabilities" => %{},
        "defaultInputModes" => ["text/plain"],
        "defaultOutputModes" => ["text/plain"],
        "skills" => []
      },
      overrides
    )
  end

  defp oauth_card(flows) do
    card_map(%{
      "securitySchemes" => %{
        "o" => %{"oauth2SecurityScheme" => %{"flows" => flows}}
      }
    })
  end

  describe "OAuth flows" do
    test "deviceCode round-trips" do
      flows = %{
        "deviceCode" => %{
          "deviceAuthorizationUrl" => "https://auth.example/device",
          "tokenUrl" => "https://auth.example/token",
          "scopes" => %{"read" => "r"}
        }
      }

      assert {:ok, card} = JSON.decode_agent_card(oauth_card(flows))
      assert %OAuth2{flows: ^flows} = card.security_schemes["o"]

      assert {:ok, again} =
               card
               |> JSON.encode_agent_card(url: "https://a.example")
               |> JSON.decode_agent_card()

      assert again.security_schemes["o"].flows == flows
    end

    test "authorizationCode with pkceRequired round-trips and types strictly" do
      flows = %{
        "authorizationCode" => %{
          "authorizationUrl" => "https://a",
          "tokenUrl" => "https://t",
          "scopes" => %{"s" => "d"},
          "pkceRequired" => true
        }
      }

      assert {:ok, card} = JSON.decode_agent_card(oauth_card(flows))

      assert {:ok, again} =
               card
               |> JSON.encode_agent_card(url: "https://a.example")
               |> JSON.decode_agent_card()

      assert again.security_schemes["o"].flows == flows

      assert {:ok, %OAuthFlows.AuthorizationCode{pkce_required: true}} = OAuthFlows.decode(flows)
      assert OAuthFlows.encode(elem(OAuthFlows.decode(flows), 1)) == flows
    end

    test "typed struct encodes on the wire" do
      {:ok, typed} =
        OAuthFlows.decode(%{
          "clientCredentials" => %{"tokenUrl" => "https://t", "scopes" => %{}}
        })

      scheme = %OAuth2{flows: typed}

      card = %AshA2A.Protocol.AgentCard{
        name: "n",
        description: "d",
        url: "http://x",
        version: "1",
        skills: [],
        security_schemes: %{"o" => scheme}
      }

      wire = JSON.encode_agent_card(card, url: "https://a.example")

      assert get_in(wire, ["securitySchemes", "o", "oauth2SecurityScheme", "flows"]) ==
               %{"clientCredentials" => %{"tokenUrl" => "https://t", "scopes" => %{}}}
    end

    test "two flow keys violate the oneof" do
      flows = %{
        "clientCredentials" => %{"tokenUrl" => "https://t", "scopes" => %{}},
        "deviceCode" => %{
          "deviceAuthorizationUrl" => "https://d",
          "tokenUrl" => "https://t",
          "scopes" => %{}
        }
      }

      assert {:error, {:oneof_violation, _, ["clientCredentials", "deviceCode"]}} =
               JSON.decode_agent_card(oauth_card(flows))
    end

    test "unknown flow key and unknown member are rejected" do
      assert {:error, {:unknown_flow, "magic"}} =
               JSON.decode_agent_card(oauth_card(%{"magic" => %{}}))

      assert {:error, {:unknown_field, _}} =
               JSON.decode_agent_card(
                 oauth_card(%{"clientCredentials" => %{"tokenUrl" => "t", "bogus" => 1}})
               )
    end

    test "deviceCode missing deviceAuthorizationUrl is rejected" do
      flows = %{"deviceCode" => %{"tokenUrl" => "https://t", "scopes" => %{}}}

      assert {:error,
              {:missing_field, "oauth2SecurityScheme.flows.deviceCode.deviceAuthorizationUrl"}} =
               JSON.decode_agent_card(oauth_card(flows))
    end

    test "deviceCode missing tokenUrl or scopes is rejected" do
      assert {:error, {:missing_field, _}} =
               JSON.decode_agent_card(
                 oauth_card(%{
                   "deviceCode" => %{"deviceAuthorizationUrl" => "d", "scopes" => %{}}
                 })
               )

      assert {:error, {:missing_field, _}} =
               JSON.decode_agent_card(
                 oauth_card(%{
                   "deviceCode" => %{"deviceAuthorizationUrl" => "d", "tokenUrl" => "t"}
                 })
               )
    end

    test "deprecated implicit and password decode and are flagged" do
      implicit = %{"implicit" => %{"authorizationUrl" => "https://a", "scopes" => %{}}}
      password = %{"password" => %{"tokenUrl" => "https://t"}}

      assert {:ok, _} = JSON.decode_agent_card(oauth_card(implicit))
      assert {:ok, _} = JSON.decode_agent_card(oauth_card(password))
      assert OAuthFlows.deprecated?(implicit)
      assert OAuthFlows.deprecated?("password")
      refute OAuthFlows.deprecated?(%{"deviceCode" => %{}})
    end

    test "wrong member types are rejected" do
      assert {:error, {:invalid_field, _}} =
               JSON.decode_agent_card(
                 oauth_card(%{
                   "authorizationCode" => %{
                     "authorizationUrl" => "a",
                     "tokenUrl" => "t",
                     "scopes" => %{},
                     "pkceRequired" => "yes"
                   }
                 })
               )
    end
  end

  describe "AgentCardSignature" do
    test "valid signature decodes; header optional" do
      sigs = [
        %{"protected" => "p", "signature" => "s"},
        %{"protected" => "p", "signature" => "s", "header" => %{"k" => "v"}}
      ]

      assert {:ok, card} = JSON.decode_agent_card(card_map(%{"signatures" => sigs}))
      assert card.signatures == sigs
    end

    test "missing protected, missing signature, bad header, non-list fail" do
      for bad <- [
            [%{"signature" => "s"}],
            [%{"protected" => "p"}],
            [%{"protected" => "p", "signature" => "s", "header" => "nope"}],
            [%{"protected" => 1, "signature" => "s"}],
            "x"
          ] do
        assert {:error, {:invalid_field, "signatures"}} =
                 JSON.decode_agent_card(card_map(%{"signatures" => bad}))
      end
    end
  end

  describe "AgentCard required members" do
    test "each REQUIRED member is enforced" do
      for key <-
            ~w(name description version supportedInterfaces capabilities defaultInputModes defaultOutputModes skills) do
        assert {:error, {:missing_field, ^key}} =
                 JSON.decode_agent_card(Map.delete(card_map(), key))
      end
    end

    test "protocolBinding must be JSONRPC, GRPC or HTTP+JSON" do
      for b <- ["JSONRPC", "GRPC", "HTTP+JSON"] do
        card = card_map(%{"supportedInterfaces" => [%{"url" => "u", "protocolBinding" => b}]})
        assert {:ok, _} = JSON.decode_agent_card(card)
      end

      card = card_map(%{"supportedInterfaces" => [%{"url" => "u", "protocolBinding" => "SOAP"}]})

      assert {:error, {:invalid_field, "supportedInterfaces.protocolBinding"}} =
               JSON.decode_agent_card(card)
    end
  end

  describe "Artifact" do
    test "requires artifactId and non-empty parts" do
      part = %{"text" => "hi"}

      assert {:error, {:missing_field, "artifactId"}} =
               JSON.decode(%{"parts" => [part]}, :artifact)

      assert {:error, {:invalid_field, "artifactId"}} =
               JSON.decode(%{"artifactId" => "", "parts" => [part]}, :artifact)

      assert {:error, {:empty_field, "parts"}} =
               JSON.decode(%{"artifactId" => "a", "parts" => []}, :artifact)

      assert {:error, {:missing_field, "parts"}} = JSON.decode(%{"artifactId" => "a"}, :artifact)
    end

    test "new/2 extensions default [] and accept :extensions" do
      assert %Artifact{extensions: []} = Artifact.new([Part.Text.new("x")])

      assert %Artifact{extensions: ["urn:x"]} =
               Artifact.new([Part.Text.new("x")], extensions: ["urn:x"])
    end

    test "Message extensions default []" do
      assert %Message{extensions: []} = Message.new_user("hi")
    end
  end
end
