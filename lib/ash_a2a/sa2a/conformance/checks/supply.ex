# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule AshA2A.SA2A.Conformance.Checks.Supply do
  @moduledoc """
  Supply-chain block (RFC-007 E-Q): protected main, signed tag at the subject,
  single release workflow. Reads `gh`/`git` facts ONLY when `ctx.github` is
  true (`--github`); otherwise every check is `:unverified`.
  """

  alias AshA2A.SA2A.Conformance.{Check, Context}

  @spec checks(map()) :: [Check.t()]
  def checks(ctx) do
    ctx = Context.build(ctx)

    [
      Check.run("supply.protected_main", :c2, "main is a protected branch", fn ->
        protected_main(ctx)
      end),
      Check.run("supply.signed_tag", :c2, "subject carries a verified signed tag", fn ->
        signed_tag(ctx)
      end),
      Check.run("supply.single_release_workflow", :c2, "exactly one release workflow", fn ->
        single_release_workflow(ctx)
      end)
    ]
  end

  defp gated(%{github: true}, fun), do: fun.()
  defp gated(_ctx, _fun), do: {:unverified, "supply-chain facts are read only with --github"}

  def protected_main(ctx) do
    ctx = Context.build(ctx)

    gated(ctx, fn ->
      case run(ctx.gh, ["api", "repos/{owner}/{repo}/branches/main/protection"], ctx.root) do
        {:ok, {out, 0}} ->
          case Jason.decode(out) do
            {:ok, %{} = body} ->
              rules =
                Map.keys(body)
                |> Enum.filter(
                  &(&1 in ~w(enforce_admins required_status_checks required_pull_request_reviews restrictions))
                )

              if rules == [],
                do: {:fail, "main protection response carries no rules"},
                else: {:pass, "gh api branches/main/protection: rules #{Enum.join(rules, ", ")}"}

            _ ->
              {:unverified, "gh answered 0 but not with JSON"}
          end

        {:ok, {out, _code}} ->
          if out =~ "Branch not protected",
            do: {:fail, "main is not protected (gh: Branch not protected)"},
            else: {:unverified, "gh could not answer: #{String.trim(out)}"}

        {:error, why} ->
          {:unverified, "gh unavailable: #{why}"}
      end
    end)
  end

  def signed_tag(ctx) do
    ctx = Context.build(ctx)

    gated(ctx, fn ->
      case run("git", ["tag", "--points-at", "HEAD"], ctx.root) do
        {:ok, {out, 0}} ->
          tags = String.split(out, "\n", trim: true)
          verify_tags(ctx, tags)

        _ ->
          {:unverified, "git tag --points-at HEAD failed in #{ctx.root}"}
      end
    end)
  end

  defp verify_tags(_ctx, []), do: {:fail, "no tag points at the subject HEAD"}

  defp verify_tags(ctx, tags) do
    verdicts =
      Enum.map(tags, fn tag ->
        case run("git", ["cat-file", "-t", "refs/tags/#{tag}"], ctx.root) do
          {:ok, {"tag" <> _, 0}} ->
            case run("git", ["tag", "-v", tag], ctx.root) do
              {:ok, {_, 0}} ->
                {:ok, tag}

              {:ok, {out, _}} ->
                {:bad,
                 "#{tag}: annotated but signature not verified (#{String.trim(out) |> String.slice(0, 120)})"}

              {:error, why} ->
                {:bad, "#{tag}: #{why}"}
            end

          _ ->
            {:bad,
             "#{tag}: lightweight tag, not an annotated signed tag object (annotated required)"}
        end
      end)

    case Enum.find(verdicts, &match?({:ok, _}, &1)) do
      {:ok, tag} ->
        {:pass,
         "tag #{tag} on subject HEAD is an annotated tag whose signature `git tag -v` verified"}

      nil ->
        {:fail, Enum.map_join(verdicts, "; ", fn {:bad, w} -> w end)}
    end
  end

  def single_release_workflow(ctx) do
    ctx = Context.build(ctx)

    gated(ctx, fn ->
      dir = Path.join(ctx.root, ".github/workflows")
      files = Path.wildcard(Path.join(dir, "*.{yml,yaml}"))

      if not Code.ensure_loaded?(YamlElixir) do
        {:unverified, "YamlElixir unavailable: cannot parse workflow triggers"}
      else
        releases =
          for f <- files, release_trigger?(f), do: Path.basename(f)

        case releases do
          [one] ->
            {:pass, "exactly one release-triggered workflow: #{one} (of #{length(files)})"}

          [] ->
            {:fail,
             "no release-triggered workflow (release event or pushed tags) among #{length(files)}"}

          many ->
            {:fail, "#{length(many)} release-triggered workflows: #{Enum.join(many, ", ")}"}
        end
      end
    end)
  end

  defp release_trigger?(file) do
    with {:ok, doc} when is_map(doc) <- YamlElixir.read_from_file(file) do
      on = Map.get(doc, "on", Map.get(doc, true))

      case on do
        %{} = m ->
          Map.has_key?(m, "release") or
            match?(%{"tags" => t} when t not in [nil, []], m["push"])

        list when is_list(list) ->
          "release" in list

        "release" ->
          true

        _ ->
          false
      end
    else
      _ -> false
    end
  end

  defp run(exe, args, cwd) do
    {:ok, System.cmd(exe, args, cd: cwd, stderr_to_stdout: true)}
  rescue
    e -> {:error, Exception.message(e)}
  end
end
