# Elixir Stress — Phoenix LiveDashboard Stress Test

A BEAM VM stress testing tool with Phoenix LiveDashboard for real-time observability. Exercises memory, CPU, disk, processes, ETS, message passing, ports, GC, and more — all visible through the dashboard.

## Prerequisites

- Elixir ~> 1.19
- Erlang/OTP

## Installation & Setup

```bash
cd elixir_stress
mix deps.get
mix compile
```

**Note:** If you're behind a corporate TLS proxy (e.g. Zscaler), you may need to export your system CA certificates for Hex to work:

```bash
security find-certificate -a -p /Library/Keychains/System.keychain \
  /System/Library/Keychains/SystemRootCertificates.keychain > /tmp/all_cas.pem

HEX_CACERTS_PATH=/tmp/all_cas.pem mix deps.get
```

## Running

```bash
mix run --no-halt
```

This starts two servers:

| Service | URL |
|---|---|
| Web app | http://localhost:4001 |
| Phoenix LiveDashboard | http://localhost:4002/dashboard |

## Web App

The web app on port 4001 provides:

- **GET /** — Control panel with stress test buttons
- **POST /stress** — Launches the full stress test (configurable duration: 15s, 30s, 60s, 2min)
- **POST /burn** — Quick CPU/memory spike (lighter than the full stress test)

## Phoenix LiveDashboard

The dashboard on port 4002 provides real-time observability into the BEAM VM:

- **Home** — Memory usage (total, processes, atoms, binary, ETS), run queue lengths, process/port/atom counts
- **OS Data** — System CPU, memory, and disk usage (requires `:os_mon`)
- **Metrics** — Custom telemetry metrics (VM memory, run queues, request duration)
- **Request Logger** — Live stream of HTTP requests
- **Processes** — All running processes with memory, reductions, and message queue length
- **Ports** — Open OS ports
- **ETS** — All ETS tables with row counts and memory usage
- **Memory Allocators** — Low-level BEAM memory allocator stats
- **Applications** — Supervision tree of running OTP applications

## Stress Test Details

The stress test (`ElixirStress.Stress`) launches ~40+ concurrent workers across all BEAM schedulers. Each worker runs for the selected duration, exercising a different subsystem.

### Memory (10 workers)

Each worker holds **tens to hundreds of MB** in its process heap with a sawtooth pattern — rapidly allocating then partially dropping data to create visible oscillation on the dashboard.

- Allocates giant lists (up to 2M elements), binaries (up to 4MB), maps (up to 500k keys), and deeply nested structures
- Touches all held data with `:erlang.phash2/1` to prevent optimization
- Periodically drops 25-33% of held data to create memory churn

### CPU (2x schedulers_online workers)

Saturates every scheduler with zero sleeps between cycles:

- **Naive Fibonacci** — fib(35-38), exponential time recursive calls
- **Sorting** — Sort/group/reduce 5M random integers
- **Crypto grinding** — 1,000 rounds of SHA-256 on 4MB blobs
- **Matrix multiply** — 300x300 matrix multiplication in pure Elixir
- **Ackermann function** — ackermann(3, 10-12), deeply recursive
- **Permutations** — Generate permutations of 9-10 element lists

### Disk I/O (4 workers)

- Write 20-100MB files in 1MB chunks, then read back with random seeks
- Read, hash, modify, and rewrite files
- Continuous create/write/delete cycle

### Process Explosion (2 workers)

- Spawns **2,000-10,000 processes per cycle**, each holding memory and doing computation
- Maintains up to 20,000 live processes simultaneously
- Creates churn by killing batches and spawning replacements

### ETS (2 workers)

- Creates multiple tables (set, ordered_set, bag) with varying options
- Inserts **50,000 rows per cycle** with binary/list values
- Full table scans, select queries, delete-and-refill operations
- Concurrent read/write to a shared named table

### GC Torture (4 workers)

- Allocates massive garbage (1M-element lists, 4MB binaries, 100k-key maps) then forces `:erlang.garbage_collect()`
- Spawns 50 sub-processes per cycle that each create garbage and GC
- Creates visible memory oscillation and GC pause pressure

### Binary Heap Abuse (4 workers)

- Creates 2-8MB binaries and holds references
- Creates sub-binary slices shared across spawned processes
- Stresses the reference-counted binary garbage collector

### Message Queue Pressure (2 workers)

- Spawns slow-consumer processes (one message per 100ms)
- Floods each with **10,000 messages** carrying list payloads
- Creates backed-up mailboxes visible in the Processes tab

### Port Churn (2 workers)

- Opens 20-60 OS ports (`cat`) simultaneously
- Pumps 4-64KB of data through each port
- Rapid open/data/close cycles

### Atom Growth (1 worker)

- Creates 500-1,000 unique atoms per batch
- Atoms are never garbage collected, so the atom count steadily climbs
- Visible on the Home tab atom gauge

## Project Structure

```
elixir_stress/
├── config/
│   └── config.exs              # Phoenix endpoint config (port 4002)
├── lib/
│   ├── elixir_stress.ex
│   └── elixir_stress/
│       ├── application.ex       # OTP application (starts Cowboy, Endpoint, Telemetry)
│       ├── router.ex            # Main web routes (port 4001)
│       ├── endpoint.ex          # Phoenix endpoint for dashboard (port 4002)
│       ├── dashboard_router.ex  # LiveDashboard route config
│       ├── telemetry.ex         # Telemetry metrics definitions
│       └── stress.ex            # Stress test suite
├── mix.exs
└── README.md
```
