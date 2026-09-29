defmodule AshA2A.SafeExec do
  @moduledoc """
  Closed-allowlist external process execution (RFC-SA2A-006 s22; CWE-77/78).

  Kernel-adjacent code never calls `System.cmd/3` or `Port.open/2` directly. It
  names one of a closed set of declared executables (`:node`, `:ps`, `:git`) and
  passes a typed argv:

    * `flag` -- a literal string that is a member of that executable's flag
      allowlist (for git, of the subcommand's flag allowlist);
    * `{:sha, s}` -- 40 or 64 lowercase hex;
    * `{:ref, s}` -- a strict ref charset (no leading dash), optional `~N`/`^N`;
    * `{:commit_ref, s}` -- a ref rendered as `<ref>^{commit}`;
    * `{:object, rev, path}` -- rendered `<rev>:<path>` (rev is sha or ref);
    * `{:path, s}` -- a path with no leading dash, NUL, CR/LF or shell metachar;
    * `{:int, n}` -- non-negative integer, rendered decimal;
    * `{:pid, s | n}` -- digits only.

  Every argument is validated BEFORE anything is spawned; a violation returns
  `{:error, %{code: :safe_exec_arg_refused, ...}}`. There is no shell: the
  executable is resolved to an absolute path and started with `spawn_executable`
  and an argv list. The environment is cleared except for an allowlist, a
  timeout kills the OS process, and captured output is capped.

  Result: `{:ok, %{output: binary, exit: integer}}` (a non-zero exit is still
  `:ok` -- the caller decides), or `{:error, %{code: code, ...}}` with code in
  `:safe_exec_executable_not_allowed | :safe_exec_arg_refused |
  :safe_exec_unavailable | :safe_exec_timeout | :safe_exec_output_too_large`.
  """

  @executables %{node: "node", ps: "ps", git: "git"}
  @env_allowlist ~w(PATH HOME LANG LC_ALL TMPDIR)
  @default_timeout 30_000
  @default_output_cap 8 * 1024 * 1024

  @git_subcommands %{
    "ls-tree" => ~w(-r --name-only --),
    "cat-file" => ~w(-e blob),
    "rev-parse" => ~w(--verify --quiet),
    "rev-list" => ~w(--first-parent)
  }
  @ps_flags ~w(-o comm= -p)

  @ref ~r/\A[A-Za-z0-9_][A-Za-z0-9_.\/@-]{0,254}([~^][0-9]{0,4})*\z/
  @sha ~r/\A([0-9a-f]{40}|[0-9a-f]{64})\z/
  @bad_path ~r/[;&|`$<>\\\x00\r\n]/

  @doc "The closed executable allowlist."
  @spec executables() :: [atom()]
  def executables, do: Map.keys(@executables)

  @doc "Validates argv for `exe` without spawning; returns the rendered argv."
  @spec validate(atom(), list()) :: {:ok, [String.t()]} | {:error, map()}
  def validate(exe, args) when is_list(args) do
    if Map.has_key?(@executables, exe), do: validate_args(exe, args), else: not_allowed(exe)
  end

  def validate(exe, _), do: refuse(exe, :argv_not_list, nil)

  @doc """
  Runs an allowlisted executable. Options: `:cd`, `:timeout` (ms), `:output_cap`
  (bytes), `:stderr_to_stdout` (boolean, default false).
  """
  @spec run(atom(), list(), keyword()) ::
          {:ok, %{output: binary(), exit: integer()}} | {:error, map()}
  def run(exe, args, opts \\ []) do
    with {:ok, name} <- fetch_exe(exe),
         {:ok, argv} <- validate(exe, args),
         {:ok, cd} <- validate_cd(exe, Keyword.get(opts, :cd)),
         {:ok, path} <- find(exe, name) do
      spawn_and_collect(path, argv, cd, opts)
    end
  end

  # --- validation ----------------------------------------------------------

  defp fetch_exe(exe) do
    case Map.fetch(@executables, exe) do
      {:ok, name} -> {:ok, name}
      :error -> not_allowed(exe)
    end
  end

  defp not_allowed(exe),
    do: {:error, %{code: :safe_exec_executable_not_allowed, executable: inspect(exe)}}

  defp refuse(exe, reason, arg),
    do:
      {:error,
       %{
         code: :safe_exec_arg_refused,
         executable: inspect(exe),
         reason: reason,
         arg: safe_arg(arg)
       }}

  defp safe_arg(arg) do
    arg |> inspect(limit: 20, printable_limit: 80)
  end

  defp validate_cd(_exe, nil), do: {:ok, nil}

  defp validate_cd(exe, cd) do
    # `cd` is a chdir target, never argv and never shell text, so only NUL/CR/LF
    # (which can corrupt or smuggle) are refused; repo directories may legitimately
    # contain characters such as `;`.
    if is_binary(cd) and cd != "" and String.valid?(cd) and not Regex.match?(~r/[\x00\r\n]/, cd),
      do: {:ok, cd},
      else: refuse(exe, :bad_cd, cd)
  end

  defp find(exe, name) do
    case System.find_executable(name) do
      nil -> {:error, %{code: :safe_exec_unavailable, executable: inspect(exe)}}
      path -> {:ok, path}
    end
  end

  defp validate_args(:git, [sub | rest]) when is_binary(sub) do
    case Map.fetch(@git_subcommands, sub) do
      {:ok, flags} -> render_all(:git, rest, flags, [sub])
      :error -> refuse(:git, :subcommand_not_allowed, sub)
    end
  end

  defp validate_args(:git, other), do: refuse(:git, :subcommand_required, other)
  defp validate_args(:ps, args), do: render_all(:ps, args, @ps_flags, [])
  defp validate_args(:node, args), do: render_all(:node, args, [], [])

  defp render_all(exe, args, flags, acc) do
    Enum.reduce_while(args, {:ok, Enum.reverse(acc)}, fn arg, {:ok, rendered} ->
      case render(arg, flags) do
        {:ok, s} -> {:cont, {:ok, [s | rendered]}}
        {:error, reason} -> {:halt, refuse(exe, reason, arg)}
      end
    end)
    |> case do
      {:ok, rendered} -> {:ok, Enum.reverse(rendered)}
      error -> error
    end
  end

  defp render(flag, flags) when is_binary(flag) do
    cond do
      flag in flags -> {:ok, flag}
      String.starts_with?(flag, "--max-count=") -> max_count(flag)
      String.starts_with?(flag, "-") -> {:error, :option_injection}
      true -> {:error, :untyped_argument}
    end
  end

  defp render({:sha, s}, _), do: if(sha?(s), do: {:ok, s}, else: {:error, :bad_sha})
  defp render({:ref, s}, _), do: if(ref?(s), do: {:ok, s}, else: ref_reason(s))

  defp render({:commit_ref, s}, _),
    do: if(ref?(s), do: {:ok, s <> "^{commit}"}, else: ref_reason(s))

  defp render({:object, rev, path}, _) do
    cond do
      not (sha?(rev) or ref?(rev)) -> ref_reason(rev)
      true -> with :ok <- check_path(path), do: {:ok, rev <> ":" <> path}
    end
  end

  defp render({:path, s}, _), do: with(:ok <- check_path(s), do: {:ok, s})
  defp render({:int, n}, _) when is_integer(n) and n >= 0, do: {:ok, Integer.to_string(n)}
  defp render({:int, _}, _), do: {:error, :bad_int}
  defp render({:pid, n}, _) when is_integer(n) and n > 0, do: {:ok, Integer.to_string(n)}

  defp render({:pid, s}, _) when is_binary(s),
    do: if(Regex.match?(~r/\A[0-9]{1,10}\z/, s), do: {:ok, s}, else: {:error, :bad_pid})

  defp render(_, _), do: {:error, :untyped_argument}

  defp max_count("--max-count=" <> n),
    do:
      if(Regex.match?(~r/\A[0-9]{1,9}\z/, n),
        do: {:ok, "--max-count=" <> n},
        else: {:error, :bad_int}
      )

  defp sha?(s), do: is_binary(s) and Regex.match?(@sha, s)
  defp ref?(s), do: is_binary(s) and Regex.match?(@ref, s)

  defp ref_reason(s) when is_binary(s) do
    cond do
      String.starts_with?(s, "-") -> {:error, :option_injection}
      true -> {:error, :bad_ref}
    end
  end

  defp ref_reason(_), do: {:error, :bad_ref}

  defp check_path(s) when is_binary(s) and byte_size(s) > 0 and byte_size(s) <= 4096 do
    cond do
      String.starts_with?(s, "-") -> {:error, :option_injection}
      not String.valid?(s) -> {:error, :bad_path}
      Regex.match?(@bad_path, s) -> {:error, :forbidden_character}
      true -> :ok
    end
  end

  defp check_path(_), do: {:error, :bad_path}

  # --- execution -------------------------------------------------------------

  defp spawn_and_collect(path, argv, cd, opts) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    cap = Keyword.get(opts, :output_cap, @default_output_cap)

    port_opts =
      [:binary, :exit_status, :use_stdio, :hide, args: argv, env: env()] ++
        if(cd, do: [cd: cd], else: []) ++
        if(Keyword.get(opts, :stderr_to_stdout, false), do: [:stderr_to_stdout], else: [])

    port = Port.open({:spawn_executable, path}, port_opts)
    deadline = System.monotonic_time(:millisecond) + timeout
    collect(port, [], 0, cap, deadline)
  rescue
    e in ErlangError -> {:error, %{code: :safe_exec_unavailable, detail: Exception.message(e)}}
  end

  defp collect(port, acc, size, cap, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        size = size + byte_size(data)

        if size > cap do
          kill(port)
          {:error, %{code: :safe_exec_output_too_large, cap: cap}}
        else
          collect(port, [acc, data], size, cap, deadline)
        end

      {^port, {:exit_status, status}} ->
        {:ok, %{output: IO.iodata_to_binary(acc), exit: status}}
    after
      remaining ->
        kill(port)
        {:error, %{code: :safe_exec_timeout}}
    end
  end

  defp kill(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _ -> nil
      end

    try do
      Port.close(port)
    catch
      _, _ -> :ok
    end

    if os_pid, do: kill_os(os_pid)
    flush(port)
  end

  defp kill_os(pid) do
    case System.find_executable("kill") do
      nil -> :ok
      k -> run_kill(k, pid)
    end
  end

  defp run_kill(k, pid) do
    p =
      Port.open({:spawn_executable, k}, [
        :exit_status,
        :hide,
        :stderr_to_stdout,
        args: ["-9", Integer.to_string(pid)]
      ])

    receive do
      {^p, {:exit_status, _}} -> flush(p)
    after
      2_000 -> :ok
    end
  end

  defp flush(port) do
    receive do
      {^port, _} -> flush(port)
    after
      0 -> :ok
    end
  end

  @doc false
  def __env__, do: env()

  # Cleared environment: every inherited variable is unset, then the allowlist
  # is copied back.
  defp env do
    keep =
      for k <- @env_allowlist,
          v = System.get_env(k),
          do: {String.to_charlist(k), String.to_charlist(v)}

    unset =
      for {k, _} <- System.get_env(), k not in @env_allowlist, do: {String.to_charlist(k), false}

    unset ++ keep
  end
end
