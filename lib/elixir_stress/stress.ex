defmodule ElixirStress.Stress do
  @moduledoc false

  @tmp_dir "/tmp/elixir_stress"

  def run(duration_seconds \\ 30) do
    File.mkdir_p!(@tmp_dir)

    # Shared ETS that persists for the duration — visible in ETS tab
    shared = :ets.new(:stress_shared, [:public, :set, :named_table,
      read_concurrency: true, write_concurrency: true])

    workers =
      # 10 memory hogs — each holds hundreds of MB
      replicate(10, fn -> memory_hog(duration_seconds) end) ++
      # CPU burners — saturate all schedulers
      replicate(System.schedulers_online() * 2, fn -> cpu_saturate(duration_seconds) end) ++
      # 4 disk thrashers
      replicate(4, fn -> disk_thrash(duration_seconds) end) ++
      # Process explosion
      replicate(2, fn -> process_explosion(duration_seconds) end) ++
      # ETS bloat
      replicate(2, fn -> ets_bloat(duration_seconds, shared) end) ++
      # GC torture
      replicate(4, fn -> gc_torture(duration_seconds) end) ++
      # Binary heap abuse
      replicate(4, fn -> binary_abuse(duration_seconds) end) ++
      # Message queue backup
      replicate(2, fn -> message_queue_pressure(duration_seconds) end) ++
      # Port churn
      replicate(2, fn -> port_churn(duration_seconds) end) ++
      # Atom growth
      [Task.async(fn -> atom_growth(duration_seconds) end)]

    results = Task.yield_many(workers, :timer.seconds(duration_seconds + 30))

    File.rm_rf!(@tmp_dir)
    try do :ets.delete(shared) rescue _ -> :ok end

    Enum.map(results, fn {task, res} ->
      case res do
        {:ok, val} -> val
        nil -> Task.shutdown(task, :brutal_kill); :timeout
      end
    end)
  end

  defp replicate(n, fun), do: for(_ <- 1..n, do: Task.async(fun))

  # ============================================================
  # MEMORY HOG — each worker holds 50-200MB in its process heap
  # This WILL show up on the Home tab memory gauges
  # ============================================================
  defp memory_hog(seconds) do
    deadline = deadline(seconds)
    memory_hog_loop(deadline, [], 0)
  end

  defp memory_hog_loop(deadline, held, cycles) do
    if past?(deadline) do
      {:memory_hog, cycles: cycles, held_mb: div(:erlang.external_size(held), 1_048_576)}
    else
      # Always be growing — allocate 5-20MB per cycle
      new_chunks = for _ <- 1..Enum.random([5, 10, 20]) do
        case Enum.random(1..4) do
          1 ->
            Enum.to_list(1..Enum.random([500_000, 1_000_000, 2_000_000]))
          2 ->
            :crypto.strong_rand_bytes(Enum.random([1_048_576, 2_097_152, 4_194_304]))
          3 ->
            Map.new(1..Enum.random([100_000, 500_000]), fn i ->
              {i, :crypto.strong_rand_bytes(32)}
            end)
          4 ->
            build_nested(Enum.random([10, 15, 20]))
        end
      end

      held = new_chunks ++ held

      Enum.each(held, fn chunk ->
        :erlang.phash2(chunk)
      end)

      held = if length(held) > Enum.random([30, 50, 80]) do
        drop = Enum.random([div(length(held), 4), div(length(held), 3)])
        Enum.drop(held, drop)
      else
        held
      end

      memory_hog_loop(deadline, held, cycles + 1)
    end
  end

  defp build_nested(0), do: :crypto.strong_rand_bytes(4096)
  defp build_nested(depth) do
    %{
      left: build_nested(depth - 1),
      right: build_nested(depth - 1),
      data: Enum.to_list(1..1000),
      bin: :crypto.strong_rand_bytes(1024)
    }
  end

  # ============================================================
  # CPU SATURATE — tight loops that pin schedulers at 100%
  # ============================================================
  defp cpu_saturate(seconds) do
    deadline = deadline(seconds)
    cpu_saturate_loop(deadline, 0)
  end

  defp cpu_saturate_loop(deadline, cycles) do
    if past?(deadline), do: {:cpu_saturate, cycles},
    else: (
      case Enum.random(1..6) do
        1 -> fib(Enum.random([35, 36, 37, 38]))
        2 ->
          data = for _ <- 1..5_000_000, do: :rand.uniform(100_000_000)
          Enum.sort(data)
          |> Enum.chunk_every(1000)
          |> Enum.map(&Enum.sum/1)
        3 ->
          blob = :crypto.strong_rand_bytes(4_194_304)
          Enum.reduce(1..1_000, blob, fn _, acc ->
            :crypto.hash(:sha256, acc)
          end)
        4 ->
          size = 300
          a = for _ <- 1..size, do: (for _ <- 1..size, do: :rand.uniform(1000))
          b = for _ <- 1..size, do: (for _ <- 1..size, do: :rand.uniform(1000))
          bt = Enum.zip_with(b, &Function.identity/1)
          for row <- a do
            for col <- bt do
              Enum.zip_with(row, col, &Kernel.*/2) |> Enum.sum()
            end
          end
        5 -> ackermann(3, Enum.random([10, 11, 12]))
        6 ->
          permutations(Enum.to_list(1..Enum.random([9, 10])))
          |> Enum.take(100_000)
          |> Enum.map(&Enum.sum/1)
      end

      cpu_saturate_loop(deadline, cycles + 1)
    )
  end

  defp fib(0), do: 0
  defp fib(1), do: 1
  defp fib(n), do: fib(n - 1) + fib(n - 2)

  defp ackermann(0, n), do: n + 1
  defp ackermann(m, 0), do: ackermann(m - 1, 1)
  defp ackermann(m, n), do: ackermann(m - 1, ackermann(m, n - 1))

  defp permutations([]), do: [[]]
  defp permutations(list) do
    for elem <- list, rest <- permutations(list -- [elem]), do: [elem | rest]
  end

  # ============================================================
  # DISK THRASH
  # ============================================================
  defp disk_thrash(seconds) do
    deadline = deadline(seconds)
    disk_thrash_loop(deadline, 0)
  end

  defp disk_thrash_loop(deadline, cycles) do
    if past?(deadline), do: {:disk_thrash, cycles},
    else: (
      path = Path.join(@tmp_dir, "thrash_#{:erlang.unique_integer([:positive])}.bin")

      f = File.open!(path, [:write, :raw])
      chunk = :crypto.strong_rand_bytes(1_048_576)
      count = Enum.random([20, 50, 100])
      Enum.each(1..count, fn _ -> IO.binwrite(f, chunk) end)
      File.close(f)

      case File.read(path) do
        {:ok, data} ->
          :crypto.hash(:sha256, data)
          modified = :crypto.hash(:sha512, data) |> String.duplicate(div(byte_size(data), 64))
          File.write!(path, modified)
        _ -> :ok
      end

      File.rm(path)
      disk_thrash_loop(deadline, cycles + 1)
    )
  end

  # ============================================================
  # PROCESS EXPLOSION
  # ============================================================
  defp process_explosion(seconds) do
    deadline = deadline(seconds)
    explosion_loop(deadline, [], 0)
  end

  defp explosion_loop(deadline, alive, cycles) do
    if past?(deadline) do
      Enum.each(alive, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      {:process_explosion, cycles}
    else
      batch = for _ <- 1..Enum.random([2_000, 5_000, 10_000]) do
        spawn(fn ->
          data = Enum.to_list(1..Enum.random([1_000, 5_000, 10_000]))
          Enum.reduce(data, 0, fn x, acc -> acc + x * x end)
          receive do :die -> :ok after Enum.random([1_000, 3_000, 5_000]) -> :ok end
        end)
      end

      alive = (batch ++ alive) |> Enum.filter(&Process.alive?/1)
      if length(alive) > 20_000 do
        {to_kill, to_keep} = Enum.split(alive, 10_000)
        Enum.each(to_kill, fn pid -> Process.exit(pid, :kill) end)
        explosion_loop(deadline, to_keep, cycles + 1)
      else
        explosion_loop(deadline, alive, cycles + 1)
      end
    end
  end

  # ============================================================
  # ETS BLOAT
  # ============================================================
  defp ets_bloat(seconds, shared) do
    deadline = deadline(seconds)
    tables = for _ <- 1..5 do
      :ets.new(:bloat, [Enum.random([:set, :ordered_set, :bag]), :public])
    end
    ets_bloat_loop(deadline, [shared | tables], 0)
  end

  defp ets_bloat_loop(deadline, tables, cycles) do
    if past?(deadline) do
      tl(tables) |> Enum.each(fn t -> try do :ets.delete(t) rescue _ -> :ok end end)
      {:ets_bloat, cycles}
    else
      t = Enum.random(tables)

      case Enum.random(1..5) do
        1 ->
          Enum.each(1..50_000, fn i ->
            :ets.insert(t, {
              {:rand.uniform(1_000_000), i},
              :crypto.strong_rand_bytes(Enum.random([256, 512, 1024])),
              Enum.to_list(1..Enum.random([50, 100]))
            })
          end)
        2 ->
          :ets.foldl(fn row, acc -> :erlang.phash2(row) + acc end, 0, t)
        3 ->
          :ets.select(t, [{:_, [], [true]}])
        4 ->
          :ets.delete_all_objects(t)
          Enum.each(1..20_000, fn i ->
            :ets.insert(t, {i, :crypto.strong_rand_bytes(512)})
          end)
        5 ->
          Enum.each(1..10_000, fn _ ->
            key = :rand.uniform(10_000)
            :ets.insert(t, {key, :crypto.strong_rand_bytes(256), System.monotonic_time()})
          end)
      end

      ets_bloat_loop(deadline, tables, cycles + 1)
    end
  end

  # ============================================================
  # GC TORTURE
  # ============================================================
  defp gc_torture(seconds) do
    deadline = deadline(seconds)
    gc_torture_loop(deadline, 0)
  end

  defp gc_torture_loop(deadline, cycles) do
    if past?(deadline), do: {:gc_torture, cycles},
    else: (
      _garbage = for _ <- 1..100 do
        case Enum.random(1..4) do
          1 -> Enum.to_list(1..1_000_000)
          2 -> :crypto.strong_rand_bytes(4_194_304)
          3 -> Map.new(1..100_000, fn i -> {i, make_ref()} end)
          4 -> String.duplicate("garbage!", 500_000)
        end
      end

      :erlang.garbage_collect()

      _more = for _ <- 1..50 do
        Enum.to_list(1..500_000)
      end

      :erlang.garbage_collect()

      pids = for _ <- 1..50 do
        spawn(fn ->
          _junk = for _ <- 1..20 do
            :crypto.strong_rand_bytes(Enum.random([1_048_576, 2_097_152]))
          end
          :erlang.garbage_collect()
        end)
      end

      Enum.each(pids, fn pid ->
        ref = Process.monitor(pid)
        receive do {:DOWN, ^ref, _, _, _} -> :ok after 2000 -> :ok end
      end)

      gc_torture_loop(deadline, cycles + 1)
    )
  end

  # ============================================================
  # BINARY ABUSE
  # ============================================================
  defp binary_abuse(seconds) do
    deadline = deadline(seconds)
    binary_abuse_loop(deadline, [], 0)
  end

  defp binary_abuse_loop(deadline, held, cycles) do
    if past?(deadline), do: {:binary_abuse, cycles},
    else: (
      new_bins = for _ <- 1..Enum.random([10, 20, 30]) do
        big = :crypto.strong_rand_bytes(Enum.random([2_097_152, 4_194_304, 8_388_608]))
        subs = for i <- 0..9 do
          offset = div(byte_size(big), 10) * i
          binary_part(big, offset, 1024)
        end
        Enum.each(1..5, fn _ ->
          spawn(fn ->
            Enum.each(subs, fn sub -> :crypto.hash(:sha256, sub) end)
            Process.sleep(Enum.random([500, 1_000, 2_000]))
          end)
        end)
        big
      end

      held = new_bins ++ held

      held = if length(held) > 50 do
        Enum.take(held, 30)
      else
        held
      end

      Enum.each(held, fn b -> :erlang.phash2(b) end)

      binary_abuse_loop(deadline, held, cycles + 1)
    )
  end

  # ============================================================
  # MESSAGE QUEUE PRESSURE
  # ============================================================
  defp message_queue_pressure(seconds) do
    deadline = deadline(seconds)
    msg_pressure_loop(deadline, 0)
  end

  defp msg_pressure_loop(deadline, cycles) do
    if past?(deadline), do: {:message_queue_pressure, cycles},
    else: (
      targets = for _ <- 1..Enum.random([10, 20, 30]) do
        spawn(fn -> slow_consume(0) end)
      end

      Enum.each(targets, fn target ->
        spawn(fn ->
          Enum.each(1..10_000, fn i ->
            if Process.alive?(target) do
              send(target, {:work, i, Enum.to_list(1..Enum.random([100, 500, 1000]))})
            end
          end)
        end)
      end)

      Process.sleep(Enum.random([500, 1_000, 2_000]))

      Enum.each(targets, fn pid ->
        if Process.alive?(pid), do: Process.exit(pid, :kill)
      end)

      msg_pressure_loop(deadline, cycles + 1)
    )
  end

  defp slow_consume(count) do
    receive do
      {:work, _, data} ->
        Enum.sum(data)
        Process.sleep(100)
        slow_consume(count + 1)
    after
      5000 -> count
    end
  end

  # ============================================================
  # PORT CHURN
  # ============================================================
  defp port_churn(seconds) do
    deadline = deadline(seconds)
    port_churn_loop(deadline, 0)
  end

  defp port_churn_loop(deadline, cycles) do
    if past?(deadline), do: {:port_churn, cycles},
    else: (
      ports = for _ <- 1..Enum.random([20, 40, 60]) do
        try do Port.open({:spawn, "cat"}, [:binary]) rescue _ -> nil end
      end |> Enum.filter(& &1)

      Enum.each(ports, fn port ->
        try do
          Enum.each(1..20, fn _ ->
            Port.command(port, :crypto.strong_rand_bytes(Enum.random([4_096, 16_384, 65_536])))
          end)
        rescue _ -> :ok
        end
      end)

      Process.sleep(Enum.random([50, 100]))
      Enum.each(ports, fn port -> try do Port.close(port) rescue _ -> :ok end end)

      port_churn_loop(deadline, cycles + 1)
    )
  end

  # ============================================================
  # ATOM GROWTH
  # ============================================================
  defp atom_growth(seconds) do
    deadline = deadline(seconds)
    atom_loop(deadline, 0)
  end

  defp atom_loop(deadline, cycles) do
    if past?(deadline), do: {:atom_growth, cycles},
    else: (
      Enum.each(1..Enum.random([500, 1_000]), fn _ ->
        String.to_atom("stress_#{:erlang.unique_integer([:positive])}")
      end)
      Process.sleep(Enum.random([10, 30]))
      atom_loop(deadline, cycles + 1)
    )
  end

  # ============================================================
  # HELPERS
  # ============================================================
  defp deadline(seconds), do: System.monotonic_time(:second) + seconds
  defp past?(deadline), do: System.monotonic_time(:second) >= deadline
end
