defmodule AshA2A.DurablePreparedJournal.JournalTest do
  @moduledoc """
  Court for the keyed, sequence-numbered `PreparedEffectStore.Journal`.

  Real files under the build path (non-tmp), real HMAC key custody, real
  second BEAM for the restart case. Tampering is done by editing the real
  journal bytes; the oracle is the refusal code, not a call count.
  """
  use ExUnit.Case, async: false

  alias AshA2A.ConsequenceKernel.KeyCustody.HmacSha256
  alias AshA2A.ConsequenceKernel.PreparedEffectStore
  alias AshA2A.ConsequenceKernel.PreparedEffectStore.Journal

  @key String.duplicate("k", 32)

  defp dir do
    d =
      Path.join([
        Mix.Project.build_path(),
        "durable_courts",
        "journal_#{System.unique_integer([:positive])}"
      ])

    on_exit(fn -> File.rm_rf!(d) end)
    d
  end

  defp open!(d, key \\ @key) do
    {:ok, h} = Journal.open(d, {HmacSha256, [key: key]})
    h
  end

  defp record(digest),
    do: %{digest: digest, bytes: "bytes-" <> digest, tag: "t", state: :prepared}

  defp other_beam(code) do
    paths = :code.get_path() |> Enum.flat_map(&["-pa", to_string(&1)])
    System.cmd("elixir", paths ++ ["-e", code], stderr_to_stdout: true)
  end

  test "put/fetch/transition/claim/complete follow the store contract" do
    h = open!(dir())
    assert :ok = Journal.put(h, record("d1"))
    assert {:error, :prepared_duplicate} = Journal.put(h, record("d1"))
    assert {:ok, %{digest: "d1", state: :prepared}} = Journal.fetch(h, "d1")
    assert :not_found = Journal.fetch(h, "zz")

    assert {:error, :prepared_transition_refused} =
             Journal.transition(h, "d1", :prepared, :completed)

    assert :ok = Journal.transition(h, "d1", :prepared, :claimed)

    assert {:error, :prepared_transition_refused} =
             Journal.transition(h, "d1", :prepared, :claimed)

    assert :ok = Journal.claim_request(h, "r1", :owner_a)
    assert :ok = Journal.claim_request(h, "r1", :owner_a)
    assert {:error, :claim_conflict} = Journal.claim_request(h, "r1", :owner_b)
    assert :ok = Journal.claim_effect(h, "e1", :owner_a)
    assert {:error, :claim_conflict} = Journal.claim_effect(h, "e1", :owner_b)
    assert {:error, :prepared_not_completed} = Journal.complete(h, "d1", :out)
    :ok = Journal.transition(h, "d1", :claimed, :applying)
    :ok = Journal.transition(h, "d1", :applying, :completed)
    assert :ok = Journal.complete(h, "d1", :out)
    assert {:ok, %{state: :completed, outcome: :out}} = Journal.fetch(h, "d1")
  end

  test "entries are sequence-numbered 1..n without gaps" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    :ok = Journal.put(h, record("b"))
    :ok = Journal.transition(h, "a", :prepared, :claimed)
    assert {:ok, [1, 2, 3]} = Journal.sequence(h)
    assert {:ok, 3} = Journal.head(h)
  end

  test "PreparedEffectStore.prepare/3 seals a real PreparedEffect into the journal and is idempotent" do
    d = dir()
    h = open!(d)

    {:ok, i} =
      AshA2A.EffectInstance.new(%{
        request: %{"n" => System.unique_integer([:positive])},
        subject: %{"id" => 1},
        effect: %{"op" => "update"}
      })

    {:ok, p} = AshA2A.PreparedEffect.new(i, %{"op" => "update"}, :change)
    opts = [key_provider: HmacSha256, key_opts: [key: @key]]

    assert :ok = PreparedEffectStore.prepare({Journal, h}, p, opts)
    assert :ok = PreparedEffectStore.prepare({Journal, h}, p, opts)
    assert {:ok, %{digest: digest}} = Journal.fetch(open!(d), p.prepared_digest)
    assert digest == p.prepared_digest
    assert {:ok, 1} = Journal.head(h)

    assert {:error, :claim_conflict} =
             PreparedEffectStore.claim_request({Journal, h}, "rq", :o)
             |> then(fn :ok -> PreparedEffectStore.claim_request({Journal, h}, "rq", :p) end)
  end

  test "state survives a real BEAM restart; the second BEAM continues the sequence" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("r1"))

    {out, 0} =
      other_beam("""
      alias AshA2A.ConsequenceKernel.PreparedEffectStore.Journal
      {:ok, h} = Journal.open(#{inspect(d)}, {AshA2A.ConsequenceKernel.KeyCustody.HmacSha256, [key: #{inspect(@key)}]})
      IO.puts("dup:" <> inspect(Journal.put(h, %{digest: "r1", bytes: "x", tag: "t", state: :prepared})))
      IO.puts("put:" <> inspect(Journal.put(h, %{digest: "r2", bytes: "x", tag: "t", state: :prepared})))
      IO.puts("seq:" <> inspect(Journal.sequence(h)))
      """)

    assert out =~ "dup:{:error, :prepared_duplicate}"
    assert out =~ "put::ok"
    assert out =~ "seq:{:ok, [1, 2]}"
    assert {:ok, %{digest: "r2"}} = Journal.fetch(h, "r2")
  end

  test "opening with a different key is refused (authentication, not silence)" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("k1"))
    h2 = open!(d, String.duplicate("z", 32))
    assert {:error, :prepared_authentication_failed} = Journal.fetch(h2, "k1")
    assert {:error, :prepared_authentication_failed} = Journal.put(h2, record("k2"))
  end

  test "a flipped byte in the journal is refused" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("t1"))
    :ok = Journal.put(h, record("t2"))
    log = Path.join(d, "journal.log")
    bin = File.read!(log)
    pos = div(byte_size(bin), 2)
    <<pre::binary-size(^pos), b, post::binary>> = bin
    File.write!(log, <<pre::binary, Bitwise.bxor(b, 1), post::binary>>)
    assert {:error, e} = Journal.fetch(h, "t1")
    assert e in [:prepared_authentication_failed, :journal_corrupt]
  end

  test "a truncated journal (dropped tail entry) is refused against the MAC'd head" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    size1 = File.stat!(Path.join(d, "journal.log")).size
    :ok = Journal.put(h, record("b"))

    File.write!(
      Path.join(d, "journal.log"),
      binary_part(File.read!(Path.join(d, "journal.log")), 0, size1)
    )

    assert {:error, :journal_truncated} = Journal.fetch(h, "a")
  end

  test "a swapped/reordered entry is refused (chain)" do
    d = dir()
    h = open!(d)
    :ok = Journal.put(h, record("a"))
    :ok = Journal.put(h, record("b"))
    log = Path.join(d, "journal.log")
    File.write!(log, File.read!(log) <> File.read!(log))
    assert {:error, e} = Journal.fetch(h, "a")
    assert e in [:prepared_authentication_failed, :journal_corrupt, :journal_sequence_gap]
  end

  test "an entry spliced in from another journal under the same key is refused (chain)" do
    frames = fn d ->
      bin = File.read!(Path.join(d, "journal.log"))
      <<l1::32, _::binary-size(l1), t1::16, _::binary-size(t1), _::binary>> = bin
      first = 4 + l1 + 2 + t1
      {binary_part(bin, 0, first), binary_part(bin, first, byte_size(bin) - first)}
    end

    da = dir()
    ha = open!(da)
    :ok = Journal.put(ha, record("a1"))
    :ok = Journal.put(ha, record("a2"))
    db = dir()
    hb = open!(db)
    :ok = Journal.put(hb, record("b1"))
    :ok = Journal.put(hb, record("b2"))
    {a_first, _} = frames.(da)
    {_, b_second} = frames.(db)
    File.write!(Path.join(da, "journal.log"), a_first <> b_second)
    assert {:error, :prepared_authentication_failed} = Journal.fetch(ha, "a1")
  end

  test "mandatory key: no key, short key, and no provider are refused at open" do
    d = dir()
    assert {:error, :journal_key_missing} = Journal.open(d, nil)
    assert {:error, :prepared_key_unavailable} = Journal.open(d, {HmacSha256, [key: "short"]})
    assert {:error, :prepared_key_unavailable} = Journal.open(d, {HmacSha256, []})
  end

  test "a tmp directory is refused at open" do
    tmp = Path.join(System.tmp_dir!(), "journal_tmp_#{System.unique_integer([:positive])}")
    assert {:error, :journal_dir_not_durable} = Journal.open(tmp, {HmacSha256, [key: @key]})
    assert {:error, :journal_dir_not_durable} = Journal.open(nil, {HmacSha256, [key: @key]})
    refute File.exists?(tmp)
  end

  test "from_config/0 builds the handle from real app env" do
    d = dir()
    keys = [:receipt_outbox_dir, :receipt_outbox_key, :prepared_journal_dir]
    prev = for k <- keys, do: {k, Application.get_env(:ash_a2a, k)}
    Application.put_env(:ash_a2a, :receipt_outbox_dir, d)
    Application.put_env(:ash_a2a, :receipt_outbox_key, @key)
    Application.delete_env(:ash_a2a, :prepared_journal_dir)

    on_exit(fn ->
      for {k, v} <- prev,
          do:
            if(v == nil,
              do: Application.delete_env(:ash_a2a, k),
              else: Application.put_env(:ash_a2a, k, v)
            )
    end)

    assert {:ok, h} = Journal.from_config()
    assert :ok = Journal.put(h, record("cfg"))
    assert File.exists?(Path.join([d, "prepared_journal", "journal.log"]))
  end
end
