defmodule AshA2a.StandingReceiptChainTest do
  use ExUnit.Case, async: false

  alias AshA2a.StandingReceipt.Chain

  @genesis Chain.genesis()

  # --- real doc fixture: a temp file whose bytes we control fully ------------

  defp write_doc(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  defp append_revision(doc_path) do
    {out, 0} =
      run_task(["--in", doc_path, "--chain", Chain.chain_path(doc_path)])

    assert [_, head_line] = Regex.run(~r/CHAIN_HEAD:([0-9a-f]{64})/, out)
    {head_line, Chain.sha256_hex(File.read!(doc_path))}
  end

  defp run_task(args) do
    # drain any stale shell messages so the regex below can only match this run
    flush_shell()

    Mix.shell(Mix.Shell.Process)

    out =
      try do
        Mix.Tasks.AshA2a.StandingReceipt.Revision.run(args)
        collected()
      rescue
        e ->
          flunk("revision task raised: #{Exception.message(e)}")
      after
        Mix.shell(Mix.Shell.IO)
      end

    {out, 0}
  end

  defp flush_shell do
    receive do
      {:mix_shell, _, _} -> flush_shell()
      _ -> :ok
    after
      0 -> :ok
    end
  end

  defp collected do
    self()
    |> Process.info(:messages)
    |> elem(1)
    |> Enum.flat_map(fn
      {:mix_shell, :info, [msg]} -> [msg]
      {:mix_shell, :error, [msg]} -> [msg]
      _ -> []
    end)
    |> Enum.join("\n")
  end

  setup do
    dir = Path.join(System.tmp_dir!(), "l108-chain-#{:erlang.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    {:ok, dir: dir}
  end

  describe "fold" do
    test "empty chain folds to genesis" do
      assert {:ok, @genesis} == Chain.fold([])
    end

    test "single revision event folds off genesis" do
      event_id = Chain.sha256_hex("doc-v2")
      line = Jason.encode!(%{"event_type" => "receipt-revision", "event_id" => event_id,
                             "commitment" => @genesis, "ts" => "2026-10-13T00:00:00Z"})

      assert {:ok, Chain.digest(@genesis, event_id)} == Chain.fold([line])
    end

    test "flipped commitment byte refuses" do
      event_id = Chain.sha256_hex("doc-v2")
      good = Chain.digest(@genesis, event_id)

      # a second event whose commitment has one nibble flipped
      tampered =
        Chain.digest(good, event_id)
        |> flip_first_byte()
        |> then(&Jason.encode!(%{"event_type" => "receipt-revision",
                                 "event_id" => Chain.sha256_hex("doc-v3"),
                                 "commitment" => &1, "ts" => "2026-10-13T00:00:01Z"}))

      assert {:refused, msg} = Chain.fold([tampered])
      assert msg =~ "does not match prior chain head"
    end

    test "unknown event_type refuses" do
      line = Jason.encode!(%{"event_type" => "forgery", "event_id" => "ff",
                             "commitment" => @genesis, "ts" => "x"})

      assert {:refused, msg} = Chain.fold([line])
      assert msg =~ "unknown event_type"
    end
  end

  describe "revision flow (real mix task + real files)" do
    test "mint head, mutate doc, re-append; court refuses old head for mutated doc", %{dir: dir} do
      doc = write_doc(dir, "STANDING-RECEIPT.md", "receipt body v1")
      chain = Chain.chain_path(doc)

      # 1. mint head over v1
      {head1, _} = append_revision(doc)
      assert File.exists?(chain)
      assert {:ok, head1} == Chain.fold(chain_lines(chain))
      assert :ok == Chain.verify(doc)

      # 2. mutate the doc (edit that would pass a fresh-signature re-mint)
      File.write!(doc, "receipt body v2 -- edited")

      # 3. court refuses: head event_id no longer equals live doc sha
      assert {:refused, msg} = Chain.verify(doc)
      assert msg =~ "chain head event_id"
      assert msg =~ "re-mint"

      # 4. the documented re-mint flow: append a revision for the edited doc
      {head2, doc2_sha} = append_revision(doc)
      assert head2 == Chain.digest(head1, doc2_sha)
      assert :ok == Chain.verify(doc)
    end

    test "untouched doc verifies (multi-link chain)", %{dir: dir} do
      doc = write_doc(dir, "STANDING-RECEIPT.md", "stable body")

      {h1, _} = append_revision(doc)
      {h2, _} = append_revision(doc)
      {h3, _} = append_revision(doc)

      assert h1 != h2 and h2 != h3
      assert {:ok, h3} == Chain.fold(chain_lines(Chain.chain_path(doc)))
      assert :ok == Chain.verify(doc)
    end

    test "tampered chain file (flipped commitment byte) refuses", %{dir: dir} do
      doc = write_doc(dir, "STANDING-RECEIPT.md", "body")
      {_, _} = append_revision(doc)
      {_, _} = append_revision(doc)
      chain = Chain.chain_path(doc)

      lines = chain_lines(chain)
      flipped = flip_first_byte(Jason.decode!(hd(lines))["commitment"])

      # flip one byte inside the SECOND line's commitment
      tampered_lines =
        lines
        |> List.update_at(1, fn line ->
          String.replace(line, Jason.decode!(line)["commitment"], flipped)
        end)

      File.write!(chain, Enum.join(tampered_lines, "\n") <> "\n")

      assert {:refused, msg} = Chain.verify(doc)
      assert msg =~ "does not match prior chain head"

      # and the revision task refuses to append onto the broken chain
      Mix.shell(Mix.Shell.Process)

      assert catch_exit(append_revision_bare(doc)) != nil
      Mix.shell(Mix.Shell.IO)
    end

    test "back-compat: no chain file -> verify absent, fold not consulted", %{dir: dir} do
      doc = write_doc(dir, "STANDING-RECEIPT.md", "body")
      refute File.exists?(Chain.chain_path(doc))
      assert {:absent, path} = Chain.verify(doc)
      assert path == Chain.chain_path(doc)
    end
  end

  defp append_revision_bare(doc) do
    Mix.Tasks.AshA2a.StandingReceipt.Revision.run([
      "--in",
      doc,
      "--chain",
      Chain.chain_path(doc)
    ])
  end

  defp chain_lines(chain) do
    chain |> File.read!() |> String.split("\n", trim: true)
  end

  defp flip_first_byte(hex) when is_binary(hex) do
    first = String.at(hex, 0)
    swapped = if first == "0", do: "1", else: "0"
    swapped <> String.slice(hex, 1..-1//1)
  end
end
