defmodule AshA2A.EmailProviderEdgeTest do
  use ExUnit.Case, async: true

  alias AshA2A.Email.{Sender, Webhook}
  alias AshA2A.Hilt.WorkOrder

  @secret "0123456789abcdef-secret"

  describe "sendgrid" do
    test "header secret accepted, wrong rejected, unconfigured rejected" do
      assert :ok = Webhook.verify(:sendgrid, [{"x-webhook-secret", @secret}], secret: @secret)

      assert {:error, :unauthorized} =
               Webhook.verify(:sendgrid, [{"x-webhook-secret", "nope"}], secret: @secret)

      assert {:error, :unauthorized} = Webhook.verify(:sendgrid, [], secret: @secret)
      assert {:error, :not_configured} = Webhook.verify(:sendgrid, [], [])
    end

    test "basic auth password accepted" do
      auth = "Basic " <> Base.encode64("user:" <> @secret)
      assert :ok = Webhook.verify(:sendgrid, %{"Authorization" => auth}, secret: @secret)

      bad = "Basic " <> Base.encode64("user:wrong")

      assert {:error, :unauthorized} =
               Webhook.verify(:sendgrid, %{"authorization" => bad}, secret: @secret)
    end
  end

  describe "workspace" do
    test "bearer token" do
      assert :ok =
               Webhook.verify(:workspace, [{"authorization", "Bearer " <> @secret}],
                 token: @secret
               )

      assert {:error, :unauthorized} =
               Webhook.verify(:workspace, [{"authorization", "Bearer x"}], token: @secret)

      assert {:error, :unauthorized} =
               Webhook.verify(:workspace, [{"authorization", @secret}], token: @secret)

      assert {:error, :not_configured} = Webhook.verify(:workspace, [], token: nil)
    end
  end

  describe "ses" do
    defp sns(over \\ %{}) do
      Map.merge(
        %{
          "Type" => "Notification",
          "MessageId" => "m1",
          "TopicArn" => "arn:aws:sns:us-east-1:1:t",
          "Timestamp" => "2026-11-13T00:00:00Z",
          "Signature" => Base.encode64("sig"),
          "SignatureVersion" => "1",
          "SigningCertURL" =>
            "https://sns.us-east-1.amazonaws.com/SimpleNotificationService-x.pem"
        },
        over
      )
    end

    test "structure-only accepts valid, default is fail-closed" do
      assert :ok = Webhook.verify(:ses, sns(), structure_only: true)
      assert {:error, :signature_unverified} = Webhook.verify(:ses, sns(), [])

      assert :ok =
               Webhook.verify(:ses, Jason.encode!(sns()), signature_verifier: fn _ -> true end)

      assert {:error, :bad_signature} =
               Webhook.verify(:ses, sns(), signature_verifier: fn _ -> false end)
    end

    test "rejects hostile cert url, bad version, topic mismatch, junk" do
      assert {:error, :bad_cert_url} =
               Webhook.verify(:ses, sns(%{"SigningCertURL" => "https://evil.example.com/a.pem"}),
                 structure_only: true
               )

      assert {:error, :bad_cert_url} =
               Webhook.verify(
                 :ses,
                 sns(%{"SigningCertURL" => "http://sns.us-east-1.amazonaws.com/a.pem"}),
                 structure_only: true
               )

      assert {:error, :bad_signature_version} =
               Webhook.verify(:ses, sns(%{"SignatureVersion" => "9"}), structure_only: true)

      assert {:error, :topic_mismatch} =
               Webhook.verify(:ses, sns(), structure_only: true, topic_arn: "other")

      assert {:error, :malformed} = Webhook.verify(:ses, "not json", structure_only: true)
      assert {:error, :malformed} = Webhook.verify(:ses, %{}, structure_only: true)
    end
  end

  test "unknown provider refused" do
    assert {:error, :unknown_provider} = Webhook.verify(:mailgun, [], [])
  end

  test "spool sender writes a real message file" do
    dir = Path.join(System.tmp_dir!(), "y9_spool_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(dir) end)

    msg = %{to: "a@example.com", from: "g@example.com", subject: "Hi", body: "Approve?"}
    assert {:ok, %{path: path}} = Sender.deliver(Sender.Spool, msg, spool_dir: dir)
    content = File.read!(path)
    assert content =~ "To: a@example.com"
    assert content =~ "Subject: Hi"
    assert String.ends_with?(content, "Approve?")
  end

  test "sender rejects header injection and missing fields" do
    bad = %{to: "a@example.com\r\nBcc: x@y", from: "g@example.com", subject: "s", body: "b"}
    assert {:error, {:invalid_message, :to}} = Sender.deliver(Sender.Spool, bad, [])

    assert {:error, {:invalid_message, :body}} =
             Sender.validate(%{to: "a", from: "b", subject: "c"})
  end

  test "checkpoint_graph_digest/2 is public and deterministic" do
    d = String.duplicate("a", 64)
    assert :ok = WorkOrder.checkpoint_graph_digest(nil, d)
    assert :ok = WorkOrder.checkpoint_graph_digest(d, nil)
    assert :ok = WorkOrder.checkpoint_graph_digest(d, d)

    other = String.duplicate("b", 64)

    for _ <- 1..3 do
      assert {:error, :stale_graph_identity} = WorkOrder.checkpoint_graph_digest(d, other)
    end
  end
end
