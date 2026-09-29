defmodule AuthorityService.TestKit do
  @moduledoc false
  # Real P-256 key pairs generated per test and real signatures made with :crypto
  # directly: an oracle independent of AuthorityService and of Sa2aCrypto.Native.
  alias Sa2aCrypto.{Envelope, KeyRecord, KeyRef, SignedMessage}

  @authority_audience "authority:test"
  @actuator "actuator:test"
  def authority_audience, do: @authority_audience
  def actuator, do: @actuator
  def now, do: 1_800_000_000

  def signer(custodian, tier \\ :i3) do
    {pub, priv} = :crypto.generate_key(:ecdh, :secp256r1)
    kid = KeyRef.kid!("ES256", pub)

    %{
      kid: kid,
      pub: pub,
      priv: priv,
      custodian: custodian,
      record: %KeyRecord{
        kid: kid,
        alg: "ES256",
        public_key: pub,
        custodian_id: custodian,
        custody_tier: tier,
        state: :active,
        revocation_epoch: 4
      }
    }
  end

  def effect(over \\ %{}) do
    Map.merge(
      %{
        "effect_class" => "payment",
        "amount" => 50_000,
        "principal" => "agent:alice",
        "target" => "acct:42",
        "idem" => "e-1"
      },
      over
    )
  end

  def effect_bytes(effect), do: Jcs.encode(effect)
  def digest(bytes), do: SignedMessage.digest(bytes)

  @doc "Wire request (string keys) for `effect`, with `approvals` already attached."
  def request(effect, approvals \\ [], over \\ %{}) do
    bytes = effect_bytes(effect)

    Map.merge(
      %{
        "effect" => Base.url_encode64(bytes, padding: false),
        "effect_digest" => digest(bytes),
        "audience" => @actuator,
        "generation" => 9,
        "approvals" => approvals
      },
      over
    )
  end

  @doc "A wire approval signed by `signer` over `effect_digest`."
  def approval(signer, effect_digest, over \\ %{}) do
    fields =
      Map.merge(
        %{
          "v" => 1,
          "alg" => "ES256",
          "kid" => signer.kid,
          "effect_digest" => effect_digest,
          "principal" => "agent:alice",
          "policy_epoch" => 3,
          "revocation_epoch" => 4,
          "generation" => 9,
          "nonce" => nonce(),
          "not_before" => now() - 10,
          "expires" => now() + 200,
          "audience" => @authority_audience
        },
        over
      )

    {:ok, bytes} = SignedMessage.build(fields)
    sig = :crypto.sign(:ecdsa, :sha256, bytes, [signer.priv, :secp256r1])

    env = %Envelope{
      v: fields["v"],
      alg: "ES256",
      kid: fields["kid"],
      profile: :classical,
      signed_bytes_digest: SignedMessage.digest(bytes),
      signature: sig,
      nonce: fields["nonce"],
      not_before: fields["not_before"],
      expires: fields["expires"],
      audience: fields["audience"]
    }

    {:ok, json} = Envelope.encode(env)

    %{
      "envelope" => Jason.decode!(json),
      "message" => Base.url_encode64(bytes, padding: false)
    }
  end

  def nonce, do: Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)

  def tmp_dir(name) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "authsvc-#{name}-#{Base.url_encode64(:crypto.strong_rand_bytes(9), padding: false)}"
      )

    File.mkdir_p!(dir)
    dir
  end

  def write_key(dir, priv, mode \\ 0o600) do
    path = Path.join(dir, "policy.key")
    File.write!(path, Base.url_encode64(priv, padding: false))
    File.chmod!(path, mode)
    path
  end

  def policy(over \\ []) do
    AuthorityService.Policy.new(
      Keyword.merge(
        [
          epoch: 3,
          approvers: ["alice", "bob", "carol"],
          min_approver_tier: :i3,
          classes: %{
            "payment" => [
              %{max_amount: 10_000, k: 0},
              %{max_amount: 100_000, k: 1},
              %{max_amount: :infinity, k: 2}
            ]
          }
        ],
        over
      )
    )
  end

  @doc "Build a running Issuer over a fresh journal dir. Returns a context map."
  def start_issuer(ctx \\ %{}) do
    dir = Map.get(ctx, :dir) || tmp_dir("issuer")
    svc = Map.get(ctx, :svc) || signer("authority-service", :i2)
    approvers = Map.get(ctx, :approvers) || Enum.map(~w(alice bob carol), &signer/1)
    key_path = write_key(dir, svc.priv)

    {:ok, key} = AuthorityService.KeyFile.load(key_path)

    config =
      AuthorityService.Config.new(
        service_key: key,
        policy: Map.get(ctx, :policy) || policy(),
        approver_registry: Sa2aCrypto.Registry.Static.view(Enum.map(approvers, & &1.record)),
        authority_audience: @authority_audience,
        journal_path: Path.join(dir, "journal.log"),
        channel: Map.get(ctx, :channel),
        clock: &__MODULE__.now/0
      )

    {:ok, pid} = AuthorityService.Issuer.start_link(config: config, name: nil)
    %{issuer: pid, dir: dir, svc: svc, approvers: approvers, config: config}
  end

  def signer_named(ctx, name), do: Enum.find(ctx.approvers, &(&1.custodian == name))
end
