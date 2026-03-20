defmodule ElixirStress.Stress do
  @moduledoc false
  require OpenTelemetry.Tracer, as: Tracer
  alias ElixirStress.OtelLogger
  alias ElixirStress.OtelStress

  @tmp_dir "/tmp/elixir_stress"
  @worker_service "http://localhost:4003"

  def run(duration_seconds \\ 30) do
    Tracer.with_span "stress_test.run",
      attributes: %{
        duration_seconds: duration_seconds,
        schedulers: System.schedulers_online(),
        node: node() |> Atom.to_string()
      } do
      OtelLogger.info("Stress test starting", %{
        duration: duration_seconds,
        schedulers: System.schedulers_online()
      })

      start_time = System.monotonic_time()
      File.mkdir_p!(@tmp_dir)

      shared =
        :ets.new(:stress_shared, [
          :public,
          :set,
          :named_table,
          read_concurrency: true,
          write_concurrency: true
        ])

      run_ctx = OpenTelemetry.Ctx.get_current()

      workers =
        replicate(10, fn -> propagated_worker(run_ctx, :memory_hog, duration_seconds) end) ++
          replicate(System.schedulers_online() * 2, fn ->
            propagated_worker(run_ctx, :cpu_saturate, duration_seconds)
          end) ++
          replicate(4, fn -> propagated_worker(run_ctx, :disk_thrash, duration_seconds) end) ++
          replicate(2, fn ->
            propagated_worker(run_ctx, :process_explosion, duration_seconds)
          end) ++
          replicate(2, fn ->
            propagated_worker_with_arg(run_ctx, :ets_bloat, duration_seconds, shared)
          end) ++
          replicate(4, fn -> propagated_worker(run_ctx, :gc_torture, duration_seconds) end) ++
          replicate(4, fn -> propagated_worker(run_ctx, :binary_abuse, duration_seconds) end) ++
          replicate(2, fn ->
            propagated_worker(run_ctx, :message_queue_pressure, duration_seconds)
          end) ++
          replicate(2, fn -> propagated_worker(run_ctx, :port_churn, duration_seconds) end) ++
          [Task.async(fn -> propagated_worker(run_ctx, :atom_growth, duration_seconds) end)] ++
          # Tier 4: OTel stress workers
          replicate(2, fn -> propagated_otel_worker(run_ctx, :span_flood, duration_seconds) end) ++
          replicate(2, fn ->
            propagated_otel_worker(run_ctx, :high_cardinality, duration_seconds)
          end) ++
          [
            Task.async(fn ->
              propagated_otel_worker(run_ctx, :large_payloads, duration_seconds)
            end)
          ] ++
          [
            Task.async(fn -> propagated_otel_worker(run_ctx, :metric_flood, duration_seconds) end)
          ] ++
          [Task.async(fn -> propagated_otel_worker(run_ctx, :log_flood, duration_seconds) end)] ++
          # Tier 5: Distributed workers
          replicate(2, fn ->
            propagated_worker(run_ctx, :distributed_call, duration_seconds)
          end)

      results = Task.yield_many(workers, :timer.seconds(duration_seconds + 30))

      File.rm_rf!(@tmp_dir)
      try do :ets.delete(shared) rescue _ -> :ok end

      duration_ns = System.monotonic_time() - start_time
      duration_ms = System.convert_time_unit(duration_ns, :native, :millisecond)

      :telemetry.execute([:elixir_stress, :run, :stop], %{duration: duration_ns}, %{
        duration_seconds: duration_seconds
      })

      OtelLogger.info("Stress test complete", %{
        duration_seconds: duration_seconds,
        actual_duration_ms: duration_ms,
        worker_count: length(workers)
      })

      Tracer.set_attributes(%{
        actual_duration_ms: duration_ms,
        worker_count: length(workers)
      })

      Enum.map(results, fn {task, res} ->
        case res do
          {:ok, val} -> val
          nil -> Task.shutdown(task, :brutal_kill); :timeout
        end
      end)
    end
  end

  defp replicate(n, fun), do: for(_ <- 1..n, do: Task.async(fun))

  defp propagated_worker(ctx, worker_name, duration_seconds) do
    OpenTelemetry.Ctx.attach(ctx)

    Tracer.with_span "stress.worker.#{worker_name}",
      attributes: %{worker: Atom.to_string(worker_name)} do
      :telemetry.execute([:elixir_stress, :worker, :start], %{count: 1}, %{
        worker: Atom.to_string(worker_name)
      })

      OtelLogger.info("Worker started: #{worker_name}", %{worker: Atom.to_string(worker_name)})

      result =
        try do
          apply(__MODULE__, :"do_#{worker_name}", [duration_seconds])
        rescue
          e ->
            OpenTelemetry.Span.record_exception(
              Tracer.current_span_ctx(),
              e,
              __STACKTRACE__
            )

            Tracer.set_status(:error, Exception.message(e))

            OtelLogger.error("Worker #{worker_name} crashed: #{Exception.message(e)}", %{
              worker: Atom.to_string(worker_name),
              error: Exception.message(e)
            })

            {:error, worker_name, Exception.message(e)}
        end

      :telemetry.execute([:elixir_stress, :worker, :stop], %{count: 1}, %{
        worker: Atom.to_string(worker_name)
      })

      OtelLogger.info("Worker stopped: #{worker_name}", %{worker: Atom.to_string(worker_name)})
      result
    end
  end

  defp propagated_worker_with_arg(ctx, worker_name, duration_seconds, arg) do
    OpenTelemetry.Ctx.attach(ctx)

    Tracer.with_span "stress.worker.#{worker_name}",
      attributes: %{worker: Atom.to_string(worker_name)} do
      :telemetry.execute([:elixir_stress, :worker, :start], %{count: 1}, %{
        worker: Atom.to_string(worker_name)
      })

      OtelLogger.info("Worker started: #{worker_name}", %{worker: Atom.to_string(worker_name)})

      result =
        try do
          apply(__MODULE__, :"do_#{worker_name}", [duration_seconds, arg])
        rescue
          e ->
            OpenTelemetry.Span.record_exception(
              Tracer.current_span_ctx(),
              e,
              __STACKTRACE__
            )

            Tracer.set_status(:error, Exception.message(e))

            OtelLogger.error("Worker #{worker_name} crashed: #{Exception.message(e)}", %{
              worker: Atom.to_string(worker_name)
            })

            {:error, worker_name, Exception.message(e)}
        end

      :telemetry.execute([:elixir_stress, :worker, :stop], %{count: 1}, %{
        worker: Atom.to_string(worker_name)
      })

      result
    end
  end

  defp propagated_otel_worker(ctx, worker_name, duration_seconds) do
    OpenTelemetry.Ctx.attach(ctx)

    :telemetry.execute([:elixir_stress, :worker, :start], %{count: 1}, %{
      worker: Atom.to_string(worker_name)
    })

    result =
      try do
        apply(OtelStress, worker_name, [duration_seconds])
      rescue
        e ->
          OtelLogger.error("OTel worker #{worker_name} crashed: #{Exception.message(e)}", %{
            worker: Atom.to_string(worker_name)
          })

          {:error, worker_name, Exception.message(e)}
      end

    :telemetry.execute([:elixir_stress, :worker, :stop], %{count: 1}, %{
      worker: Atom.to_string(worker_name)
    })

    result
  end

  defp emit_cycle(worker_name) do
    :telemetry.execute([:elixir_stress, :worker, :cycle], %{count: 1, value: 1}, %{
      worker: Atom.to_string(worker_name)
    })
  end

  defp emit_app(event, measurements, metadata) do
    :telemetry.execute([:elixir_stress, :app | event], measurements, metadata)
  end

  defp timed_cycle(worker_name, fun) do
    start = System.monotonic_time(:microsecond)
    result = fun.()
    duration_us = System.monotonic_time(:microsecond) - start
    emit_app([:cycle_duration], %{duration: duration_us}, %{worker: Atom.to_string(worker_name)})
    result
  end

  # ============================================================
  # MEMORY HOG
  # ============================================================
  def do_memory_hog(seconds) do
    deadline = deadline(seconds)
    memory_hog_loop(deadline, [], 0)
  end

  defp memory_hog_loop(deadline, held, cycles) do
    if past?(deadline) do
      held_mb = div(:erlang.external_size(held), 1_048_576)
      Tracer.set_attributes(%{total_cycles: cycles, final_held_mb: held_mb})
      {:memory_hog, cycles: cycles, held_mb: held_mb}
    else
      held = timed_cycle(:memory_hog, fn ->
        Tracer.with_span "memory_hog.cycle",
          attributes: %{cycle: cycles, chunks_held: length(held)} do
          alloc_count = Enum.random([5, 10, 20])

          new_chunks =
            for _ <- 1..alloc_count do
              case Enum.random(1..4) do
                1 ->
                  Tracer.add_event("allocate_list", %{elements: 2_000_000})
                  Enum.to_list(1..Enum.random([500_000, 1_000_000, 2_000_000]))

                2 ->
                  size = Enum.random([1_048_576, 2_097_152, 4_194_304])
                  Tracer.add_event("allocate_binary", %{bytes: size})
                  :crypto.strong_rand_bytes(size)

                3 ->
                  keys = Enum.random([100_000, 500_000])
                  Tracer.add_event("allocate_map", %{keys: keys})
                  Map.new(1..keys, fn i -> {i, :crypto.strong_rand_bytes(32)} end)

                4 ->
                  depth = Enum.random([10, 15, 20])
                  Tracer.add_event("allocate_nested", %{depth: depth})
                  build_nested(depth)
              end
            end

          alloc_bytes = Enum.reduce(new_chunks, 0, fn chunk, acc -> acc + :erlang.external_size(chunk) end)
          emit_app([:memory, :allocated], %{bytes: alloc_bytes, chunks: alloc_count}, %{worker: "memory_hog"})

          held = new_chunks ++ held
          Enum.each(held, fn chunk -> :erlang.phash2(chunk) end)

          {held, released_bytes} =
            if length(held) > Enum.random([30, 50, 80]) do
              drop = Enum.random([div(length(held), 4), div(length(held), 3)])
              {dropped, kept} = Enum.split(held, drop)
              released = Enum.reduce(dropped, 0, fn chunk, acc -> acc + :erlang.external_size(chunk) end)
              Tracer.add_event("memory_drop", %{dropping: drop, keeping: length(kept)})
              {kept, released}
            else
              {held, 0}
            end

          if released_bytes > 0 do
            emit_app([:memory, :released], %{bytes: released_bytes}, %{worker: "memory_hog"})
          end

          held_bytes = Enum.reduce(held, 0, fn chunk, acc -> acc + :erlang.external_size(chunk) end)
          emit_app([:memory, :held], %{bytes: held_bytes, chunks: length(held)}, %{worker: "memory_hog"})

          Tracer.set_attributes(%{held_chunks: length(held), allocations: alloc_count})
          held
        end
      end)

      emit_cycle(:memory_hog)

      if rem(cycles, 5) == 0 do
        held_mb = div(:erlang.external_size(held), 1_048_576)
        OtelLogger.info("memory_hog: cycle #{cycles}, holding #{held_mb}MB", %{
          worker: "memory_hog", cycle: cycles, held_mb: held_mb
        })
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
  # CPU SATURATE
  # ============================================================
  def do_cpu_saturate(seconds) do
    deadline = deadline(seconds)
    cpu_saturate_loop(deadline, 0)
  end

  defp cpu_saturate_loop(deadline, cycles) do
    if past?(deadline) do
      Tracer.set_attributes(%{total_cycles: cycles})
      {:cpu_saturate, cycles}
    else
      timed_cycle(:cpu_saturate, fn ->
      Tracer.with_span "cpu_saturate.cycle", attributes: %{cycle: cycles} do
        algo = Enum.random(1..6)

        algo_name =
          case algo do
            1 -> "fibonacci"
            2 -> "sort_and_chunk"
            3 -> "sha256_chain"
            4 -> "matrix_multiply"
            5 -> "ackermann"
            6 -> "permutations"
          end

        Tracer.set_attributes(%{algorithm: algo_name})
        Tracer.add_event("computation_start", %{algorithm: algo_name})

        case algo do
          1 ->
            n = Enum.random([35, 36, 37, 38])
            fib(n)

          2 ->
            data = for(_ <- 1..5_000_000, do: :rand.uniform(100_000_000))

            Enum.sort(data)
            |> Enum.chunk_every(1000)
            |> Enum.map(&Enum.sum/1)

          3 ->
            blob = :crypto.strong_rand_bytes(4_194_304)
            Enum.reduce(1..1_000, blob, fn _, acc -> :crypto.hash(:sha256, acc) end)

          4 ->
            size = 300
            a = for(_ <- 1..size, do: for(_ <- 1..size, do: :rand.uniform(1000)))
            b = for(_ <- 1..size, do: for(_ <- 1..size, do: :rand.uniform(1000)))
            bt = Enum.zip_with(b, &Function.identity/1)

            for row <- a do
              for col <- bt do
                Enum.zip_with(row, col, &Kernel.*/2) |> Enum.sum()
              end
            end

          5 ->
            ackermann(3, Enum.random([10, 11, 12]))

          6 ->
            permutations(Enum.to_list(1..Enum.random([9, 10])))
            |> Enum.take(100_000)
            |> Enum.map(&Enum.sum/1)
        end

        Tracer.add_event("computation_complete", %{algorithm: algo_name})
      end
      end)

      emit_cycle(:cpu_saturate)
      cpu_saturate_loop(deadline, cycles + 1)
    end
  end

  defp fib(0), do: 0
  defp fib(1), do: 1
  defp fib(n), do: fib(n - 1) + fib(n - 2)

  defp ackermann(0, n), do: n + 1
  defp ackermann(m, 0), do: ackermann(m - 1, 1)
  defp ackermann(m, n), do: ackermann(m - 1, ackermann(m, n - 1))

  defp permutations([]), do: [[]]
  defp permutations(list), do: for(elem <- list, rest <- permutations(list -- [elem]), do: [elem | rest])

  # ============================================================
  # DISK THRASH
  # ============================================================
  def do_disk_thrash(seconds) do
    deadline = deadline(seconds)
    disk_thrash_loop(deadline, 0)
  end

  defp disk_thrash_loop(deadline, cycles) do
    if past?(deadline) do
      Tracer.set_attributes(%{total_cycles: cycles})
      {:disk_thrash, cycles}
    else
      timed_cycle(:disk_thrash, fn ->
        Tracer.with_span "disk_thrash.cycle", attributes: %{cycle: cycles} do
          path = Path.join(@tmp_dir, "thrash_#{:erlang.unique_integer([:positive])}.bin")
          count = Enum.random([20, 50, 100])
          bytes_written = count * 1_048_576

          Tracer.with_span "disk.write", attributes: %{path: path, bytes: bytes_written} do
            f = File.open!(path, [:write, :raw])
            chunk = :crypto.strong_rand_bytes(1_048_576)
            Enum.each(1..count, fn _ -> IO.binwrite(f, chunk) end)
            File.close(f)
            Tracer.add_event("file_written", %{chunks: count, total_bytes: bytes_written})
          end

          emit_app([:disk, :written], %{bytes: bytes_written}, %{worker: "disk_thrash"})

          Tracer.with_span "disk.read_and_hash" do
            case File.read(path) do
              {:ok, data} ->
                bytes_read = byte_size(data)
                emit_app([:disk, :read], %{bytes: bytes_read}, %{worker: "disk_thrash"})

                hash =
                  :crypto.hash(:sha256, data) |> Base.encode16(case: :lower) |> binary_part(0, 16)

                Tracer.add_event("file_read_and_hashed", %{bytes: bytes_read, hash_prefix: hash})

                modified =
                  :crypto.hash(:sha512, data) |> String.duplicate(div(byte_size(data), 64))

                File.write!(path, modified)

              _ ->
                Tracer.add_event("file_read_failed", %{path: path})
            end
          end

          File.rm(path)
          Tracer.add_event("file_deleted", %{path: path})
        end
      end)

      emit_cycle(:disk_thrash)
      disk_thrash_loop(deadline, cycles + 1)
    end
  end

  # ============================================================
  # PROCESS EXPLOSION
  # ============================================================
  def do_process_explosion(seconds) do
    deadline = deadline(seconds)
    explosion_loop(deadline, [], 0)
  end

  defp explosion_loop(deadline, alive, cycles) do
    if past?(deadline) do
      Enum.each(alive, fn pid -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      Tracer.set_attributes(%{total_cycles: cycles})
      {:process_explosion, cycles}
    else
      {alive, _killed} = timed_cycle(:process_explosion, fn ->
        Tracer.with_span "process_explosion.cycle",
          attributes: %{cycle: cycles, alive_before: length(alive)} do
          batch_size = Enum.random([2_000, 5_000, 10_000])

          batch =
            for _ <- 1..batch_size do
              spawn(fn ->
                data = Enum.to_list(1..Enum.random([1_000, 5_000, 10_000]))
                Enum.reduce(data, 0, fn x, acc -> acc + x * x end)
                receive do :die -> :ok after Enum.random([1_000, 3_000, 5_000]) -> :ok end
              end)
            end

          emit_app([:processes, :spawned], %{count: batch_size}, %{worker: "process_explosion"})
          Tracer.add_event("processes_spawned", %{count: batch_size})

          alive = (batch ++ alive) |> Enum.filter(&Process.alive?/1)

          if length(alive) > 20_000 do
            {to_kill, to_keep} = Enum.split(alive, 10_000)
            Enum.each(to_kill, fn pid -> Process.exit(pid, :kill) end)
            emit_app([:processes, :killed], %{count: 10_000}, %{worker: "process_explosion"})
            Tracer.add_event("processes_culled", %{killed: 10_000, remaining: length(to_keep)})
            {to_keep, 10_000}
          else
            Tracer.set_attributes(%{alive_after: length(alive)})
            {alive, 0}
          end
        end
      end)

      emit_app([:processes, :alive], %{count: length(alive)}, %{worker: "process_explosion"})
      emit_cycle(:process_explosion)
      explosion_loop(deadline, alive, cycles + 1)
    end
  end

  # ============================================================
  # ETS BLOAT
  # ============================================================
  def do_ets_bloat(seconds, shared) do
    deadline = deadline(seconds)

    tables =
      for _ <- 1..5 do
        :ets.new(:bloat, [Enum.random([:set, :ordered_set, :bag]), :public])
      end

    ets_bloat_loop(deadline, [shared | tables], 0)
  end

  defp ets_bloat_loop(deadline, tables, cycles) do
    if past?(deadline) do
      tl(tables)
      |> Enum.each(fn t -> try do :ets.delete(t) rescue _ -> :ok end end)

      Tracer.set_attributes(%{total_cycles: cycles})
      {:ets_bloat, cycles}
    else
      t = Enum.random(tables)
      op = Enum.random(1..5)

      op_name =
        case op do
          1 -> "bulk_insert"
          2 -> "full_scan"
          3 -> "select_all"
          4 -> "clear_and_refill"
          5 -> "concurrent_write"
        end

      Tracer.with_span "ets_bloat.cycle",
        attributes: %{cycle: cycles, operation: op_name} do
        case op do
          1 ->
            Enum.each(1..50_000, fn i ->
              :ets.insert(t, {
                {:rand.uniform(1_000_000), i},
                :crypto.strong_rand_bytes(Enum.random([256, 512, 1024])),
                Enum.to_list(1..Enum.random([50, 100]))
              })
            end)

            Tracer.add_event("rows_inserted", %{count: 50_000})

          2 ->
            total = :ets.foldl(fn row, acc -> :erlang.phash2(row) + acc end, 0, t)
            Tracer.add_event("table_scanned", %{hash_total: total})

          3 ->
            count = length(:ets.select(t, [{:_, [], [true]}]))
            Tracer.add_event("select_complete", %{rows_matched: count})

          4 ->
            :ets.delete_all_objects(t)

            Enum.each(1..20_000, fn i ->
              :ets.insert(t, {i, :crypto.strong_rand_bytes(512)})
            end)

            Tracer.add_event("table_cleared_and_refilled", %{new_rows: 20_000})

          5 ->
            Enum.each(1..10_000, fn _ ->
              key = :rand.uniform(10_000)
              :ets.insert(t, {key, :crypto.strong_rand_bytes(256), System.monotonic_time()})
            end)

            Tracer.add_event("concurrent_writes", %{count: 10_000})
        end
      end

      emit_cycle(:ets_bloat)
      ets_bloat_loop(deadline, tables, cycles + 1)
    end
  end

  # ============================================================
  # GC TORTURE
  # ============================================================
  def do_gc_torture(seconds) do
    deadline = deadline(seconds)
    gc_torture_loop(deadline, 0)
  end

  defp gc_torture_loop(deadline, cycles) do
    if past?(deadline) do
      Tracer.set_attributes(%{total_cycles: cycles})
      {:gc_torture, cycles}
    else
      Tracer.with_span "gc_torture.cycle", attributes: %{cycle: cycles} do
        Tracer.with_span "gc.allocate_garbage" do
          _garbage =
            for _ <- 1..100 do
              case Enum.random(1..4) do
                1 -> Enum.to_list(1..1_000_000)
                2 -> :crypto.strong_rand_bytes(4_194_304)
                3 -> Map.new(1..100_000, fn i -> {i, make_ref()} end)
                4 -> String.duplicate("garbage!", 500_000)
              end
            end

          Tracer.add_event("garbage_allocated", %{chunks: 100})
        end

        :erlang.garbage_collect()
        Tracer.add_event("gc_forced", %{phase: 1})

        Tracer.with_span "gc.more_garbage" do
          _more = for(_ <- 1..50, do: Enum.to_list(1..500_000))
          Tracer.add_event("more_garbage_allocated", %{lists: 50})
        end

        :erlang.garbage_collect()
        Tracer.add_event("gc_forced", %{phase: 2})

        Tracer.with_span "gc.sub_processes" do
          pids =
            for _ <- 1..50 do
              spawn(fn ->
                _junk =
                  for _ <- 1..20 do
                    :crypto.strong_rand_bytes(Enum.random([1_048_576, 2_097_152]))
                  end

                :erlang.garbage_collect()
              end)
            end

          Enum.each(pids, fn pid ->
            ref = Process.monitor(pid)
            receive do {:DOWN, ^ref, _, _, _} -> :ok after 2000 -> :ok end
          end)

          Tracer.add_event("sub_processes_complete", %{count: 50})
        end
      end

      emit_cycle(:gc_torture)
      gc_torture_loop(deadline, cycles + 1)
    end
  end

  # ============================================================
  # BINARY ABUSE
  # ============================================================
  def do_binary_abuse(seconds) do
    deadline = deadline(seconds)
    binary_abuse_loop(deadline, [], 0)
  end

  defp binary_abuse_loop(deadline, held, cycles) do
    if past?(deadline) do
      Tracer.set_attributes(%{total_cycles: cycles, final_held: length(held)})
      {:binary_abuse, cycles}
    else
      Tracer.with_span "binary_abuse.cycle",
        attributes: %{cycle: cycles, held_before: length(held)} do
        new_count = Enum.random([10, 20, 30])

        new_bins =
          for _ <- 1..new_count do
            size = Enum.random([2_097_152, 4_194_304, 8_388_608])
            big = :crypto.strong_rand_bytes(size)

            subs =
              for i <- 0..9 do
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

        Tracer.add_event("binaries_allocated", %{
          count: new_count,
          total_bytes: Enum.sum(Enum.map(new_bins, &byte_size/1))
        })

        held = new_bins ++ held

        held =
          if length(held) > 50 do
            Tracer.add_event("binaries_trimmed", %{from: length(held), to: 30})
            Enum.take(held, 30)
          else
            held
          end

        Enum.each(held, fn b -> :erlang.phash2(b) end)
        Tracer.set_attributes(%{held_after: length(held)})
      end

      emit_cycle(:binary_abuse)
      binary_abuse_loop(deadline, held, cycles + 1)
    end
  end

  # ============================================================
  # MESSAGE QUEUE PRESSURE
  # ============================================================
  def do_message_queue_pressure(seconds) do
    deadline = deadline(seconds)
    msg_pressure_loop(deadline, 0)
  end

  defp msg_pressure_loop(deadline, cycles) do
    if past?(deadline) do
      Tracer.set_attributes(%{total_cycles: cycles})
      {:message_queue_pressure, cycles}
    else
      timed_cycle(:message_queue_pressure, fn ->
        target_count = Enum.random([10, 20, 30])

        Tracer.with_span "message_queue.cycle",
          attributes: %{cycle: cycles, targets: target_count} do
          targets = for(_ <- 1..target_count, do: spawn(fn -> slow_consume(0) end))

          Tracer.add_event("consumers_spawned", %{count: target_count})

          total_messages = target_count * 10_000
          Enum.each(targets, fn target ->
            spawn(fn ->
              Enum.each(1..10_000, fn i ->
                if Process.alive?(target) do
                  send(target, {:work, i, Enum.to_list(1..Enum.random([100, 500, 1000]))})
                end
              end)
            end)
          end)

          emit_app([:messages, :sent], %{count: total_messages}, %{worker: "message_queue_pressure"})
          Tracer.add_event("messages_sent", %{per_target: 10_000, total: total_messages})

          Process.sleep(Enum.random([500, 1_000, 2_000]))

          Enum.each(targets, fn pid ->
            if Process.alive?(pid), do: Process.exit(pid, :kill)
          end)

          Tracer.add_event("consumers_killed", %{count: target_count})
        end
      end)

      emit_cycle(:message_queue_pressure)
      msg_pressure_loop(deadline, cycles + 1)
    end
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
  def do_port_churn(seconds) do
    deadline = deadline(seconds)
    port_churn_loop(deadline, 0)
  end

  defp port_churn_loop(deadline, cycles) do
    if past?(deadline) do
      Tracer.set_attributes(%{total_cycles: cycles})
      {:port_churn, cycles}
    else
      port_count = Enum.random([20, 40, 60])

      timed_cycle(:port_churn, fn ->
      Tracer.with_span "port_churn.cycle",
        attributes: %{cycle: cycles, target_ports: port_count} do
        Tracer.with_span "ports.open" do
          ports =
            for _ <- 1..port_count do
              try do
                Port.open({:spawn, "cat"}, [:binary])
              rescue
                _ -> nil
              end
            end
            |> Enum.filter(& &1)

          Tracer.add_event("ports_opened", %{count: length(ports)})

          Tracer.with_span "ports.pump_data" do
            total_bytes =
              Enum.reduce(ports, 0, fn port, acc ->
                try do
                  bytes =
                    Enum.reduce(1..20, 0, fn _, b_acc ->
                      size = Enum.random([4_096, 16_384, 65_536])
                      Port.command(port, :crypto.strong_rand_bytes(size))
                      b_acc + size
                    end)

                  acc + bytes
                rescue
                  _ -> acc
                end
              end)

            Tracer.add_event("data_pumped", %{total_bytes: total_bytes})
          end

          Process.sleep(Enum.random([50, 100]))

          Enum.each(ports, fn port ->
            try do Port.close(port) rescue _ -> :ok end
          end)

          emit_app([:ports, :opened], %{count: length(ports)}, %{worker: "port_churn"})
          emit_app([:ports, :closed], %{count: length(ports)}, %{worker: "port_churn"})
          Tracer.add_event("ports_closed", %{count: length(ports)})
        end
      end
      end)

      emit_cycle(:port_churn)
      port_churn_loop(deadline, cycles + 1)
    end
  end

  # ============================================================
  # ATOM GROWTH
  # ============================================================
  def do_atom_growth(seconds) do
    deadline = deadline(seconds)
    atom_loop(deadline, 0, 0)
  end

  defp atom_loop(deadline, cycles, total_atoms) do
    if past?(deadline) do
      Tracer.set_attributes(%{total_cycles: cycles, total_atoms_created: total_atoms})
      {:atom_growth, cycles}
    else
      batch = Enum.random([500, 1_000])

      Tracer.with_span "atom_growth.cycle", attributes: %{cycle: cycles, batch_size: batch} do
        Enum.each(1..batch, fn _ ->
          String.to_atom("stress_#{:erlang.unique_integer([:positive])}")
        end)

        current = :erlang.system_info(:atom_count)
        Tracer.add_event("atoms_created", %{batch: batch, total_system_atoms: current})
        Tracer.set_attributes(%{system_atom_count: current})
      end

      Process.sleep(Enum.random([10, 30]))
      emit_cycle(:atom_growth)

      if rem(cycles, 20) == 0 do
        OtelLogger.warning("Atom growth: #{:erlang.system_info(:atom_count)} atoms in system", %{
          worker: "atom_growth",
          atom_count: :erlang.system_info(:atom_count)
        })
      end

      atom_loop(deadline, cycles + 1, total_atoms + batch)
    end
  end

  # ============================================================
  # DISTRIBUTED CALL (Tier 5)
  # ============================================================
  def do_distributed_call(seconds) do
    deadline = deadline(seconds)
    distributed_loop(deadline, 0, 0, 0)
  end

  defp distributed_loop(deadline, cycles, successes, failures) do
    if past?(deadline) do
      Tracer.set_attributes(%{
        total_cycles: cycles,
        total_successes: successes,
        total_failures: failures
      })

      OtelLogger.info("Distributed calls complete", %{
        worker: "distributed_call",
        cycles: cycles,
        successes: successes,
        failures: failures
      })

      {:distributed_call, cycles: cycles, successes: successes, failures: failures}
    else
      Tracer.with_span "distributed_call.cycle", attributes: %{cycle: cycles} do
        {s, f} = make_distributed_calls()
        Tracer.set_attributes(%{cycle_successes: s, cycle_failures: f})

        emit_cycle(:distributed_call)
        distributed_loop(deadline, cycles + 1, successes + s, failures + f)
      end
    end
  end

  defp make_distributed_calls do
    calls = [
      {"compute", %{"intensity" => Enum.random([20, 25, 30])}},
      {"store", %{"rows" => Enum.random([5_000, 10_000, 20_000])}},
      {"transform", %{"size" => Enum.random([25_000, 50_000])}}
    ]

    results =
      Enum.map(calls, fn {endpoint, body} ->
        Tracer.with_span "distributed.http_call",
          attributes: %{
            "http.method": "POST",
            "http.url": "#{@worker_service}/work/#{endpoint}",
            "peer.service": "worker_service"
          } do
          headers = inject_trace_context()

          OtelLogger.debug("Calling worker service: #{endpoint}", %{
            worker: "distributed_call",
            endpoint: endpoint
          })

          start = System.monotonic_time(:millisecond)

          result =
            try do
              resp =
                Req.post!("#{@worker_service}/work/#{endpoint}",
                  json: body,
                  headers: headers,
                  receive_timeout: 30_000
                )

              duration = System.monotonic_time(:millisecond) - start
              Tracer.set_attributes(%{"http.status_code": resp.status, duration_ms: duration})
              Tracer.add_event("response_received", %{status: resp.status, duration_ms: duration})

              emit_app([:distributed, :call], %{duration: duration}, %{endpoint: endpoint, status: "success"})

              if resp.status in 200..299, do: :ok, else: :error
            rescue
              e ->
                duration = System.monotonic_time(:millisecond) - start

                emit_app([:distributed, :call], %{duration: duration}, %{endpoint: endpoint, status: "error"})
                emit_app([:distributed, :error], %{count: 1}, %{endpoint: endpoint})

                OpenTelemetry.Span.record_exception(
                  Tracer.current_span_ctx(),
                  e,
                  __STACKTRACE__
                )

                Tracer.set_status(:error, Exception.message(e))

                OtelLogger.error("Distributed call failed: #{endpoint} - #{Exception.message(e)}",
                  %{worker: "distributed_call", endpoint: endpoint, duration_ms: duration}
                )

                :error
            end

          result
        end
      end)

    successes = Enum.count(results, &(&1 == :ok))
    failures = Enum.count(results, &(&1 == :error))
    {successes, failures}
  end

  defp inject_trace_context do
    carrier = :otel_propagator_text_map.inject([])
    Enum.map(carrier, fn {k, v} -> {to_string(k), to_string(v)} end)
  end

  # ============================================================
  # HELPERS
  # ============================================================
  defp deadline(seconds), do: System.monotonic_time(:second) + seconds
  defp past?(deadline), do: System.monotonic_time(:second) >= deadline
end
