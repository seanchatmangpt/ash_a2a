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
        case attest_stage(att_path, in_path, trusted, opts[:attest_bin]) do
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
  end

  # --- stage 1: payload digest (pure :crypto, always runs) ------------------

  defp payload_digest_stage(in_path, att_path) do
    with {:ok, payload} <- File.read(in_path),
         {:ok, att_json} <- File.read(att_path),
         {:ok, att} <- Jason.decode(att_json),
         {:ok, claimed} <- fetch_field(att, "payload_sha256"),
         :ok <- check_digest(in_path, payload, claimed) do
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

  defp fetch_field(att, key) do
    case Map.fetch(att, key) do
      {:ok, v} -> {:ok, v}
      :error -> {:refused, "attestation missing field #{inspect(key)}"}
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
