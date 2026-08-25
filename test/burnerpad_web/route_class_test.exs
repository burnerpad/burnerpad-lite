# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule BurnerpadWeb.RouteClassTest do
  use ExUnit.Case, async: true

  alias BurnerpadWeb.RouteClass

  test "classifies every allowlisted route without retaining its concrete path" do
    cases = [
      {[], :home},
      {["s", "private-secret-id"], :secret_page},
      {["api", "secrets"], :secret_create},
      {["api", "secrets", "private-secret-id", "reveal"], :secret_reveal},
      {["api", "secrets", "private-secret-id", "burn"], :secret_burn},
      {["api", "edge", "source-check"], :edge_source_check},
      {["stats"], :stats_page},
      {["api", "stats"], :stats_api},
      {["terms"], :terms},
      {[".well-known", "security.txt"], :security_contact}
    ]

    for {path_info, expected} <- cases do
      assert RouteClass.classify(path_info) == expected
    end
  end

  test "groups unknown API routes without mistaking lookalikes for capability operations" do
    assert RouteClass.classify(["api"]) == :api_other
    assert RouteClass.classify(["api", "anything"]) == :api_other

    assert RouteClass.classify(["api", "secrets", "private-secret-id", "reveal", "extra"]) ==
             :api_other

    assert RouteClass.classify(["api", "secrets", "private-secret-id", "burned"]) == :api_other
    assert RouteClass.classify(["api", "edge", "source-check", "extra"]) == :api_other
    assert RouteClass.classify(["api", "edge", "source-check-private"]) == :api_other
  end

  test "collapses every other path to one safe class" do
    assert RouteClass.classify(["anything", "reveal"]) == :unmatched
    assert RouteClass.classify(["s", "private-secret-id", "extra"]) == :unmatched
    assert RouteClass.classify([".well-known", "security.txt", "extra"]) == :unmatched
    assert RouteClass.classify(["private", "path", "marker"]) == :unmatched
  end
end
