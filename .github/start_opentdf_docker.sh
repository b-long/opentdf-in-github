#!/usr/bin/env bash

set -euo pipefail

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Change to the repository root to ensure relative paths work
cd "$REPO_ROOT"

# Parse command line arguments
AUTO_RESTART=false
STOP_ONLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --auto-restart)
      AUTO_RESTART=true
      shift
      ;;
    --stop)
      STOP_ONLY=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: $0 [--auto-restart|--stop]"
      exit 1
      ;;
  esac
done

echo "=== OpenTDF Platform Setup Script ==="
echo ""

TEMP_DIR="${TMPDIR:-/tmp}"
PID_FILE="${TEMP_DIR}/opentdf_platform.pid"
LOG_FILE="${TEMP_DIR}/opentdf_platform.log"
PLATFORM_PORT=8080

# Function to detect container runtime and compose command
# Sets global variables: CONTAINER_RUNTIME and COMPOSE_CMD
# Returns 1 and exits if no container runtime is found
detect_container_runtime() {
  CONTAINER_RUNTIME=""
  COMPOSE_CMD=""

  if command -v docker &> /dev/null; then
    CONTAINER_RUNTIME="docker"
    # Test if docker compose (plugin) or docker-compose (standalone) works
    if docker compose version &> /dev/null; then
      COMPOSE_CMD="docker compose"
    elif command -v docker-compose &> /dev/null; then
      COMPOSE_CMD="docker-compose"
    else
      echo "  ✗ No Docker Compose command found (tried 'docker compose' and 'docker-compose')."
      echo ""
      echo "ERROR: Docker is installed but Docker Compose is not available."
      echo "Please install Docker Compose and try again."
      exit 1
    fi
    echo "  ✓ Docker detected"
    echo "  ✓ Using: $COMPOSE_CMD"
  elif command -v podman &> /dev/null; then
    CONTAINER_RUNTIME="podman"
    # Test if podman compose (plugin) or podman-compose (standalone) works
    if podman compose version &> /dev/null; then
      COMPOSE_CMD="podman compose"
    elif command -v podman-compose &> /dev/null; then
      COMPOSE_CMD="podman-compose"
    else
      echo "  ✗ No Podman Compose command found (tried 'podman compose' and 'podman-compose')."
      echo ""
      echo "ERROR: Podman is installed but Podman Compose is not available."
      echo "Please install Podman Compose and try again."
      exit 1
    fi
    echo "  ✓ Podman detected"
    echo "  ✓ Using: $COMPOSE_CMD"
  else
    echo "  ✗ Neither Docker nor Podman found"
    echo ""
    echo "ERROR: No container runtime found. Please install Docker or Podman."
    exit 1
  fi
}

# Function to kill process bound to a specific port
# Works on macOS (lsof) and Linux
kill_port() {
  local port=$1
  local force=${2:-true}
  
  if ! command -v lsof &> /dev/null; then
    echo "  Warning: lsof not found, cannot check port $port"
    return 1
  fi
  
  local pids=$(lsof -ti :$port 2>/dev/null || true)
  
  if [ -z "$pids" ]; then
    return 0
  fi
  
  echo "  Found process(es) bound to port $port (PIDs: $pids)"
  
  if [ "$force" = true ]; then
    # Force kill
    echo -n "  Force killing process(es)... "
    for pid in $pids; do
      kill -9 "$pid" 2>/dev/null || true
    done
    
    # Verify port is free with retries
    local verify_retries=5
    while [ $verify_retries -gt 0 ]; do
      sleep 1
      if ! lsof -ti :$port &> /dev/null; then
        echo "✓"
        return 0
      fi
      verify_retries=$((verify_retries - 1))
    done
    
    echo "✗ (failed - port still in use after kill)"
    return 1
  else
    # Graceful kill
    echo -n "  Killing process(es)... "
    for pid in $pids; do
      kill "$pid" 2>/dev/null || true
    done
    sleep 2
    # Check if port is still in use
    if lsof -ti :$port &> /dev/null; then
      # Port still in use, try force kill
      echo "(grace period expired, force killing)"
      kill_port "$port" true
      return $?
    else
      echo "✓"
      return 0
    fi
  fi
}

