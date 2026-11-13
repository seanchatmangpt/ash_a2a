# SPDX-License-Identifier: MIT

defmodule AshA2A.Authority.AllowAllGuardTest do
  use ExUnit.Case, async: false

  alias AshA2A.Authority.Source.AllowAll

  test "prod env is denied, other envs allowed" do
    assert {:deny, :allow_all_in_prod} = AllowAll.__check__(:prod, "a", :x, %{}, [])
    assert :ok = AllowAll.__check__(:test, "a", :x, %{}, [])
  end

  test "runtime release marker denies even in a non-prod compile" do
    old = System.get_env("RELEASE_NAME")
    System.put_env("RELEASE_NAME", "ash_a2a")

    on_exit(fn ->
      if old, do: System.put_env("RELEASE_NAME", old), else: System.delete_env("RELEASE_NAME")
    end)

    assert {:deny, :allow_all_in_prod} = AllowAll.check("a", :x, %{}, [])
  end
end
