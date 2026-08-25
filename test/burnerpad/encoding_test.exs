# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.EncodingTest do
  use ExUnit.Case, async: true
  alias Burnerpad.Encoding

  test "accepts exactly canonical unpadded base64url" do
    assert {:ok, <<1>>} = Encoding.decode64url("AQ")

    for invalid <- ["AR", "AQ==", "AQ\n", "AQ+", "A", 1, nil] do
      assert :error = Encoding.decode64url(invalid)
    end
  end

  test "can require an exact decoded byte length" do
    token = Base.url_encode64(:binary.copy(<<7>>, 32), padding: false)
    assert {:ok, bytes} = Encoding.decode64url(token, 32)
    assert byte_size(bytes) == 32
    assert :error = Encoding.decode64url("AQ", 32)
  end
end