# Function to recreate ca.jks from ca.p12 using the appropriate container runtime
recreate_ca_jks() {
  local keys_dir="${1:-.}"
  echo "  Converting ca.p12 to ca.jks..."

  # Ensure CONTAINER_RUNTIME is set
  if [ -z "${CONTAINER_RUNTIME:-}" ]; then
    echo "  ✗ ERROR: CONTAINER_RUNTIME is not set. Cannot recreate ca.jks."
    echo "  Please ensure detect_container_runtime() has been called first."
    return 1
  fi

  # Set up Java environment options for ARM64 Macs
  local JAVA_ENV_OPTS=""
  if [ -n "${JAVA_OPTS_APPEND:-}" ]; then
    JAVA_ENV_OPTS="-e JAVA_TOOL_OPTIONS=$JAVA_OPTS_APPEND"
  elif [ "$(uname -m)" = "arm64" ] && sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -q "Apple"; then
    JAVA_ENV_OPTS="-e JAVA_TOOL_OPTIONS=-XX:UseSVE=0"
  fi

  # Use the appropriate container runtime and volume mount flags
  local runtime_cmd="$CONTAINER_RUNTIME"
  local volume_flag
  if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    volume_flag=":Z"
  fi
  "$runtime_cmd" run --rm \
    "$JAVA_ENV_OPTS" \
    -v "$(cd "$keys_dir" && pwd):/keys${volume_flag}" \
    --entrypoint keytool \
    keycloak/keycloak:25.0 \
    -importkeystore \
    -srckeystore /keys/ca.p12 \
    -srcstoretype PKCS12 \
    -destkeystore /keys/ca.jks \
    -deststoretype JKS \
    -srcstorepass "${KEYSTORE_PASSWORD:-password}" \
    -deststorepass "${KEYSTORE_PASSWORD:-password}" \
    -noprompt
  
  echo "  ✓ ca.jks created successfully"
}

# Function to verify ca.jks is a file and fix if it's a directory
verify_and_fix_ca_jks() {
  local keys_dir="${1:-keys}"

  if [ -d "$keys_dir/ca.jks" ]; then
    echo "  Warning: ca.jks was created as a directory, removing and recreating..."
    rm -rf "$keys_dir/ca.jks"
    recreate_ca_jks "$keys_dir"
  fi
}

# Handle --stop flag
if [ "$STOP_ONLY" = true ]; then
  echo "Stopping OpenTDF platform..."

  # Kill any processes bound to port 8080
  echo "Checking for processes bound to port $PLATFORM_PORT..."
  kill_port $PLATFORM_PORT || true

  # Stop the platform service if running
  if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
      echo "  Stopping platform service (PID: $OLD_PID)..."
      # Kill the main process
      kill "$OLD_PID" 2>/dev/null || true
      # Also kill any child processes spawned by go run
      pkill -P "$OLD_PID" 2>/dev/null || true
      sleep 2
      # Force kill if still running
      kill -9 "$OLD_PID" 2>/dev/null || true
      pkill -9 -P "$OLD_PID" 2>/dev/null || true
      rm -f "$PID_FILE"
      echo "  ✓ Platform service stopped"
    else
      echo "  Platform service not running (stale PID file removed)"
      rm -f "$PID_FILE"
    fi
  else
    echo "  Platform service not running"
  fi

  # Also kill any orphaned service processes
  pkill -f "service start" 2>/dev/null || true

  # Stop containers
  if [ -d platform ]; then
    (
      cd platform
      echo "  Stopping and removing containers..."
      # Check for container runtime without failing
      compose_cmd=""
      if command -v docker &> /dev/null; then
        if docker compose version &> /dev/null; then
          compose_cmd="docker compose"
        elif command -v docker-compose &> /dev/null; then
          compose_cmd="docker-compose"
        fi
      elif command -v podman &> /dev/null; then
        if podman compose version &> /dev/null; then
          compose_cmd="podman compose"
        elif command -v podman-compose &> /dev/null; then
          compose_cmd="podman-compose"
        fi
      fi

      if [ -n "$compose_cmd" ]; then
        $compose_cmd down -v 2>/dev/null || true
        echo "  ✓ Containers stopped and removed"
      else
        echo "  Warning: No container runtime found (docker/podman), skipping container cleanup"
      fi
    ) || true
  else
    echo "  Platform directory not found, skipping container cleanup"
  fi

  echo ""
  echo "OpenTDF platform stopped successfully!"
  exit 0
