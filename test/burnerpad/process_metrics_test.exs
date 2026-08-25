# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Impulsa SLU

defmodule Burnerpad.ProcessMetricsTest do
  use ExUnit.Case, async: true

  alias Burnerpad.ProcessMetrics

  test "returns zero for an absent registered process" do
    assert ProcessMetrics.queue_length(__MODULE__.Missing) == 0
  end

  test "reads a process mailbox by pid and registered name" do
    pid = spawn(fn -> receive do: (:release -> :ok) end)
    Process.register(pid, __MODULE__.Probe)
    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    send(pid, :queued)

    assert ProcessMetrics.queue_length(pid) == 1
    assert ProcessMetrics.queue_length(__MODULE__.Probe) == 1

    send(pid, :release)
  end
end
