defmodule ElixirStress.Router do
  use Plug.Router

  plug Plug.Parsers, parsers: [:urlencoded]
  plug :match
  plug :dispatch

  get "/" do
    html = """
    <!DOCTYPE html>
    <html>
    <head><title>Elixir Stress</title></head>
    <body>
      <h1>Elixir Stress Test</h1>
      <form action="/stress" method="post">
        <label>Full stress test (memory, CPU, disk, processes, ETS, messages, atoms, ports, binaries):</label><br><br>
        <select name="duration">
          <option value="15">15 seconds</option>
          <option value="30" selected>30 seconds</option>
          <option value="60">60 seconds</option>
          <option value="120">2 minutes</option>
        </select>
        <button type="submit">Run Full Stress Test</button>
      </form>
      <br>
      <form action="/burn" method="post">
        <label>Quick CPU and memory spike:</label><br><br>
        <button type="submit">Run Busy Loop</button>
      </form>
      <br>
      <p><a href="http://localhost:4002/dashboard" target="_blank">Open Phoenix LiveDashboard</a></p>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  post "/stress" do
    duration = String.to_integer(conn.body_params["duration"] || "30")

    spawn(fn -> ElixirStress.Stress.run(duration) end)

    html = """
    <!DOCTYPE html>
    <html>
    <head><title>Stress Test Running</title></head>
    <body>
      <h1>Full Stress Test Started!</h1>
      <p>Running for #{duration} seconds with:</p>
      <ul>
        <li>10x Memory hogs (hold tens to hundreds of MB each)</li>
        <li>CPU saturate (2x schedulers — primes, sorting, hashing, fibonacci, matrix multiply)</li>
        <li>4x Disk I/O thrash (write/read/hash 20-100MB files)</li>
        <li>2x Process explosion (up to 20k live processes)</li>
        <li>2x ETS bloat (50k row inserts, full table scans)</li>
        <li>4x GC torture (massive garbage + forced collection)</li>
        <li>4x Binary heap abuse (2-8MB binaries shared across processes)</li>
        <li>2x Message queue pressure (10k messages flooding slow consumers)</li>
        <li>2x Port churn (open/pump/close 20-60 ports)</li>
        <li>Atom growth (500-1000 atoms per batch)</li>
      </ul>
      <p>Watch it live: <a href="http://localhost:4002/dashboard" target="_blank">Open Dashboard</a></p>
      <a href="/">Go back</a>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  post "/burn" do
    for _ <- 1..10 do
      spawn(fn ->
        list = Enum.to_list(1..500_000)
        Enum.each(1..20, fn _ -> Enum.sum(list) end)
      end)
    end

    html = """
    <!DOCTYPE html>
    <html>
    <head><title>Burning!</title></head>
    <body>
      <h1>Busy loop started!</h1>
      <p>Spawned 10 processes each crunching 500k element lists. Check the <a href="http://localhost:4002/dashboard" target="_blank">dashboard</a> to see the spike.</p>
      <a href="/">Go back</a>
    </body>
    </html>
    """

    conn
    |> put_resp_content_type("text/html")
    |> send_resp(200, html)
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end
end
