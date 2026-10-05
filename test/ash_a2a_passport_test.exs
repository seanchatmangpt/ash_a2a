defmodule AshA2A.PassportTest do
  @moduledoc """
  Real court for the Agent Passport (lane ZD1): real HMAC-SHA256 JWS
  signing over the vendored RFC 8785 canonicalizer (`Jcs.encode/1`), a
  real RFC 6962-style Merkle tree (`AshA2A.Passport.Merkle`), a real
  signed revocation list, and a real `Plug.Test` GET against
  `AshA2A.Passport.Plug`. Zero mocks.

  Adversarial courts, per the lane contract:

  - issue -> mutate a capability -> `verify/2` fails with the Merkle proof
    pinning the change (the audit path over the SIGNED leaves recomputes
    the signed root from the OLD leaf);
  - issue -> revoke -> `verify/2` fails `{:error, {:revoked, _}}`;
  - cross-check vs `AshA2A.Protocol.CardSigning` (same key, same scheme,
    shared canonicalizer);
  - the passport round-trips through the codec (`to_json/1` ->
    `from_json/1`) and still verifies.
  """

  use ExUnit.Case, async: false

  import Plug.Conn, only: [get_resp_header: 2]

  alias AshA2A.Passport
  alias AshA2A.Passport.Merkle
  alias AshA2A.Passport.Revocation
  alias AshA2A.Protocol.AgentCard
  alias AshA2A.Protocol.CardSigning

  @key :crypto.strong_rand_bytes(32)
  @wrong_key :crypto.strong_rand_bytes(32)
  @issuer "urn:ash-a2a:issuer:zd1"
  @now ~U[2026-10-04 12:00:00Z]

  defp card do
    %AgentCard{
      name: "passport-agent",
      description: "Agent under passport court",
      url: "https://agent.example.com",
      version: "1.0.0",
      skills: [
        %{
          id: "echo",
          name: "Echo",
          description: "Echoes the utterance",
          tags: ["echo"]
        }
      ]
    }
  end

  defp attestations do
    [
      %{"id" => "att-1", "capability" => "echo", "scope" => "read", "since" => "2026-01-01"},
      %{"id" => "att-2", "capability" => "translate", "scope" => "read-write", "since" => "2026-02-01"}
    ]
  end

  defp evidence do
    [
      %{"id" => "ev-1", "kind" => "capability-index-digest", "digest" => String.duplicate("ab", 32)}
    ]
  end

  defp issued(opts \\ []) do
    Passport.issue(card(), attestations(), evidence(),
      [key: @key, issuer: @issuer, now: @now] ++ opts
    )
  end

  defp attestation_leaf(entry), do: Merkle.leaf(Jcs.encode(Jason.decode!(Jason.encode!(entry))))

  # Explicit struct-field updates: put_in/3's `put_in(a.b, path, v)` form
  # is the plain-FUNCTION form (data = a.b), not path sugar.
  defp with_attestation(passport, index, updater) do
    %{passport | attestations: List.update_at(passport.attestations, index, updater)}
  end

  defp with_evidence(passport, index, updater) do
    %{passport | evidence: List.update_at(passport.evidence, index, updater)}
  end

  # ------------------------------------------------------------------
  # Issuance + verification happy path
  # ------------------------------------------------------------------

  describe "issue/4 + verify/2" do
    test "a freshly issued passport verifies" do
      passport = issued()

      assert %Passport.Document{} = passport
      assert passport.issuer == @issuer
      assert String.starts_with?(passport.id, "urn:ash-a2a:passport:")
      assert length(passport.signatures) == 1
      assert Passport.verify(passport, @key) == :ok
    end

    test "the merkle member carries the root and one leaf per pinned entry" do
      passport = issued()

      assert %{"root" => root, "leaves" => leaves} = passport.merkle
      assert byte_size(root) == 64
      assert length(leaves) == 3

      {:ok, recomputed} =
        Merkle.root(Enum.map(leaves, &Base.decode16!(&1, case: :lower)))

      assert Base.encode16(recomputed, case: :lower) == root
    end

    test "verify on a wire map verifies the decoded document" do
      passport = issued()

      assert Passport.verify(Passport.to_json(passport) |> Jason.decode!(), @key) == :ok
    end

    test "verify with the wrong key is {:error, {:bad_signature, %{index: 0}}}" do
      assert {:error, {:bad_signature, %{index: 0}}} = Passport.verify(issued(), @wrong_key)
    end

    test "verify refuses an unsigned document (no vacuous admission)" do
      unsigned = %{issued() | signatures: []}

      assert {:error, {:malformed, :no_signatures}} = Passport.verify(unsigned, @key)
    end

    test "issue refuses empty attestations, a missing key and a missing issuer" do
      assert_raise ArgumentError, ~r/attestations/, fn ->
        Passport.issue(card(), [], evidence(), key: @key, issuer: @issuer)
      end

      assert_raise ArgumentError, ~r/:key/, fn ->
        Passport.issue(card(), attestations(), evidence(), issuer: @issuer)
      end

      assert_raise ArgumentError, ~r/:issuer/, fn ->
        Passport.issue(card(), attestations(), evidence(), key: @key)
      end
    end

    test "issue refuses an already-expired expires_at" do
      assert_raise ArgumentError, ~r/future/, fn ->
        Passport.issue(card(), attestations(), evidence(),
          key: @key,
          issuer: @issuer,
          now: @now,
          expires_at: ~U[2026-10-04 11:00:00Z]
        )
      end
    end
  end

  # ------------------------------------------------------------------
  # Capability-mutation court (the Merkle proof pins the change)
  # ------------------------------------------------------------------

  describe "capability mutation" do
    test "mutating a capability fails verification with the Merkle audit path pinning the change" do
      passport = issued()

      [att_1, _att_2] = attestations()
      mutated = with_attestation(passport, 0, &%{&1 | "scope" => "admin"})

      assert {:error, {:capability_mutated, detail}} = Passport.verify(mutated, @key)

      assert detail.kind == :attestation
      assert detail.index == 0
      assert detail.position == 0
      assert detail.entry_id == "att-1"
      assert detail.signed_leaf == Enum.at(passport.merkle["leaves"], 0)
      assert detail.leaf == Base.encode16(attestation_leaf(%{att_1 | "scope" => "admin"}), case: :lower)

      # The proof pins the change: the SIGNED tree contained the OLD leaf.
      old_leaf = attestation_leaf(att_1)
      root = Base.decode16!(detail.root, case: :lower)
      assert Merkle.valid_proof?(old_leaf, detail.proof, root)
      refute Merkle.valid_proof?(Base.decode16!(detail.leaf, case: :lower), detail.proof, root)
    end

    test "mutating the LAST capability pins the odd-duplicate audit path" do
      passport = issued()

      [_att_1, att_2] = attestations()
      mutated = with_attestation(passport, 1, &%{&1 | "capability" => "exfiltrate"})

      assert {:error, {:capability_mutated, detail}} = Passport.verify(mutated, @key)
      assert detail.index == 1
      assert detail.kind == :attestation

      old_leaf = attestation_leaf(att_2)
      root = Base.decode16!(detail.root, case: :lower)
      assert Merkle.valid_proof?(old_leaf, detail.proof, root)
    end

    test "mutating an evidence entry is pinned too" do
      passport = issued()

      [ev] = evidence()
      mutated = with_evidence(passport, 0, &%{&1 | "digest" => String.duplicate("ff", 32)})

      assert {:error, {:capability_mutated, detail}} = Passport.verify(mutated, @key)
      assert detail.kind == :evidence
      assert detail.index == 0
      assert detail.position == 2

      root = Base.decode16!(detail.root, case: :lower)
      assert Merkle.valid_proof?(attestation_leaf(ev), detail.proof, root)
    end

    test "an attacker who rewrites merkle.leaves lands in :merkle_root_mismatch" do
      passport = issued()

      [att_1, _att_2] = attestations()
      mutated_entry = %{att_1 | "scope" => "admin"}

      mutated_merkle =
        Map.update!(passport.merkle, "leaves", fn leaves ->
          List.replace_at(leaves, 0, Base.encode16(attestation_leaf(mutated_entry), case: :lower))
        end)

      mutated = %{passport | attestations: [mutated_entry, Enum.at(passport.attestations, 1)], merkle: mutated_merkle}

      assert {:error, {:merkle_root_mismatch, _}} = Passport.verify(mutated, @key)
    end

    test "an attacker who rewrites merkle.leaves AND the root lands in :digest_mismatch" do
      passport = issued()

      [att_1, att_2] = attestations()
      mutated_entry = %{att_1 | "scope" => "admin"}
      new_leaf = Base.encode16(attestation_leaf(mutated_entry), case: :lower)

      leaves =
        passport.merkle["leaves"] |> List.replace_at(0, new_leaf) |> Enum.map(&Base.decode16!(&1, case: :lower))

      {:ok, root} = Merkle.root(leaves)

      mutated = %{
        passport
        | attestations: [mutated_entry, att_2],
          merkle: %{"root" => Base.encode16(root, case: :lower), "leaves" => Enum.map(leaves, &Base.encode16(&1, case: :lower))}
      }

      assert {:error, {:digest_mismatch, _}} = Passport.verify(mutated, @key)
    end

    test "removing an attestation fails closed, pinning the shifted leaf" do
      passport = issued()
      [l1, l2, _l3] = passport.merkle["leaves"]
      mutated = %{passport | attestations: tl(passport.attestations)}

      assert {:error, {:capability_mutated, detail}} = Passport.verify(mutated, @key)
      # Position 0 now hashes the shifted-up second attestation, not att-1.
      assert detail.position == 0
      assert detail.leaf == l2
      assert detail.signed_leaf == l1
    end
  end

  # ------------------------------------------------------------------
  # Revocation court
  # ------------------------------------------------------------------

  describe "revocation" do
    test "revoke -> verify fails {:error, {:revoked, _}} with the reason" do
      passport = issued()
      list = Passport.revoke(passport, @key, issuer: @issuer, reason: "key-compromise", now: @now)

      assert %Revocation.List{} = list
      assert Revocation.verify(list, @key) == :ok

      assert {:error, {:revoked, detail}} = Passport.verify(passport, @key, revocation: list)
      assert detail.passport_id == passport.id
      assert detail.reason == "key-compromise"
    end

    test "an unlisted passport still verifies against the same list" do
      revoked = issued()
      list = Passport.revoke(revoked, @key, issuer: @issuer, now: @now)
      other = issued()

      assert Passport.verify(other, @key, revocation: list) == :ok
    end

    test "a tampered revocation list fails closed (refuses to admit OR to revoke)" do
      passport = issued()
      list = Passport.revoke(passport, @key, issuer: @issuer, now: @now)

      # Flip the reason on the single entry — a content change the signature
      # does not cover.
      tampered = update_in(list.entries, &[%{hd(&1) | reason: "innocent"}])

      assert {:error, {:digest_mismatch, _}} = Revocation.verify(tampered, @key)
      assert {:error, {:revocation_list_unverified, _}} =
               Passport.verify(passport, @key, revocation: tampered)
    end

    test "the revocation list round-trips through the codec and still verifies" do
      passport = issued()
      list = Passport.revoke(passport, @key, issuer: @issuer, now: @now)

      wire = list |> Revocation.to_json() |> Jason.decode!()
      assert {:ok, decoded} = Revocation.from_json(wire)
      assert Revocation.verify(decoded, @key) == :ok

      assert {:error, {:revoked, _}} =
               Passport.verify(passport, @key, revocation: decoded)
    end

    test "revoking accumulates across calls on the same list" do
      p1 = issued()
      p2 = issued()

      list =
        p1
        |> Passport.revoke(@key, issuer: @issuer, now: @now)
        |> then(&Passport.revoke(p2, @key, list: &1, now: @now))

      assert Revocation.verify(list, @key) == :ok
      assert {:error, {:revoked, _}} = Passport.verify(p1, @key, revocation: list)
      assert {:error, {:revoked, _}} = Passport.verify(p2, @key, revocation: list)
    end
  end

  # ------------------------------------------------------------------
  # Cross-check vs CardSigning
  # ------------------------------------------------------------------

  describe "cross-check vs AshA2A.Protocol.CardSigning" do
    test "the subject card signed by CardSigning under the SAME key verifies" do
      passport = issued()
      signed_card = CardSigning.sign(passport.subject, @key)

      assert CardSigning.verify(signed_card, @key) == :ok
      assert {:error, {:bad_signature, _}} = CardSigning.verify(signed_card, @wrong_key)
    end

    test "verify/3 with :card_key cross-checks the subject card" do
      # Issue the passport WITH a pre-signed subject card: CardSigning
      # signatures ride inside the card, so they survive the passport's own
      # canonicalization and are cross-checked at verification time.
      signed_card = CardSigning.sign(card(), @key)
      passport = Passport.issue(signed_card, attestations(), evidence(), key: @key, issuer: @issuer, now: @now)

      assert Passport.verify(passport, @key, card_key: @key) == :ok
      assert {:error, {:bad_signature, %{index: 0}}} =
               Passport.verify(passport, @key, card_key: @wrong_key)
    end
  end

  # ------------------------------------------------------------------
  # Expiry
  # ------------------------------------------------------------------

  describe "expiry" do
    test "an expired passport is refused" do
      passport =
        issued(expires_at: ~U[2026-10-04 13:00:00Z])

      assert Passport.verify(passport, @key, now: @now) == :ok

      assert {:error, {:expired, detail}} =
               Passport.verify(passport, @key, now: ~U[2026-10-04 14:00:00Z])

      assert detail.expires_at == "2026-10-04T13:00:00Z"
    end
  end

  # ------------------------------------------------------------------
  # Codec round trip (the falsifier)
  # ------------------------------------------------------------------

  describe "codec round trip" do
    test "to_json -> from_json -> verify is :ok, and the decoded document is field-identical" do
      passport = issued(expires_at: ~U[2026-10-05 00:00:00Z])

      json = Passport.to_json(passport)
      assert {:ok, decoded} = Passport.from_json(json)

      assert decoded.id == passport.id
      assert decoded.issuer == passport.issuer
      assert decoded.merkle == passport.merkle
      assert decoded.attestations == passport.attestations
      assert decoded.evidence == passport.evidence
      assert decoded.issued_at == passport.issued_at
      assert decoded.expires_at == passport.expires_at
      assert decoded.signatures == passport.signatures
      assert decoded.subject.name == passport.subject.name
      assert decoded.subject.url == passport.subject.url
      assert decoded.subject.skills == passport.subject.skills

      # The court clock is pinned with :now so the expires_at member is
      # exercised without depending on the wall clock.
      assert Passport.verify(decoded, @key, now: @now) == :ok
    end

    test "from_json refuses malformed documents" do
      assert {:error, {:malformed, :not_json}} = Passport.from_json("not json")
      assert {:error, {:malformed, {:missing_member, "id"}}} = Passport.from_json(%{})

      # Fail-closed first-error ordering: the subject is validated before
      # the merkle member, so a malformed subject is reported first.
      assert {:error, {:malformed, {:bad_subject, {:missing_field, "name"}}}} =
               Passport.from_json(%{
                 "id" => "x",
                 "issuer" => "i",
                 "subject" => %{},
                 "attestations" => [%{}],
                 "evidence" => [],
                 "merkle" => %{"root" => "zz", "leaves" => []},
                 "issuedAt" => "t"
               })

      # A structurally valid subject surfaces the bad merkle member.
      subject = %{"name" => "n", "description" => "d", "version" => "1", "skills" => []}

      assert {:error, {:malformed, {:bad_member, "merkle"}}} =
               Passport.from_json(%{
                 "id" => "x",
                 "issuer" => "i",
                 "subject" => subject,
                 "attestations" => [%{}],
                 "evidence" => [],
                 "merkle" => %{"root" => "zz", "leaves" => []},
                 "issuedAt" => "t"
               })
    end
  end

  # ------------------------------------------------------------------
  # Merkle unit courts
  # ------------------------------------------------------------------

  describe "AshA2A.Passport.Merkle" do
    test "root of one leaf is the leaf; proof is empty; valid" do
      leaf = Merkle.leaf("x")
      assert {:ok, ^leaf} = Merkle.root([leaf])
      assert {:ok, []} = Merkle.proof([leaf], 0)
      assert Merkle.valid_proof?(leaf, [], leaf)
    end

    test "every leaf of a 5-leaf tree proves against the root" do
      leaves = Enum.map(1..5, &Merkle.leaf(Integer.to_string(&1)))
      {:ok, root} = Merkle.root(leaves)

      for i <- 0..4 do
        {:ok, proof} = Merkle.proof(leaves, i)
        assert Merkle.valid_proof?(Enum.at(leaves, i), proof, root)
        refute Merkle.valid_proof?(Merkle.leaf("forged"), proof, root)
      end
    end

    test "refuses the empty tree and out-of-range proofs" do
      assert {:error, :empty} = Merkle.root([])
      assert {:error, {:out_of_range, 2}} = Merkle.proof([Merkle.leaf("a"), Merkle.leaf("b")], 2)
    end

    test "leaf and node hashing are domain-separated (RFC 6962)" do
      data = "payload"
      leaf = Merkle.leaf(data)
      assert leaf != :crypto.hash(:sha256, data)
    end
  end

  # ------------------------------------------------------------------
  # Plug court
  # ------------------------------------------------------------------

  describe "AshA2A.Passport.Plug" do
    test "GET serves the passport as JSON that verifies after a codec round trip" do
      passport = issued()
      conn = dispatch(passport_plug(passport), :GET, [".well-known", "agent-passport.json"])

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]

      assert {:ok, decoded} = Passport.from_json(conn.resp_body)
      assert decoded.id == passport.id
      assert Passport.verify(decoded, @key) == :ok
    end

    test "GET serves the configured revocation list; without one the path 404s" do
      passport = issued()
      list = Passport.revoke(passport, @key, issuer: @issuer, now: @now)

      conn = dispatch(passport_plug(passport, list), :GET, [".well-known", "agent-passport-revocations.json"])
      assert conn.status == 200
      assert {:ok, decoded} = Jason.decode(conn.resp_body)
      assert {:ok, list_decoded} = Revocation.from_json(decoded)
      assert Revocation.verify(list_decoded, @key) == :ok

      conn = dispatch(passport_plug(passport), :GET, [".well-known", "agent-passport-revocations.json"])
      assert conn.status == 404
    end

    test "wrong method on the passport path is 405; unknown paths are 404" do
      plug = passport_plug(issued())

      conn = dispatch(plug, :POST, [".well-known", "agent-passport.json"])
      assert conn.status == 405
      assert get_resp_header(conn, "allow") == ["GET"]

      conn = dispatch(plug, :GET, ["other", "path"])
      assert conn.status == 404
    end

    test "a string path option splits on slashes" do
      passport = issued()

      opts =
        Passport.Plug.init(passport: passport, passport_path: "/.well-known/agent-passport.json")

      conn = dispatch({Passport.Plug, opts}, :GET, [".well-known", "agent-passport.json"])
      assert conn.status == 200
    end
  end

  # ------------------------------------------------------------------
  # Plug harness (real Plug.Test conn, direct call/2 — no socket, no mocks)
  # ------------------------------------------------------------------

  defp passport_plug(passport, revocation \\ nil) do
    opts =
      if revocation do
        Passport.Plug.init(passport: passport, revocation: revocation)
      else
        Passport.Plug.init(passport: passport)
      end

    {Passport.Plug, opts}
  end

  defp dispatch({plug, opts}, method, path) do
    Plug.Test.conn(method, "/" <> Enum.join(path, "/"))
    |> plug.call(opts)
  end
end