fi

# Detect container runtime (Docker or Podman)
echo "Detecting container runtime..."
detect_container_runtime
echo ""

# Check for required CLI tools
echo "Checking required CLI tools..."
REQUIRED_TOOLS=("git" "yq" "go")
MISSING_TOOLS=()

for tool in "${REQUIRED_TOOLS[@]}"; do
  if ! command -v "$tool" &> /dev/null; then
    MISSING_TOOLS+=("$tool")
    echo "  ✗ $tool - NOT FOUND"
  else
    VERSION=$("$tool" --version 2>&1 | head -n1 || echo "unknown")
    echo "  ✓ $tool - found ($VERSION)"
  fi
done

if [ ${#MISSING_TOOLS[@]} -gt 0 ]; then
  echo ""
  echo "ERROR: Missing required tools: ${MISSING_TOOLS[*]}"
  echo "Please install the missing tools and try again."
  exit 1
fi

echo ""
echo "All required tools found!"
echo "Container runtime: $CONTAINER_RUNTIME"
echo "Compose command: $COMPOSE_CMD"
echo ""

# Detect yq version and set appropriate flags
YQ_VERSION=$(yq --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 | cut -d. -f1)
YQ_FLAGS="-i"
if [ -n "$YQ_VERSION" ] && [ "$YQ_VERSION" -lt 4 ]; then
  # yq v3 requires -y flag for YAML output
  YQ_FLAGS="-y -i"
  echo "Detected yq v3, using legacy flags"
else
  echo "Detected yq v4+, using modern syntax"
fi
echo ""

# If using podman, create a docker wrapper function for compatibility
if [ "$CONTAINER_RUNTIME" = "podman" ]; then
  if ! command -v docker &> /dev/null; then
    echo "Creating docker -> podman compatibility wrapper"
    # Create a temporary directory for our docker wrapper
    WRAPPER_DIR=$(mktemp -d)
    # Ensure cleanup on exit
    trap 'rm -rf "$WRAPPER_DIR"' EXIT
    cat > "$WRAPPER_DIR/docker" << 'EOF'
#!/usr/bin/env bash
exec podman "$@"
EOF
    chmod +x "$WRAPPER_DIR/docker"
    export PATH="$WRAPPER_DIR:$PATH"
    echo "✓ Docker commands will be redirected to podman"
    echo ""
  fi
fi

# Check if platform is already running
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  if kill -0 "$OLD_PID" 2>/dev/null; then
    echo "OpenTDF platform is already running (PID: $OLD_PID)"
    echo "Log file: $LOG_FILE"

    if [ "$AUTO_RESTART" = true ]; then
      echo "Automatically stopping and restarting..."
      echo "Stopping platform (PID: $OLD_PID)..."
      
      # Gracefully kill the main process first
      kill "$OLD_PID" 2>/dev/null || true
      pkill -P "$OLD_PID" 2>/dev/null || true
      sleep 1
      
      # Force kill if still running
      kill -9 "$OLD_PID" 2>/dev/null || true
      pkill -9 -P "$OLD_PID" 2>/dev/null || true
      rm -f "$PID_FILE"
      
      # Ensure port 8080 is cleaned up
      echo "Cleaning up port $PLATFORM_PORT..."
      if ! kill_port $PLATFORM_PORT; then
        echo "  Warning: Failed to clean up port $PLATFORM_PORT, but continuing..."
      fi

      # Additional safety: wait for port to be released
      sleep 1
      
      if [ -f "$LOG_FILE" ]; then
        echo "Removing old log file: $LOG_FILE"
        rm -f "$LOG_FILE"
      fi
      echo "✓ Previous instance stopped"
      echo ""
    else
      echo "Platform is already running. Use --auto-restart to restart it."
      exit 0
    fi
  else
    # PID file exists but process is not running
    echo "Cleaning up stale PID file..."
    rm -f "$PID_FILE"
  fi
fi

if ! [ -d platform ]; then
  echo "Cloning OpenTDF platform repository..."
  git clone https://github.com/opentdf/platform.git
  echo "✓ Repository cloned"
else
  echo "Platform directory already exists, skipping clone"
fi

echo "Entering platform directory..."
cd platform

echo "Checking out version service/v0.11.3..."
git checkout service/v0.11.3
echo "✓ Checked out service/v0.11.3"
echo ""

echo "Configuring Keycloak clients..."
yq "$YQ_FLAGS" '.realms[0].clients[0].client.directAccessGrantsEnabled = true | .realms[0].clients[0].client.serviceAccountsEnabled = true' service/cmd/keycloak_data.yaml

yq "$YQ_FLAGS" '.realms[0].clients[1].client.directAccessGrantsEnabled = true | .realms[0].clients[1].client.serviceAccountsEnabled = true' service/cmd/keycloak_data.yaml

yq "$YQ_FLAGS" '.realms[0].clients[4].client.directAccessGrantsEnabled = true | .realms[0].clients[4].client.serviceAccountsEnabled = true' service/cmd/keycloak_data.yaml
echo "✓ Keycloak clients configured"
echo ""


if ! [ -d ./keys ]; then
  echo "Keys directory not found. Setting up for first time..."

  echo "Downloading Go modules..."
  go mod download
  echo "✓ Go modules downloaded"

  echo "Verifying Go modules..."
  go mod verify
  echo "✓ Go modules verified"

  echo "Initializing temporary keys..."

  # The init-temp-keys.sh script uses 'docker run' which needs to use our detected container runtime
  # We'll use a modified version that works with both docker and podman
  if [ "$CONTAINER_RUNTIME" = "podman" ]; then
    # For podman, we need to ensure the docker wrapper is available
    .github/scripts/init-temp-keys.sh

    # Check if ca.jks was created successfully as a file (not a directory)
    verify_and_fix_ca_jks "./keys"
  else
    .github/scripts/init-temp-keys.sh
  fi

  echo "✓ Keys initialized"

  echo "Creating opentdf.yaml configuration..."
  cp opentdf-example.yaml opentdf.yaml
  echo "✓ Configuration file created"

  # Edit 'opentdf.yaml' for our use case
  echo "Customizing opentdf.yaml..."
  yq "$YQ_FLAGS" 'del(.db) | .services.entityresolution.url = "http://localhost:8888/auth" | .server.auth.issuer = "http://localhost:8888/auth/realms/opentdf"' opentdf.yaml
  # The above expression can also be written as 3 separate commands:
  # yq $YQ_FLAGS 'del(.db)' opentdf.yaml
  # yq $YQ_FLAGS '.services.entityresolution.url = "http://localhost:8888/auth"' opentdf.yaml
  # yq $YQ_FLAGS '.server.auth.issuer = "http://localhost:8888/auth/realms/opentdf"' opentdf.yaml

  echo "Configuring crypto provider..."
  yq "$YQ_FLAGS" '
.server.cryptoProvider = {
  "type": "standard",
  "standard": {
    "keys": [
      {
        "kid": "r1",
        "alg": "rsa:2048",
        "private": "kas-private.pem",
        "cert": "kas-cert.pem"
      },
      {
        "kid": "e1",
        "alg": "ec:secp256r1",
        "private": "kas-ec-private.pem",
        "cert": "kas-ec-cert.pem"
      }
    ]
  }
}
' opentdf.yaml
  echo "✓ Crypto provider configured"

  echo "Setting permissions on keys directory..."
  chmod -R 700 ./keys
  echo "✓ Permissions set"
  echo ""
else
  echo "Keys directory already exists, skipping initialization"
  echo ""
fi

echo "Verifying ca.jks is a valid file before starting containers..."
if [ ! -f ./keys/ca.jks ]; then
  if [ -d ./keys/ca.jks ]; then
    echo "  ✗ ERROR: ca.jks exists as a directory instead of a file"
    echo "  This will cause Keycloak to fail. Removing and recreating..."
    verify_and_fix_ca_jks "./keys"
  else
    echo "  ✗ ERROR: ca.jks not found at ./keys/ca.jks"
    echo "  Please run the key initialization first"
    exit 1
  fi
fi

if [ -f ./keys/ca.jks ]; then
  echo "✓ ca.jks verified as valid file"
else
  echo "  ✗ ERROR: Failed to create ca.jks"
  exit 1
fi
echo ""

echo "Stopping and removing any existing containers to ensure clean state..."
$COMPOSE_CMD down -v 2>/dev/null || true
echo "✓ Existing containers removed"
echo ""

echo "Starting container services using $COMPOSE_CMD..."
# Try with --wait flag first, fall back to basic up if it fails
if ! $COMPOSE_CMD up -d --wait --wait-timeout 600 2>/dev/null; then
  echo "  Note: --wait flag not supported, using basic up command"
  $COMPOSE_CMD up -d
  echo "  Waiting 30 seconds for services to be ready..."
  sleep 30
fi
echo "✓ Container services are up and ready"
echo ""

echo "Waiting for Keycloak to be healthy..."
KEYCLOAK_URL="http://localhost:8888/auth/realms/master"
MAX_RETRIES=60
RETRY_COUNT=0
while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
  if curl -sf "$KEYCLOAK_URL" > /dev/null 2>&1; then
    echo "✓ Keycloak is healthy and ready"
    break
  fi
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $((RETRY_COUNT % 10)) -eq 0 ]; then
    echo "  Still waiting for Keycloak... ($((RETRY_COUNT * 3))s elapsed)"
  fi
  sleep 3
done

if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
  echo "  ✗ Keycloak did not become healthy within $((MAX_RETRIES * 3)) seconds"
  echo "  Attempting to provision anyway, but this may fail..."
else
  echo "  Keycloak became ready after $((RETRY_COUNT * 3)) seconds"
fi
echo ""

echo "Provisioning Keycloak..."
go run ./service provision keycloak
echo "✓ Keycloak provisioned"
echo ""

echo "Provisioning fixtures..."
go run ./service provision fixtures
echo "✓ Fixtures provisioned"
echo ""

# Ensure port 8080 is available before starting
echo "Ensuring port $PLATFORM_PORT is available..."
MAX_PORT_RETRIES=10
PORT_RETRY_COUNT=0
while [ $PORT_RETRY_COUNT -lt $MAX_PORT_RETRIES ]; do
  if ! lsof -ti :$PLATFORM_PORT &> /dev/null; then
    echo "✓ Port $PLATFORM_PORT is available"
    break
  fi

  PORT_RETRY_COUNT=$((PORT_RETRY_COUNT + 1))

  if [ $PORT_RETRY_COUNT -eq 1 ]; then
    echo "  Port $PLATFORM_PORT is still in use, waiting for it to be released..."
    # One more aggressive attempt to clean it up
    kill_port $PLATFORM_PORT || echo "  Warning: Could not kill process on port $PLATFORM_PORT"
  fi

  if [ $PORT_RETRY_COUNT -lt $MAX_PORT_RETRIES ]; then
    sleep 1
  fi
done

if [ $PORT_RETRY_COUNT -eq $MAX_PORT_RETRIES ]; then
  echo "  ✗ ERROR: Port $PLATFORM_PORT did not become available after $MAX_PORT_RETRIES seconds"
  echo "  Processes still using port $PLATFORM_PORT:"
  lsof -i :$PLATFORM_PORT || true
  echo ""
  echo "  To manually clean up, run:"
  echo "    lsof -ti :$PLATFORM_PORT | xargs kill -9"
  exit 1
fi
echo ""

# Start the platform in the background
echo "Starting OpenTDF platform..."
echo "Log file: $LOG_FILE"
nohup go run ./service start > "$LOG_FILE" 2>&1 &
PLATFORM_PID=$!
echo $PLATFORM_PID > "$PID_FILE"

echo "OpenTDF platform started successfully!"
echo "  PID: $PLATFORM_PID"
echo "  Log: $LOG_FILE"
echo ""
echo "To view logs: tail -f $LOG_FILE"
echo "To stop: kill $PLATFORM_PID (or re-run this script)"
