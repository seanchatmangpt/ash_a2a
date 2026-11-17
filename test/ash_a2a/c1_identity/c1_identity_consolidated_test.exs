# SPDX-FileCopyrightText: 2026 ash_a2a contributors <https://github.com/seanchatmangpt/ash_a2a/graphs/contributors>
# SPDX-License-Identifier: MIT

# ==============================================================================
# Consolidated Test Suite: c1_identity
# Consolidated from 20 source files
# ==============================================================================


# ------------------------------------------------------------------------------
# Section 1: test/ash_a2a/c1_identity/array_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.ArrayTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/array.json", __DIR__)
  test "accept array" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 2: test/ash_a2a/c1_identity/deep_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.DeepTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/deep.json", __DIR__)
  test "bounded nesting" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 3: test/ash_a2a/c1_identity/effect_sep_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.EffectSepTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/effect_sep.json", __DIR__)
  test "effect separation" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 4: test/ash_a2a/c1_identity/effect_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.EffectTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/effect.json", __DIR__)
  test "effect schema" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 5: test/ash_a2a/c1_identity/empty_array_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.EmptyArrayTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/empty_array.json", __DIR__)
  test "accept empty array" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 6: test/ash_a2a/c1_identity/empty_object_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.EmptyObjectTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/empty_object.json", __DIR__)
  test "accept empty object" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 7: test/ash_a2a/c1_identity/float_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.FloatTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/float.json", __DIR__)
  # RFC-SA2A-007 errata E-F: portable identity refuses floats (the vector's
  # own purpose is "refuse float"); RFC 8785 would admit them, identity does not.
  test "identity canonicalization refuses floats (RFC-007 E-F)" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert {:error, :canonical_float_forbidden} = Canonical.digest(v)
  end
end


# ------------------------------------------------------------------------------
# Section 8: test/ash_a2a/c1_identity/integer_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.IntegerTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/integer.json", __DIR__)
  test "accept integer" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 9: test/ash_a2a/c1_identity/key_order_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.KeyOrderTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/key_order.json", __DIR__)
  test "canonical key order" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 10: test/ash_a2a/c1_identity/negative_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.NegativeTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/negative.json", __DIR__)
  test "accept negative integer" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 11: test/ash_a2a/c1_identity/nested_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.NestedTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/nested.json", __DIR__)
  test "accept nested" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 12: test/ash_a2a/c1_identity/null_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.NullTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/null.json", __DIR__)
  test "accept scalar null" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 13: test/ash_a2a/c1_identity/object_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.ObjectTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/object.json", __DIR__)
  test "accept object" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 14: test/ash_a2a/c1_identity/request_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.RequestTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/request.json", __DIR__)
  test "request schema" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 15: test/ash_a2a/c1_identity/schema_tag_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.SchemaTagTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/schema_tag.json", __DIR__)
  test "schema tag" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 16: test/ash_a2a/c1_identity/string_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.StringTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/string.json", __DIR__)
  test "accept utf8 string" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 17: test/ash_a2a/c1_identity/subject_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.SubjectTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/subject.json", __DIR__)
  test "exact subject" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 18: test/ash_a2a/c1_identity/true_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.TrueTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/true.json", __DIR__)
  test "accept boolean" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 19: test/ash_a2a/c1_identity/unicode_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.UnicodeTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/unicode.json", __DIR__)
  test "accept unicode" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end


# ------------------------------------------------------------------------------
# Section 20: test/ash_a2a/c1_identity/zero_test.exs
# ------------------------------------------------------------------------------
defmodule AshA2A.C1Identity.ZeroTest do
  use ExUnit.Case, async: true
  alias AshA2A.Identity.Canonical
  @vector Path.expand("../../../priv/sa2a/c1/identity_vectors/zero.json", __DIR__)
  test "accept zero" do
    v = @vector |> File.read!() |> Jason.decode!() |> Map.fetch!("value")
    assert match?({:ok, "sha256:" <> digest} when byte_size(digest) == 64, Canonical.digest(v))
  end
end
