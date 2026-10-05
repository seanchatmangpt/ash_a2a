# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule C2Harness.Scan do
  @moduledoc """
  Proves the control-plane environment contains no key material it must not hold.

  The haystack is everything the attacker can read as the control plane: the whole OS
  environment of the test VM, the application environment of every loaded application, its
  own `ControlPlane` struct and its process dictionary. It is sent to the KEYMASTER (the only
  process that knows the secrets), which searches it for every private key it holds EXCEPT
  the deliberately compromised ones (A, A2, alice), in raw / base64url / base64 / hex forms,
  for the key file contents (authority policy key, actuator TLS server key) and for the
  key-file/state-directory paths. The keymaster returns only the NAMES of leaks.

  Anti-vacuity: `selftest/1` asks the keymaster to plant each of its own secrets in a
  haystack and run the same matcher; the court fails unless every needle fires.
  """
  alias C2Harness.Fleet

  @spec control_plane(GenServer.server(), C2Harness.ControlPlane.t()) :: map()
  def control_plane(fleet, cp) do
    lim = [limit: :infinity, printable_limit: :infinity, charlists: :as_lists]

    apps =
      for {app, _, _} <- Application.loaded_applications(),
          do: {app, Application.get_all_env(app)}

    hay =
      Enum.join(
        [
          inspect(System.get_env(), lim),
          inspect(apps, lim),
          inspect(cp, lim),
          inspect(Process.get(), lim)
        ],
        "\n"
      )

    {:ok, %{"ok" => true, "leaks" => leaks, "needle_names" => names}} =
      Fleet.km(fleet, %{"op" => "scan", "haystack" => Base.encode64(hay)})

    {:ok, %{"ok" => true, "leaks" => planted, "needle_names" => pnames}} =
      Fleet.km(fleet, %{"op" => "scan", "selftest" => true})

    %{
      haystack_bytes: byte_size(hay),
      sources: [
        "System.get_env/0",
        "Application.get_all_env/1 for every loaded app",
        "ControlPlane struct",
        "process dictionary"
      ],
      leaks: leaks,
      needles: names,
      selftest_detected: planted,
      selftest_complete:
        Enum.sort(pnames) == Enum.sort(planted) or Enum.all?(pnames, &(&1 in planted)),
      compromised_by_design: Map.keys(cp.compromised)
    }
  end
end
