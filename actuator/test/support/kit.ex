defmodule Actuator.Kit do
  @moduledoc false
  # Real keys, real signatures. Signing uses :crypto directly (an oracle independent of
  # Sa2aCrypto.Native.verify and of the fence). Every builder takes overrides so a test can
  # mutate exactly one field of an otherwise valid case.
  alias Actuator.Context
  alias Sa2aCrypto.{KeyRecord, KeyRef}
  alias Sa2aCrypto.Registry.Static

  @audience "actuator:test"
  def audience, do: @audience
  def now, do: 1_800_000_000

  def effect_map(over \\ %{}) do
    Map.merge(
      %{
        "v" => 1,
        "principal" => "agent:alice",
        "subject" => "subject:orders/42",
        "capability" => "actuator.ledger.append",
        "consequence_class" => "internal_append",
        "effect_type" => "ledger_append",
        "effect_instance_id" => "ei:0001-abcdef",
        "resource_bounds" => %{"max_bytes" => 256},
        "policy_epoch" => 3,
        "params" => %{"entry" => "hello"}
      },
      over
    )
  end

  def gen_key do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    {pub, priv, KeyRef.kid!("ES256", pub)}
  end

  def raw_sign(msg, priv), do: :crypto.sign(:ecdsa, :sha256, msg, [priv, :secp256r1])

  def tmp_dir(label) do
    # random suffix: unique_integer restarts per VM and tmp dirs outlive runs
    suffix = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)
    dir = Path.join(System.tmp_dir!(), "actuator-#{label}-#{suffix}")
    File.mkdir_p!(dir)
    dir
  end

  @doc """
  Options: :effect (merged into effect before signing/digest), :effect_after (merged into
  the effect AFTER the certificate digest was fixed), :cert (merged into the certificate
  fields before signing), :signers (default 1), :custodians, :tamper_sig (index whose
  signature gets a flipped byte), :ctx (struct fields merged into the Context),
  :revocation (merged into the revocation view), :state_dir, :nonce_prefix, :keys (reuse
  generated keys), :now (unix seconds the case is built around).
  """
  def build(opts \\ []) do
    signers = Keyword.get(opts, :signers, 1)
    custodians = Keyword.get(opts, :custodians, Enum.map(1..signers, &"custodian-#{&1}"))
    nonce_prefix = Keyword.get(opts, :nonce_prefix, "n#{System.unique_integer([:positive])}")

    keys = Keyword.get(opts, :keys) || for _ <- 1..signers, do: gen_key()
    now = Keyword.get(opts, :now, now())

    records =
      keys
      |> Enum.zip(custodians)
      |> Enum.map(fn {{pub, _priv, kid}, cust} ->
        %KeyRecord{
          kid: kid,
          alg: "ES256",
          public_key: pub,
          custodian_id: cust,
          custody_tier: :i2,
          state: :active,
          revocation_epoch: 7
        }
      end)

    effect = effect_map(Keyword.get(opts, :effect, %{}))
    signed_bytes = Jcs.encode(effect)
    delivered = Jcs.encode(Map.merge(effect, Keyword.get(opts, :effect_after, %{})))

    fields =
      Map.merge(
        %{
          "v" => 1,
          "effect_digest" => Actuator.Effect.digest(signed_bytes),
          "principal" => effect["principal"],
          "policy_epoch" => 3,
          "revocation_epoch" => 7,
          "generation" => 1,
          "not_before" => now - 60,
          "expires" => now + 300,
          "audience" => @audience
        },
        Keyword.get(opts, :cert, %{})
      )

    sigs =
      keys
      |> Enum.with_index()
      |> Enum.map(fn {{_pub, priv, kid}, i} ->
        nonce = "#{nonce_prefix}-#{i}"

        {:ok, msg} =
          Sa2aCrypto.SignedMessage.build(
            Map.merge(fields, %{"alg" => "ES256", "kid" => kid, "nonce" => nonce})
          )

        sig = raw_sign(msg, priv)
        sig = if Keyword.get(opts, :tamper_sig) == i, do: flip(sig), else: sig

        %{
          "kid" => kid,
          "alg" => "ES256",
          "nonce" => nonce,
          "signature" => Base.url_encode64(sig, padding: false)
        }
      end)

    cert_bytes = Jcs.encode(Map.put(fields, "signatures", sigs))

    dir = Keyword.get(opts, :state_dir, "/nonexistent-actuator-state")

    ctx =
      struct!(
        Context,
        Keyword.merge(
          [
            state_dir: dir,
            registry: Static.view(records),
            audience: @audience,
            policy_epoch: 3,
            revocation:
              Map.merge(
                %{refreshed_at: now - 10, epoch: 7, revoked: MapSet.new()},
                Keyword.get(opts, :revocation, %{})
              ),
            allowed_subjects: ["subject:orders/42"],
            clock: fn -> now end
          ],
          Keyword.get(opts, :ctx, [])
        )
      )

    %{
      effect_bytes: delivered,
      cert_bytes: cert_bytes,
      ctx: ctx,
      records: records,
      keys: keys,
      fields: fields,
      sigs: sigs,
      effect: effect
    }
  end

  def request(built) do
    {:ok, req} = Actuator.Fence.parse(built.effect_bytes, built.cert_bytes)
    req
  end

  def view(record \\ nil, nonce_owner \\ %{}), do: %{record: record, nonce_owner: nonce_owner}

  defp flip(sig) do
    n = byte_size(sig) - 1
    <<head::binary-size(^n), last>> = sig
    head <> <<Bitwise.bxor(last, 1)>>
  end
end
