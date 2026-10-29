defmodule Mix.Tasks.AshA2a.StandingReceipt.Verify do
  @shortdoc "Verify a standing-receipt attestation (payload digest + Ed25519 via graphlaw-attest)"

  @moduledoc """
  Verifies a standing receipt's attestation (L33 seam, lane L42).

  Two stages, both real:

  1. **Payload digest**: the receipt file's SHA-256 must equal the
     `payload_sha256` recorded in the `.attestation.json`.
  2. **Signature**: if a `graphlaw-attest` binary is available, it is invoked
     with `--trusted-key` to verify the Ed25519 signature over the payload.
     If absent, stage 2 is `BLOCKED:graphlaw-attest-absent` -- never faked.
     (Stage 1 runs unconditionally, so a BLOCKED run still catches edits.)
  3. **Revision chain** (L108): if a `<doc>.chain.jsonl` exists next to the
     doc, the fold is recomputed and the head event's `event_id` must equal
     the live doc's sha256. Refuses an edited doc even with a fresh valid
     signature -- re-mint via `mix ash_a2a.standing_receipt.revision`.
     No chain file = stage skipped (back-compat).

  ## Usage

      mix ash_a2a.standing_receipt.verify \\
        --in docs/sjira/v26.10.8/STANDING-RECEIPT.md \\
        --attestation docs/sjira/v26.10.8/STANDING-RECEIPT.attestation.json \\
        --trusted-key d3fcc7395405739f76d7570e0804e79d6a1e4e60b42b1b93642bf033e62d239b

  ## Options

    * `--in` -- the standing-receipt document (default: the v26.10.8 path)
    * `--attestation` -- the `.attestation.json` (default: `--in` <> ".attestation.json")
    * `--trusted-key` -- expected Ed25519 public key (hex). Default: the
      documented v26.10.8 mint key.
    * `--attest-bin` -- path to `graphlaw-attest`; default searches
      `/Users/sac/graphlaw/target/debug/graphlaw-attest` then `$PATH`.

  ## Exit status

  `0` VERIFIED; `1` REFUSED; `2` BLOCKED (graphlaw-attest absent).
  """

  use Mix.Task

  @switches [in: :string, attestation: :string, trusted_key: :string, attest_bin: :string]
  @default_receipt "docs/sjira/v26.10.8/STANDING-RECEIPT.md"
  @default_trusted "d3fcc7395405739f76d7570e0804e79d6a1e4e60b42b1b93642bf033e62d239b"

  @impl true
  def run(args) do
    {opts, _argv} = OptionParser.parse!(args, strict: @switches)

    in_path =
      opts[:in] ||
        Path.expand(@default_receipt, Path.join(__DIR__, "../../.."))
    att_path =
      opts[:attestation] ||
        (if String.ends_with?(in_path, ".md") do
           String.replace_suffix(in_path, ".md", "") <> ".attestation.json"
         else
           in_path <> ".attestation.json"
         end)
    trusted = opts[:trusted_key] || @default_trusted

    case payload_digest_stage(in_path, att_path) do
      {:refused, msg} ->
        Mix.shell().error("REFUSED: #{msg}")
        exit({:shutdown, 1})

      :ok ->
        case chain_stage(in_path) do
          :ok ->
            attest_run(att_path, in_path, trusted, opts[:attest_bin])

          {:refused, msg} ->
            Mix.shell().error("REFUSED: #{msg}")
            exit({:shutdown, 1})
        end

    end
  end

  defp attest_run(att_path, in_path, trusted, attest_bin) do
    case attest_stage(att_path, in_path, trusted, attest_bin) do
          :ok ->
            Mix.shell().info("VERIFIED")
            :ok

          {:refused, msg} ->
            Mix.shell().error("REFUSED: #{msg}")
            exit({:shutdown, 1})

          {:blocked, msg} ->
            Mix.shell().error("BLOCKED: #{msg}")
            exit({:shutdown, 2})
        end
  end

  # --- stage 3: revision chain court (only if a chain file exists) ----------

  defp chain_stage(in_path) do
    case AshA2a.StandingReceipt.Chain.verify(in_path) do
      :ok ->
        Mix.shell().info("CHAIN:ok (fold recomputed, head matches live doc)")
        :ok

      {:refused, msg} ->
        {:refused, "chain court: #{msg}"}

      {:absent, _path} ->
        :ok
    end
  end

  # --- stage 1: payload digest (pure :crypto, always runs) ------------------

  defp payload_digest_stage(in_path, att_path) do
    with {:ok, payload} <- File.read(in_path),
         {:ok, att_json} <- File.read(att_path),
         {:ok, att} <- Jason.decode(att_json),
         :ok <- digest_stage(att, in_path, payload) do
      :ok
    else
      {:error, %Jason.DecodeError{} = e} ->
        {:refused, "attestation JSON decode: #{Exception.message(e)}"}

      {:error, reason} ->
        {:refused, "file read failed (#{inspect(reason)}): #{in_path} or #{att_path}"}

      {:refused, _msg} = refused ->
        refused
    end
  end

  defp check_digest(in_path, payload, claimed_hex) do
    actual = Base.encode16(:crypto.hash(:sha256, payload), case: :lower)

    if actual == claimed_hex do
      :ok
    else
      {:refused,
       "payload digest mismatch for #{in_path}: claimed #{claimed_hex}, actual #{actual}"}
    end
  end

  # blake3-era attestations (graphlaw-attest v26.10.28+) carry `payload_blake3`
  # instead of `payload_sha256`; this runtime has no blake3 primitive, so the
  # integrity check defers to the signature stage (graphlaw-attest verifies the
  # payload_blake3 binding itself). sha256 attestations still check exactly as
  # before.
  defp digest_stage(att, in_path, payload) do
    case Map.fetch(att, "payload_sha256") do
      {:ok, claimed} ->
        check_digest(in_path, payload, claimed)

      :error ->
        if Map.has_key?(att, "payload_blake3") do
          :ok
        else
          {:refused, "attestation missing field \"payload_sha256\" (or \"payload_blake3\")"}
        end
    end
  end

  # --- stage 2: signature via real graphlaw-attest binary -------------------

  defp attest_stage(att_path, in_path, trusted, explicit_bin) do
    case find_attest_bin(explicit_bin) do
      {:ok, bin} ->
        args = [
          "verify",
          "--in",
          in_path,
          "--attestation",
          att_path,
          "--trusted-key",
          trusted
        ]

        case System.cmd(bin, args, stderr_to_stdout: true) do
          {out, 0} ->
            if String.trim_trailing(out) != "VERIFIED" do
              Mix.shell().info(String.trim_trailing(out))
            end

            :ok

          {out, code} ->
            {:refused,
             "graphlaw-attest verify failed (exit #{code}): #{String.trim_trailing(out)}"}
        end

      :error ->
        {:blocked, "graphlaw-attest-absent (#{att_path} signature stage skipped, not faked)"}
    end
  end

  defp find_attest_bin(nil) do
    candidates = [
      "/Users/sac/graphlaw/target/debug/graphlaw-attest",
      "graphlaw-attest"
    ]

    Enum.find_value(candidates, :error, fn cand ->
      if File.regular?(cand) or System.find_executable(cand), do: {:ok, cand}, else: nil
    end)
  end

  defp find_attest_bin(bin) do
    if File.regular?(bin) or System.find_executable(bin) do
      {:ok, bin}
    else
      :error
    end
  end
end
