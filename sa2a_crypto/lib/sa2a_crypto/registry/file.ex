defmodule Sa2aCrypto.Registry.File do
  @moduledoc """
  Durable, pinned key registry.

  The registry is one canonical JSON document (RFC 8785 via `Jcs`):

      {"v":1,"epoch":N,"keys":[{"kid","custodian_id","custody_tier","alg","spki_der",
        "state","activated_at","not_after","revocation_epoch","attestation"}, ...]}

  keys sorted by `kid`; `spki_der` base64url. The registry ROOT is
  `sha256(Jcs(document))` (lowercase hex). `load/2` REFUSES a file whose root differs from
  the caller's pin (`:registry_root_mismatch`), a file that is not the canonical document
  shape (`:registry_corrupt`) and a record whose `kid` is not the hash of its own key.
  Every mutation requires the current pin, is serialized per path, writes atomically
  (temp file, `fsync`, rename) and returns the NEW root, which the caller must re-pin.

  `epoch` is the registry revocation epoch: monotonic, durable, bumped only by `revoke/3`.
  A record's `revocation_epoch` is the registry epoch when the record was enrolled, or the
  epoch at which it was revoked.

  The value returned by `load/2` is a registry VIEW `{Sa2aCrypto.Registry.File, state}`
  usable anywhere `Sa2aCrypto.verify_envelope/4` takes a registry (an immutable snapshot).

  Limits: the per-path lock is node-local (`:global.trans` on `[node()]`); directory fsync
  after the rename is attempted best-effort.
  """
  @behaviour Sa2aCrypto.Registry

  alias Sa2aCrypto.{KeyRecord, KeyRef, Suite}
  alias Sa2aCrypto.Registry.{Lifecycle, Spki}

  @v 1
  @states KeyRecord.states()
  @tiers KeyRecord.tiers()

  @type view :: {module(), map()}

  # -- creation / loading --------------------------------------------------------

  @doc "Creates an empty registry file (refuses to overwrite). Returns its root."
  @spec create(Path.t()) :: {:ok, String.t()} | {:error, atom()}
  def create(path) do
    if Elixir.File.exists?(path) do
      {:error, :registry_exists}
    else
      doc = %{"v" => @v, "epoch" => 0, "keys" => []}
      with :ok <- write(path, doc), do: {:ok, root_of(doc)}
    end
  end

  @doc "Root (hex sha256 of the canonical document) of the document at `path`."
  @spec root(Path.t()) :: {:ok, String.t()} | {:error, atom()}
  def root(path) do
    with {:ok, doc} <- read_doc(path), do: {:ok, root_of(doc)}
  end

  @doc "Loads the registry at `path`, refusing unless its root equals `pin`."
  @spec load(Path.t(), String.t()) :: {:ok, view()} | {:error, atom()}
  def load(path, pin) when is_binary(pin) do
    with {:ok, doc} <- read_doc(path),
         :ok <- check_pin(doc, pin),
         {:ok, entries} <- decode_entries(doc) do
      {:ok, {__MODULE__, %{entries: entries, root: root_of(doc), epoch: doc["epoch"]}}}
    end
  end

  def load(_, _), do: {:error, :pin_required}

  @impl true
  def lookup(%{entries: entries}, kid) do
    case Map.fetch(entries, kid) do
      {:ok, %{record: r}} -> {:ok, r}
      :error -> :error
    end
  end

  @doc "Registry revocation epoch of a loaded view."
  @spec epoch(view()) :: non_neg_integer()
  def epoch({__MODULE__, %{epoch: e}}), do: e

  @doc "Root of a loaded view."
  @spec view_root(view()) :: String.t()
  def view_root({__MODULE__, %{root: r}}), do: r

  @doc "Full stored entry (record plus activated_at and attestation) for a kid."
  @spec entry(view(), String.t()) :: {:ok, map()} | :error
  def entry({__MODULE__, %{entries: e}}, kid), do: Map.fetch(e, kid)

  # -- mutations -----------------------------------------------------------------

  @doc """
  Enrols a key (state `:pre_activation` or `:active`). Options: `:pin` (required),
  `:activated_at`, `:attestation` (JSON-able map or nil).
  """
  @spec enroll(Path.t(), KeyRecord.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def enroll(path, %KeyRecord{} = rec, opts) do
    mutate(path, opts, fn doc ->
      with :ok <- check_record(rec),
           :ok <- absent(doc, rec.kid),
           :ok <- enrollable(rec.state) do
        {:ok, put_key(doc, encode_record(rec, doc["epoch"], opts))}
      end
    end)
  end

  @doc "Moves `kid` to state `to`; illegal SP 800-57 transitions are refused."
  @spec transition(Path.t(), String.t(), atom(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def transition(path, kid, to, opts) when to in @states do
    mutate(path, opts, fn doc ->
      with {:ok, key} <- fetch_key(doc, kid),
           :ok <- Lifecycle.check(String.to_existing_atom(key["state"]), to) do
        key = %{key | "state" => Atom.to_string(to)}

        key =
          if to == :active,
            do: Map.put_new_lazy(key, "activated_at", fn -> now(opts) end),
            else: key

        {:ok, put_key(doc, key)}
      end
    end)
  end

  def transition(_, _, _, _), do: {:error, :unknown_state}

  @doc """
  Revokes `kid` (state `:compromised`) and advances the registry epoch. The epoch is
  `current + 1`, or `opts[:epoch]` which must be strictly greater than the current epoch.
  """
  @spec revoke(Path.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, atom()}
  def revoke(path, kid, opts) do
    mutate(path, opts, fn doc ->
      cur = doc["epoch"]
      new = Keyword.get(opts, :epoch, cur + 1)

      with true <- (is_integer(new) and new > cur) or {:error, :epoch_not_monotonic},
           {:ok, key} <- fetch_key(doc, kid),
           :ok <- Lifecycle.check(String.to_existing_atom(key["state"]), :compromised) do
        key = %{key | "state" => "compromised", "revocation_epoch" => new}
        {:ok, doc |> put_key(key) |> Map.put("epoch", new)}
      end
    end)
  end

  @doc """
  Rotation with an overlap window: enrols `new_record` as `:active` and caps the old key's
  `not_after` at `now + overlap` (seconds, default 0 = immediate). The old key stays
  `:active` and usable until then; finish with `transition(path, old_kid, :deactivated, _)`.
  """
  @spec rotate(Path.t(), String.t(), KeyRecord.t(), keyword()) ::
          {:ok, String.t()} | {:error, atom()}
  def rotate(path, old_kid, %KeyRecord{} = new, opts) do
    mutate(path, opts, fn doc ->
      overlap = Keyword.get(opts, :overlap, 0)
      cap = now(opts) + overlap

      with :ok <- check_record(new),
           true <-
             (new.state == :active and is_integer(overlap) and overlap >= 0) or
               {:error, :bad_rotation},
           :ok <- absent(doc, new.kid),
           {:ok, old} <- fetch_key(doc, old_kid),
           true <- old["state"] == "active" or {:error, :old_key_not_active} do
        na = if is_integer(old["not_after"]), do: min(old["not_after"], cap), else: cap
        old = %{old | "not_after" => na}
        {:ok, doc |> put_key(old) |> put_key(encode_record(new, doc["epoch"], opts))}
      end
    end)
  end

  # -- internals -----------------------------------------------------------------

  defp mutate(path, opts, fun) do
    pin = Keyword.get(opts, :pin)

    :global.trans({{__MODULE__, Path.expand(path)}, self()}, fn ->
      with true <- is_binary(pin) or {:error, :pin_required},
           {:ok, doc} <- read_doc(path),
           :ok <- check_pin(doc, pin),
           {:ok, doc2} <- fun.(doc),
           {:ok, _} <- decode_entries(doc2),
           :ok <- write(path, doc2) do
        {:ok, root_of(doc2)}
      end
    end)
    |> case do
      :aborted -> {:error, :registry_locked}
      other -> other
    end
  end

  defp now(opts), do: Keyword.get(opts, :now) || System.os_time(:second)

  defp check_pin(doc, pin) do
    if secure_eq(root_of(doc), pin), do: :ok, else: {:error, :registry_root_mismatch}
  end

  defp secure_eq(a, b) when byte_size(a) == byte_size(b), do: :crypto.hash_equals(a, b)
  defp secure_eq(_, _), do: false

  defp root_of(doc), do: :crypto.hash(:sha256, Jcs.encode(doc)) |> Base.encode16(case: :lower)

  defp read_doc(path) do
    with {:ok, bin} <- Elixir.File.read(path),
         {:ok, %{"v" => @v, "epoch" => e, "keys" => keys} = doc}
         when is_integer(e) and e >= 0 and is_list(keys) and map_size(doc) == 3 <-
           Jason.decode(bin) do
      {:ok, doc}
    else
      {:error, :enoent} -> {:error, :registry_missing}
      _ -> {:error, :registry_corrupt}
    end
  end

  defp decode_entries(%{"keys" => keys, "epoch" => epoch}) do
    kids = Enum.map(keys, &(is_map(&1) && &1["kid"]))

    with true <-
           (kids == Enum.sort(kids) and kids == Enum.uniq(kids)) or {:error, :registry_corrupt} do
      Enum.reduce_while(keys, {:ok, %{}}, fn k, {:ok, acc} ->
        case decode_key(k, epoch) do
          {:ok, entry} -> {:cont, {:ok, Map.put(acc, k["kid"], entry)}}
          {:error, _} = e -> {:halt, e}
        end
      end)
    end
  end

  @fields ~w(kid custodian_id custody_tier alg spki_der state activated_at not_after revocation_epoch attestation)

  defp decode_key(%{} = k, epoch) do
    with true <- Enum.sort(Map.keys(k)) == Enum.sort(@fields) or {:error, :registry_corrupt},
         true <-
           (is_binary(k["kid"]) and is_binary(k["custodian_id"])) or {:error, :registry_corrupt},
         {:ok, tier} <- to_enum(k["custody_tier"], @tiers),
         {:ok, state} <- to_enum(k["state"], @states),
         true <-
           (is_binary(k["alg"]) and Suite.profile_of(k["alg"]) != nil) or
             {:error, :registry_corrupt},
         {:ok, der} <- b64(k["spki_der"]),
         {:ok, pub} <- Spki.decode(k["alg"], der),
         {:ok, kid} <- KeyRef.kid(k["alg"], pub) |> ok_or(:registry_corrupt),
         true <- kid == k["kid"] or {:error, :kid_key_mismatch},
         true <-
           (int_or_nil(k["not_after"]) and int_or_nil(k["activated_at"])) or
             {:error, :registry_corrupt},
         true <-
           (is_integer(k["revocation_epoch"]) and k["revocation_epoch"] >= 0 and
              k["revocation_epoch"] <= epoch) or {:error, :registry_corrupt} do
      {:ok,
       %{
         record: %KeyRecord{
           kid: kid,
           alg: k["alg"],
           public_key: pub,
           custodian_id: k["custodian_id"],
           custody_tier: tier,
           state: state,
           revocation_epoch: k["revocation_epoch"],
           not_after: k["not_after"]
         },
         activated_at: k["activated_at"],
         attestation: k["attestation"]
       }}
    end
  end

  defp decode_key(_, _), do: {:error, :registry_corrupt}

  defp ok_or({:ok, v}, _), do: {:ok, v}
  defp ok_or(_, code), do: {:error, code}

  defp int_or_nil(nil), do: true
  defp int_or_nil(i), do: is_integer(i)

  defp to_enum(s, allowed) when is_binary(s) do
    case Enum.find(allowed, &(Atom.to_string(&1) == s)) do
      nil -> {:error, :registry_corrupt}
      a -> {:ok, a}
    end
  end

  defp to_enum(_, _), do: {:error, :registry_corrupt}

  defp b64(s) when is_binary(s) do
    with {:ok, bin} <- Base.url_decode64(s, padding: false),
         true <- Base.url_encode64(bin, padding: false) == s do
      {:ok, bin}
    else
      _ -> {:error, :registry_corrupt}
    end
  end

  defp b64(_), do: {:error, :registry_corrupt}

  defp check_record(%KeyRecord{kid: kid, alg: alg, public_key: pub, custody_tier: t}) do
    cond do
      t not in @tiers -> {:error, :bad_tier}
      is_nil(Suite.profile_of(alg)) -> {:error, :unsupported_algorithm}
      KeyRef.kid(alg, pub) != {:ok, kid} -> {:error, :kid_key_mismatch}
      true -> :ok
    end
  end

  defp enrollable(s) when s in [:pre_activation, :active], do: :ok
  defp enrollable(_), do: {:error, :illegal_transition}

  defp absent(doc, kid) do
    if Enum.any?(doc["keys"], &(&1["kid"] == kid)), do: {:error, :duplicate_kid}, else: :ok
  end

  defp fetch_key(doc, kid) do
    case Enum.find(doc["keys"], &(&1["kid"] == kid)) do
      nil -> {:error, :unknown_kid}
      k -> {:ok, k}
    end
  end

  defp put_key(doc, key) do
    keys =
      doc["keys"]
      |> Enum.reject(&(&1["kid"] == key["kid"]))
      |> Kernel.++([key])
      |> Enum.sort_by(& &1["kid"])

    %{doc | "keys" => keys}
  end

  defp encode_record(%KeyRecord{} = r, epoch, opts) do
    {:ok, spki} = KeyRef.spki(r.alg, r.public_key)

    %{
      "kid" => r.kid,
      "custodian_id" => r.custodian_id,
      "custody_tier" => Atom.to_string(r.custody_tier),
      "alg" => r.alg,
      "spki_der" => Base.url_encode64(spki, padding: false),
      "state" => Atom.to_string(r.state),
      "activated_at" => Keyword.get(opts, :activated_at) || if(r.state == :active, do: now(opts)),
      "not_after" => r.not_after,
      "revocation_epoch" => epoch,
      "attestation" => Keyword.get(opts, :attestation)
    }
  end

  defp write(path, doc) do
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"
    bin = Jcs.encode(doc)

    with {:ok, io} <- Elixir.File.open(tmp, [:write, :binary, :raw]),
         :ok <- :file.write(io, bin),
         :ok <- :file.sync(io),
         :ok <- :file.close(io),
         :ok <- Elixir.File.rename(tmp, path) do
      sync_dir(Path.dirname(path))
      :ok
    else
      {:error, _} = e ->
        Elixir.File.rm(tmp)
        e
    end
  end

  # Best effort: directories cannot be opened for sync on every platform.
  defp sync_dir(dir) do
    case :file.open(String.to_charlist(dir), [:read, :raw]) do
      {:ok, io} ->
        :file.sync(io)
        :file.close(io)

      _ ->
        :ok
    end
  end
end
