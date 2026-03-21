#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Elixir Stress Test — Full Setup Script
# ============================================================
# Installs all prerequisites and starts the complete stack:
#   - Homebrew (if missing)
#   - Elixir + Erlang (via Homebrew)
#   - Docker Desktop check
#   - Grafana LGTM stack (Docker)
#   - Elixir dependencies
#   - Application (ports 4001, 4002, 4003)
#
# Usage:
#   ./setup.sh           # Full install + start
#   ./setup.sh --start   # Skip install, just start services
#   ./setup.sh --stop    # Stop everything
#   ./setup.sh --status  # Check what's running
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}▸${NC} $1"; }
ok()    { echo -e "${GREEN}✓${NC} $1"; }
warn()  { echo -e "${YELLOW}!${NC} $1"; }
fail()  { echo -e "${RED}✗${NC} $1"; }

# ============================================================
# --stop: Kill everything
# ============================================================
if [[ "${1:-}" == "--stop" ]]; then
  info "Stopping Elixir app..."
  for port in 4001 4002 4003; do
    pids=$(lsof -ti:"$port" 2>/dev/null || true)
    if [[ -n "$pids" ]]; then
      echo "$pids" | xargs kill -9 2>/dev/null || true
      ok "Killed processes on port $port"
    fi
  done

  info "Stopping Docker containers..."
  docker compose down 2>/dev/null && ok "Docker containers stopped" || warn "No containers running"
  exit 0
fi

# ============================================================
# --status: Show what's running
# ============================================================
if [[ "${1:-}" == "--status" ]]; then
  echo ""
  echo "=== Services ==="
  for port in 4001 4002 4003; do
    if lsof -ti:"$port" &>/dev/null; then
      ok "Port $port — running"
    else
      fail "Port $port — not running"
    fi
  done

  echo ""
  echo "=== Docker ==="
  if docker compose ps 2>/dev/null | grep -q "running\|Up"; then
    docker compose ps 2>/dev/null
  else
    fail "LGTM container not running"
  fi

  echo ""
  echo "=== URLs ==="
  echo "  Web UI:          http://localhost:4001"
  echo "  LiveDashboard:   http://localhost:4002/dashboard"
  echo "  Grafana:         http://localhost:3404  (admin/admin)"
  echo "  Stress Dashboard: http://localhost:3404/d/elixir-stress-test"
  echo "  App Metrics:     http://localhost:3404/d/elixir-app-metrics"
  exit 0
fi

# ============================================================
# Header
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║       Elixir Stress Test — Setup             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

SKIP_INSTALL=false
if [[ "${1:-}" == "--start" ]]; then
  SKIP_INSTALL=true
fi

# ============================================================
# Step 1: Check / Install prerequisites
# ============================================================
if [[ "$SKIP_INSTALL" == false ]]; then
  info "Checking prerequisites..."
  echo ""

  # --- Homebrew ---
  if command -v brew &>/dev/null; then
    ok "Homebrew installed"
  else
    info "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    # Add to path for Apple Silicon
    if [[ -f /opt/homebrew/bin/brew ]]; then
      eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    ok "Homebrew installed"
  fi

  # --- Erlang ---
  if command -v erl &>/dev/null; then
    erl_version=$(erl -eval 'io:format("~s", [erlang:system_info(otp_release)]), halt().' -noshell 2>/dev/null || echo "unknown")
    ok "Erlang/OTP $erl_version installed"
  else
    info "Installing Erlang..."
    brew install erlang
    ok "Erlang installed"
  fi

  # --- Elixir ---
  if command -v elixir &>/dev/null; then
    elixir_version=$(elixir --version 2>/dev/null | grep "Elixir" | awk '{print $2}')
    ok "Elixir $elixir_version installed"
  else
    info "Installing Elixir..."
    brew install elixir
    ok "Elixir installed"
  fi

  # --- Docker ---
  if command -v docker &>/dev/null; then
    ok "Docker installed"
  else
    warn "Docker not found. Please install Docker Desktop from https://docker.com/products/docker-desktop"
    warn "Then re-run this script."
    exit 1
  fi

  echo ""
fi

# ============================================================
# Step 2: Check Docker is running
# ============================================================
info "Checking Docker daemon..."
if docker info &>/dev/null; then
  ok "Docker is running"
