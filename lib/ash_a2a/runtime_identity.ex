defmodule AshA2A.RuntimeIdentity do
  @moduledoc """
  Runtime identity established from independently observable executable
  information rather than caller-controlled labels (RFC-SA2A-002 §126).

  A runtime module's `host_id/0` / `engine_id/0` are strings the module
  chooses. Two of them differing only by whitespace, case, Unicode width or
  zero-width format characters are the same label (`label_key/1`), and two
  modules with entirely different labels can still execute on the same
  engine. `observe_session/1` therefore walks a live, opened session term for
  the real resources executing it and observes each one from the outside:

    * a local BEAM process -> `"beam_process"`: the sha256 of the emulator
      executable the OS reports for this node, the module the process was
      actually started with (`$initial_call`, recorded by `:proc_lib`, not
      reported by the runtime module), that module's BEAM md5, its owning
      application, and a digest of the application's native (NIF) libraries.
    * a port -> `"os_process"`: the sha256 of the executable the OS reports
      for the port's OS pid (`/proc/<pid>/exe` when present, else `ps`).

  Process ids are deliberately excluded: two sessions of one engine are the
  same runtime implementation, not heterogeneous hosts.

  A session with no observable resource, or a resource whose executable
  cannot be observed, is `{:unobservable, detail}` -- never a guessed
  identity (§130 fail-closed).
  """

  @max_depth 12

  @doc """
  Normalization key for a caller-controlled runtime label: NFKC, every
  whitespace / separator / format character removed, then downcased.

      iex> AshA2A.RuntimeIdentity.label_key("BEAM/Wasmex ")
      "beam/wasmex"
      iex> AshA2A.RuntimeIdentity.label_key("beam/​WASMEX")
      "beam/wasmex"
  """
  @spec label_key(term()) :: String.t()
  def label_key(label) when is_binary(label) do
    normalized =
      case :unicode.characters_to_nfkc_binary(label) do
        binary when is_binary(binary) -> binary
        _ -> label
      end

    normalized
    |> String.replace(~r/[\s\p{Z}\p{Cf}]+/u, "")
    |> String.downcase()
  end

  def label_key(label), do: label |> inspect() |> label_key()

  @doc """
  Observed identity of every real resource inside an opened runtime session.
  Returns a sorted, de-duplicated list of identity maps.
  """
  @spec observe_session(term()) :: {:ok, [map()]} | {:unobservable, String.t()}
  def observe_session(session) do
    identities =
      session
      |> collect([], 0)
      |> Enum.uniq()
      |> Enum.map(&observe_resource/1)

    cond do
      identities == [] ->
        {:unobservable,
         "the session holds no local process or port whose executable can be observed"}

      Enum.any?(identities, &unobservable?/1) ->
        {:unobservable,
         "a session resource's executable could not be observed: " <>
           inspect(Enum.filter(identities, &unobservable?/1))}

      true ->
        {:ok, identities |> Enum.uniq() |> Enum.sort_by(&AshA2A.Chicago.Json.canonical/1)}
    end
  end

  @doc "sha256 of the observed identity list (for receipts and OCEL objects)."
  @spec digest([map()]) :: String.t()
  def digest(identities) when is_list(identities) do
    identities
    |> AshA2A.Chicago.Json.canonical()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  sha256 of the executable the operating system reports for `os_pid`, or
  `nil` when it cannot be observed.
  """
  @spec os_executable_sha256(String.t() | non_neg_integer()) :: String.t() | nil
  def os_executable_sha256(os_pid) do
    case os_executable_path(os_pid) do
      nil -> nil
      path -> file_sha256(path)
    end
  end

  @doc "Absolute path of the executable the OS reports for `os_pid`, or `nil`."
  @spec os_executable_path(String.t() | non_neg_integer()) :: Path.t() | nil
  def os_executable_path(os_pid) do
    pid = to_string(os_pid)
    proc = "/proc/#{pid}/exe"

    path =
      case :file.read_link_all(proc) do
        {:ok, target} ->
          to_string(target)

        _ ->
          case System.cmd("ps", ["-o", "comm=", "-p", pid], stderr_to_stdout: true) do
            {out, 0} -> String.trim(out)
            _ -> ""
          end
      end

    cond do
      path == "" -> nil
      Path.type(path) == :absolute and File.regular?(path) -> path
      found = System.find_executable(path) -> found
      true -> nil
    end
  rescue
    _ -> nil
  end

  @doc "Streaming sha256 of a file's bytes (symlinks followed), or `nil`."
  @spec file_sha256(Path.t()) :: String.t() | nil
  def file_sha256(path) do
    if File.regular?(path) do
      path
      |> File.stream!(1_048_576)
      |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)
    end
  rescue
    _ -> nil
  end

  # --- resource discovery ---------------------------------------------------

  defp collect(_term, acc, depth) when depth > @max_depth, do: acc
  defp collect(pid, acc, _depth) when is_pid(pid), do: [pid | acc]
  defp collect(port, acc, _depth) when is_port(port), do: [port | acc]

  defp collect(%{__struct__: _} = struct, acc, depth),
    do: struct |> Map.from_struct() |> collect(acc, depth + 1)

  defp collect(map, acc, depth) when is_map(map) do
    Enum.reduce(map, acc, fn {k, v}, a -> collect(v, collect(k, a, depth + 1), depth + 1) end)
  end

  defp collect([head | tail], acc, depth),
    do: collect(tail, collect(head, acc, depth + 1), depth)

  defp collect(tuple, acc, depth) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> collect(acc, depth + 1)

  defp collect(_other, acc, _depth), do: acc

  # --- observation ----------------------------------------------------------

  defp observe_resource(pid) when is_pid(pid) do
    if node(pid) == node() and Process.alive?(pid) do
      module = initial_module(pid)
      app = module && application(module)

      %{
        "kind" => "beam_process",
        "emulator_sha256" => os_executable_sha256(System.pid()),
        "engine_module" => module && inspect(module),
        "engine_module_md5" => module_md5(module),
        "engine_application" => app && Atom.to_string(app),
        "engine_native_sha256" => native_digest(app)
      }
    else
      %{"kind" => "beam_process", "emulator_sha256" => nil}
    end
  end

  defp observe_resource(port) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{"kind" => "os_process", "executable_sha256" => os_executable_sha256(os_pid)}

      _ ->
        %{"kind" => "os_process", "executable_sha256" => nil}
    end
  end

  defp unobservable?(%{"kind" => "beam_process"} = identity),
    do: is_nil(identity["emulator_sha256"]) or is_nil(identity["engine_module"])

  defp unobservable?(%{"kind" => "os_process"} = identity),
    do: is_nil(identity["executable_sha256"])

  defp initial_module(pid) do
    dictionary =
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> dict
        _ -> []
      end

    case Keyword.get(dictionary, :"$initial_call") do
      {module, _fun, _arity} ->
        module

      _ ->
        case Process.info(pid, :initial_call) do
          {:initial_call, {module, _fun, _arity}} -> module
          _ -> nil
        end
    end
  end

  defp application(module) do
    case :application.get_application(module) do
      {:ok, app} -> app
      :undefined -> nil
    end
  end

  defp module_md5(nil), do: nil

  defp module_md5(module) do
    if Code.ensure_loaded?(module),
      do: Base.encode16(module.module_info(:md5), case: :lower)
  end

  defp native_digest(nil), do: nil

  defp native_digest(app) do
    case :code.priv_dir(app) do
      {:error, _} ->
        nil

      priv ->
        libs =
          priv
          |> to_string()
          |> Path.join("**/*.{so,dylib,dll}")
          |> Path.wildcard()
          |> Enum.sort()
          |> Enum.map(&[Path.basename(&1), file_sha256(&1)])

        if libs == [],
          do: nil,
          else:
            libs
            |> JSON.encode!()
            |> then(&:crypto.hash(:sha256, &1))
            |> Base.encode16(case: :lower)
    end
  end
end
