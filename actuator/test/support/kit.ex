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
            quorum_default: 1,
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

  # -- child-process fixture (real OS process kill/restart courts) ---------------------

  @doc """
  Writes config.json + revocation.json + effect/cert binaries for effect number `n` into
  `dir` and returns a map for `run_child/3`. `n` selects a distinct effect instance.
  """
  def child_fixture(dir, n, keys \\ nil) do
    now = System.os_time(:second)

    built =
      build(
        state_dir: dir,
        now: now,
        keys: keys,
        nonce_prefix: "child#{n}",
        effect: %{
          "effect_instance_id" => "ei:child-000#{n}",
          "params" => %{"entry" => "entry-#{n}"}
        },
        ctx: []
      )

    registry =
      for r <- built.records do
        %{
          "kid" => r.kid,
          "alg" => r.alg,
          "public_key" => Base.url_encode64(r.public_key, padding: false),
          "custodian_id" => r.custodian_id,
          "custody_tier" => "i2",
          "state" => "active",
          "revocation_epoch" => 7
        }
      end

    config = Path.join(dir, "config.json")

    File.write!(
      config,
      Jason.encode!(%{
        "state_dir" => dir,
        "audience" => audience(),
        "policy_epoch" => 3,
        "allowed_subjects" => ["subject:orders/42"],
        "quorum_default" => 1,
        "registry" => registry
      })
    )

    File.write!(
      Path.join(dir, "revocation.json"),
      Jason.encode!(%{"refreshed_at" => now, "epoch" => 7, "revoked" => []})
    )

    File.write!(Path.join(dir, "effect#{n}.bin"), built.effect_bytes)
    File.write!(Path.join(dir, "cert#{n}.bin"), built.cert_bytes)
    %{dir: dir, config: config, n: n, built: built}
  end

  @doc "Run one execute in a fresh OS process; `point` is an ACTUATOR_TEST_CRASH point or \"none\"."
  def run_child(%{dir: dir, config: config, n: n}, point \\ "none") do
    mix = System.find_executable("mix") || raise "mix not on PATH"
    script = Path.expand("boot_child.exs", __DIR__)

    System.cmd(
      mix,
      [
        "run",
        "--no-start",
        "--no-compile",
        "--no-deps-check",
        script,
        config,
        Path.join(dir, "effect#{n}.bin"),
        Path.join(dir, "cert#{n}.bin")
      ],
      env: [{"MIX_ENV", "test"}, {"ACTUATOR_TEST_CRASH", point}],
      stderr_to_stdout: true
    )
  end

  # -- oracles -----------------------------------------------------------------------

  @zero String.duplicate("0", 64)

  @doc """
  Ledger CONTENT oracle. Re-derives, independently of Actuator.Ledger, the exact entry
  (seq, prev, instance, digest, entry text, hash) each effect must have produced and compares
  it to the ledger file byte-for-byte as decoded maps. Presence of a digest is not enough.
  """
  def ledger_oracle(dir, effect_bytes_list) do
    path = Path.join(dir, "effect_ledger.jsonl")

    actual =
      if File.exists?(path),
        do: path |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&Jason.decode!/1),
        else: []

    {expected, _} =
      effect_bytes_list
      |> Enum.with_index()
      |> Enum.map_reduce(@zero, fn {bytes, i}, prev ->
        eff = Jason.decode!(bytes)

        body = %{
          "effect_instance_id" => eff["effect_instance_id"],
          "effect_digest" =>
            "sha256:" <> Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
          "entry" => eff["params"]["entry"],
          "seq" => i,
          "prev" => prev
        }

        h = Base.encode16(:crypto.hash(:sha256, prev <> Jcs.encode(body)), case: :lower)
        {Map.put(body, "hash", h), h}
      end)

    if actual == expected, do: :ok, else: {:mismatch, %{expected: expected, actual: actual}}
  end

  @doc """
  Key-material scan by VALUE. Searches every file under `dir` (recursively) for each secret's
  raw bytes and its hex / base64 / base64url encodings. Field names are irrelevant: a file
  containing `"private_key":"REDACTED"` is clean, one carrying the key bytes under any name
  is a hit.
  """
  def key_material_hits(dir, secrets) do
    files =
      Path.wildcard(Path.join(dir, "**/*"), match_dot: true) |> Enum.filter(&File.regular?/1)

    for f <- files,
        data = File.read!(f),
        s <- secrets,
        {enc, needle} <- encodings(s),
        :binary.match(data, needle) != :nomatch,
        do: {f, enc}
  end

  defp encodings(s) do
    [
      raw: s,
      hex_lower: Base.encode16(s, case: :lower),
      hex_upper: Base.encode16(s, case: :upper),
      b64: Base.encode64(s),
      b64_nopad: Base.encode64(s, padding: false),
      b64url: Base.url_encode64(s),
      b64url_nopad: Base.url_encode64(s, padding: false)
    ]
  end
end