else
  fail "Docker daemon is not running"
  echo ""
  warn "Please start Docker Desktop and re-run this script."
  # Try to open Docker Desktop on macOS
  if [[ "$(uname)" == "Darwin" ]]; then
    info "Attempting to open Docker Desktop..."
    open -a Docker 2>/dev/null || true
    echo "  Waiting for Docker to start (up to 60s)..."
    for i in $(seq 1 60); do
      if docker info &>/dev/null; then
        ok "Docker is now running"
        break
      fi
      sleep 1
      printf "."
    done
    echo ""
    if ! docker info &>/dev/null; then
      fail "Docker did not start in time. Please start it manually and re-run."
      exit 1
    fi
  else
    exit 1
  fi
fi

# ============================================================
# Step 3: Handle TLS proxy (Zscaler)
# ============================================================
if [[ "$SKIP_INSTALL" == false ]]; then
  # Check if we might be behind a corporate proxy
  if security find-certificate -c "Zscaler" /Library/Keychains/System.keychain &>/dev/null 2>&1; then
    warn "Zscaler TLS proxy detected"
    if [[ ! -f /tmp/all_cas.pem ]]; then
      info "Exporting CA certificates..."
      security find-certificate -a -p /Library/Keychains/System.keychain \
        /System/Library/Keychains/SystemRootCertificates.keychain > /tmp/all_cas.pem
      ok "CA bundle written to /tmp/all_cas.pem"
    fi
    export HEX_CACERTS_PATH=/tmp/all_cas.pem
    ok "HEX_CACERTS_PATH set for mix deps.get"
  fi
fi

# ============================================================
# Step 4: Install Elixir dependencies
# ============================================================
if [[ "$SKIP_INSTALL" == false ]]; then
  echo ""
  info "Installing Elixir dependencies..."
  mix local.hex --force --if-missing >/dev/null 2>&1
  mix local.rebar --force --if-missing >/dev/null 2>&1
  mix deps.get
  ok "Dependencies installed"

  info "Compiling..."
  mix compile
  ok "Compilation complete"
  echo ""
fi

# ============================================================
# Step 5: Start Grafana LGTM stack
# ============================================================
info "Starting Grafana LGTM stack (Docker)..."
docker compose up -d
echo "  Waiting for Grafana to become healthy..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:3404/api/health &>/dev/null; then
    break
  fi
  sleep 1
  printf "."
done
echo ""

if curl -sf http://localhost:3404/api/health &>/dev/null; then
  ok "Grafana LGTM stack is healthy"
else
  fail "Grafana did not become healthy in 60s. Check: docker compose logs"
  exit 1
fi

# ============================================================
# Step 6: Kill any existing Elixir processes on our ports
# ============================================================
for port in 4001 4002 4003; do
  pids=$(lsof -ti:"$port" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    warn "Port $port already in use — killing existing processes"
    echo "$pids" | xargs kill -9 2>/dev/null || true
    sleep 1
  fi
done

# ============================================================
# Step 7: Start Elixir application
# ============================================================
echo ""
info "Starting Elixir application..."
mix run --no-halt > /tmp/elixir_stress.log 2>&1 &
APP_PID=$!
echo "  PID: $APP_PID (log: /tmp/elixir_stress.log)"

# Wait for app to be ready
for i in $(seq 1 30); do
  if curl -sf http://localhost:4001/ &>/dev/null; then
    break
  fi
  sleep 1
  printf "."
done
echo ""

if curl -sf http://localhost:4001/ &>/dev/null; then
  ok "Elixir app is running"
else
  fail "App did not start. Check /tmp/elixir_stress.log"
  exit 1
fi

# ============================================================
# Done
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║              All systems go!                 ║"
echo "╠══════════════════════════════════════════════╣"
echo "║                                              ║"
echo "║  Web UI        http://localhost:4001          ║"
echo "║  LiveDashboard http://localhost:4002/dashboard║"
echo "║  Grafana       http://localhost:3404          ║"
echo "║                (admin / admin)                ║"
echo "║                                              ║"
echo "║  Dashboards:                                  ║"
echo "║  ▸ /d/elixir-stress-test                     ║"
echo "║  ▸ /d/elixir-app-metrics                     ║"
echo "║                                              ║"
echo "║  Stop:  ./setup.sh --stop                    ║"
echo "║  Status: ./setup.sh --status                 ║"
echo "║                                              ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Open the web UI
if [[ "$(uname)" == "Darwin" ]]; then
  open http://localhost:4001
fi
