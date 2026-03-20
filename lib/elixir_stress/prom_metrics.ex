defmodule ElixirStress.PromMetrics do
  @moduledoc false

  use Supervisor

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {TelemetryMetricsPrometheus.Core, metrics: prom_metrics(), name: :elixir_stress_prom},
      {:telemetry_poller, measurements: measurements(), period: 5_000, name: :prom_poller}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def prom_metrics do
    import Telemetry.Metrics

    [
      # =============================================
      # VM Metrics
      # =============================================
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.memory.processes", unit: :byte),
      last_value("vm.memory.binary", unit: :byte),
      last_value("vm.memory.ets", unit: :byte),
      last_value("vm.memory.atom", unit: :byte),
      last_value("vm.memory.system", unit: :byte),

      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      last_value("vm.system_counts.process_count"),
      last_value("vm.system_counts.atom_count"),
      last_value("vm.system_counts.port_count"),

      # =============================================
      # Worker Lifecycle (existing)
      # =============================================
      counter("elixir_stress.worker.start.count", tags: [:worker]),
      counter("elixir_stress.worker.stop.count", tags: [:worker]),
      counter("elixir_stress.worker.cycle.count", tags: [:worker]),
      sum("elixir_stress.worker.cycle.value", tags: [:worker]),

      counter("elixir_stress.run.start.count"),
      counter("elixir_stress.run.stop.count"),
      distribution("elixir_stress.run.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [100, 500, 1000, 5000, 15000, 30000, 60000, 120_000]]
      ),
      distribution("plug.cowboy.request.stop.duration",
        unit: {:native, :millisecond},
        reporter_options: [buckets: [1, 5, 10, 50, 100, 500, 1000]]
      ),

      # =============================================
      # Application Metrics — Cycle Duration (histogram-like via summary)
      # Template: "How long does each operation take?"
      # =============================================
      distribution("elixir_stress.app.cycle_duration.duration",
        tags: [:worker],
        unit: :microsecond,
        description: "Duration of each worker cycle in microseconds",
        reporter_options: [buckets: [1000, 5000, 10_000, 50_000, 100_000, 500_000, 1_000_000, 5_000_000, 10_000_000]]
      ),

      # =============================================
      # Application Metrics — Memory Operations
      # Template: "How much is being allocated/released?"
      # =============================================
      sum("elixir_stress.app.memory.allocated.bytes",
        tags: [:worker],
        description: "Total bytes allocated"
      ),
      counter("elixir_stress.app.memory.allocated.count",
        tags: [:worker],
        description: "Number of allocation events"
      ),
      sum("elixir_stress.app.memory.released.bytes",
        tags: [:worker],
        description: "Total bytes released"
      ),
      counter("elixir_stress.app.memory.released.count",
        tags: [:worker],
        description: "Number of release events"
      ),
      last_value("elixir_stress.app.memory.held.bytes",
        tags: [:worker],
        description: "Currently held bytes (gauge)"
      ),
      last_value("elixir_stress.app.memory.held.chunks",
        tags: [:worker],
        description: "Currently held chunk count (gauge)"
      ),

      # =============================================
      # Application Metrics — Disk I/O
      # Template: "How much data is moving through the system?"
      # =============================================
      sum("elixir_stress.app.disk.written.bytes",
        tags: [:worker],
        description: "Total bytes written to disk"
      ),
      counter("elixir_stress.app.disk.written.count",
        tags: [:worker],
        description: "Number of disk write operations"
      ),
      sum("elixir_stress.app.disk.read.bytes",
        tags: [:worker],
        description: "Total bytes read from disk"
      ),
      counter("elixir_stress.app.disk.read.count",
        tags: [:worker],
        description: "Number of disk read operations"
      ),

      # =============================================
      # Application Metrics — Process Churn
      # Template: "How much concurrency churn is happening?"
      # =============================================
      sum("elixir_stress.app.processes.spawned.count",
        tags: [:worker],
        description: "Total processes spawned"
      ),
      sum("elixir_stress.app.processes.killed.count",
        tags: [:worker],
        description: "Total processes killed"
      ),
      last_value("elixir_stress.app.processes.alive.count",
        tags: [:worker],
        description: "Currently alive stress processes (gauge)"
      ),

      # =============================================
      # Application Metrics — Messages
      # Template: "What is the throughput of the messaging system?"
      # =============================================
      sum("elixir_stress.app.messages.sent.count",
        tags: [:worker],
        description: "Total messages sent"
      ),

      # =============================================
      # Application Metrics — Ports
      # Template: "How many external resources are being churned?"
      # =============================================
      sum("elixir_stress.app.ports.opened.count",
        tags: [:worker],
        description: "Total ports opened"
      ),
      sum("elixir_stress.app.ports.closed.count",
        tags: [:worker],
        description: "Total ports closed"
      ),

      # =============================================
      # Application Metrics — Distributed Calls
      # Template: "How are downstream services performing?"
      # =============================================
      distribution("elixir_stress.app.distributed.call.duration",
        tags: [:endpoint, :status],
        unit: :millisecond,
        description: "Duration of distributed HTTP calls",
        reporter_options: [buckets: [10, 50, 100, 250, 500, 1000, 2500, 5000, 10_000]]
      ),
      counter("elixir_stress.app.distributed.call.count",
        tags: [:endpoint, :status],
        description: "Count of distributed calls by endpoint and status"
      ),
      counter("elixir_stress.app.distributed.error.count",
        tags: [:endpoint],
        description: "Count of distributed call errors"
      ),

      # =============================================
      # OTel Stress (Tier 4)
      # =============================================
      counter("elixir_stress.otel.metric_flood.count",
        tags: [:endpoint, :method],
        description: "Metric flood events"
      ),
      sum("elixir_stress.otel.metric_flood.value",
        tags: [:endpoint, :method],
        description: "Metric flood values"
      )
    ]
  end

  defp measurements do
    []
  end

  def scrape do
    TelemetryMetricsPrometheus.Core.scrape(:elixir_stress_prom)
  rescue
    _ -> ""
  end
end
