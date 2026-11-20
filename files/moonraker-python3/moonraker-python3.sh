#!/bin/sh
#
# Run Moonraker on a newer Python (Entware python3) instead of the K1C's
# system Python 3.8. Klipper keeps using the system Python.
#
#   sh moonraker-python3.sh build     build + test the new environment
#                                     (Moonraker keeps running)
#   sh moonraker-python3.sh switch    switch Moonraker to it, with
#                                     automatic rollback if it doesn't start
#   sh moonraker-python3.sh rollback  go back to the Python 3.8 environment
#   sh moonraker-python3.sh status    show which Python Moonraker uses
#
# All Python packages are installed offline from ./wheels. Only the Entware
# packages (python3, python3-pip, python3-pillow, libsodium, gcc) are
# downloaded, from bin.entware.net.

set -e

HERE="$(cd "$(dirname "$0")" && pwd)"
WHEELS="$HERE/wheels"
REQS="$HERE/requirements.txt"
USR_DATA="${USR_DATA:-/usr/data}"
MR_DIR="$USR_DATA/moonraker"
ENV_NOW="$MR_DIR/moonraker-env"
ENV_PY38="$MR_DIR/moonraker-env-py38"
ENV_NEW="$MR_DIR/moonraker-env-py3"
OPKG=/opt/bin/opkg
PY3=/opt/bin/python3
CURL="${CURL:-$USR_DATA/helper-script/files/fixes/curl}"
SERVICE="${SERVICE:-/etc/init.d/S56moonraker_service}"
BUILD_TMP="$USR_DATA/tmp-moonraker-py3"
TEST_DIR="$BUILD_TMP/test-data"
TEST_PORT=7199

info() { echo "Info: $*"; }
fail() { echo "ERROR: $*"; exit 1; }

env_python_version() {
  "$1/bin/python" -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "?"
}

opkg_install_retry() {
  # Install only the missing packages, retrying because downloads from
  # bin.entware.net can time out.
  local missing="" p i
  for p in "$@"; do
    "$OPKG" list-installed | grep -q "^$p " || missing="$missing $p"
  done
  if [ -z "$missing" ]; then
    echo "  all installed: $*"
    return 0
  fi
  info "Installing:$missing"
  for i in 1 2 3 4 5 6 7 8; do
    if "$OPKG" update && "$OPKG" install $missing; then
      return 0
    fi
    echo "  attempt $i failed, retrying in 5 s..."
    sleep 5
  done
  fail "Could not download Entware packages:$missing (bin.entware.net unreachable). Run build again later."
}

wait_for_port() {
  local port="$1" i=0
  while [ $i -lt 30 ]; do
    if "$CURL" -s -o /dev/null --connect-timeout 2 "http://127.0.0.1:$port/server/info"; then
      return 0
    fi
    sleep 3
    i=$((i + 1))
  done
  return 1
}

smoke_test() {
  # Start Moonraker from the given environment on a test port with its own
  # data folder, and check that every component loads.
  local env="$1" pid out failed
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR/config" "$TEST_DIR/logs"
  cat > "$TEST_DIR/config/moonraker.conf" <<EOF
[server]
host: 127.0.0.1
port: $TEST_PORT
klippy_uds_address: $BUILD_TMP/klippy_uds_test
[file_manager]
[database]
[data_store]
[machine]
provider: none
validate_service: False
validate_config: False
[authorization]
trusted_clients:
  127.0.0.0/8
[octoprint_compat]
[history]
[update_manager]
enable_auto_refresh: False
EOF
  info "Starting test Moonraker on port $TEST_PORT (takes up to 90 s)..."
  "$env/bin/python" "$MR_DIR/moonraker/moonraker/moonraker.py" -d "$TEST_DIR" \
    > "$BUILD_TMP/test-moonraker.out" 2>&1 &
  pid=$!
  if ! wait_for_port "$TEST_PORT"; then
    kill "$pid" 2>/dev/null || true
    echo "---- last lines of the test log ----"
    tail -30 "$BUILD_TMP/test-moonraker.out"
    return 1
  fi
  out=$("$CURL" -s "http://127.0.0.1:$TEST_PORT/server/info")
  kill "$pid" 2>/dev/null || true
  sleep 2
  failed=$(echo "$out" | sed -n 's/.*"failed_components": *\[\([^]]*\)\].*/\1/p')
  echo "  $(echo "$out" | sed -n 's/.*"moonraker_version": *"\([^"]*\)".*/moonraker \1/p')"
  if [ -n "$failed" ]; then
    echo "  failed components: $failed"
    return 1
  fi
  return 0
}

cmd_build() {
  [ -x "$OPKG" ] || fail "Entware is not installed (no $OPKG)."
  [ -d "$MR_DIR/moonraker/moonraker" ] || fail "Moonraker is not installed in $MR_DIR."
  [ -d "$WHEELS" ] || fail "Wheels folder $WHEELS is missing."

  local free_kb
  free_kb=$(df -k "$USR_DATA" | awk 'NR==2 {print $4}')
  [ "${free_kb:-0}" -ge 307200 ] || fail "Not enough free space in $USR_DATA (300 MB needed)."

  rm -rf "$BUILD_TMP"
  mkdir -p "$BUILD_TMP"
  info "Checking Entware packages..."
  opkg_install_retry python3 python3-pip python3-pillow python3-dev libsodium gcc

  local inc
  inc=$("$PY3" -c 'import sysconfig; print(sysconfig.get_paths()["include"])')
  [ -f "$inc/Python.h" ] || fail "Python headers not found in $inc (needed to build streaming-form-data)."

  # Native compiling with Entware gcc needs the libc headers package
  if ! echo '#include <stdio.h>' | /opt/bin/gcc -E - > /dev/null 2>&1; then
    info "Installing C headers for Entware gcc..."
    mkdir -p "$BUILD_TMP" /opt/include
    local n=0
    until "$CURL" -L --connect-timeout 15 -o "$BUILD_TMP/include.tar.gz" http://bin.entware.net/mipselsf-k3.4/include/include.tar.gz; do
      n=$((n + 1)); [ $n -lt 8 ] || fail "Could not download include.tar.gz. Run build again later."
      echo "  attempt $n failed, retrying in 5 s..."; sleep 5
    done
    tar -xzf "$BUILD_TMP/include.tar.gz" -C /opt/include
    echo '#include <stdio.h>' | /opt/bin/gcc -E - > /dev/null 2>&1 || fail "gcc still can't find C headers."
  fi

  # libnacl loads libsodium via dlopen("libsodium.so")
  if [ ! -e /opt/lib/libsodium.so ]; then
    local so
    so=$(ls /opt/lib/libsodium.so.* 2>/dev/null | head -1)
    [ -n "$so" ] && ln -sf "$so" /opt/lib/libsodium.so
  fi

  info "Python: $("$PY3" --version)"
  info "Creating environment $ENV_NEW..."
  rm -rf "$ENV_NEW"
  mkdir -p "$BUILD_TMP"
  # --system-site-packages: pip and pillow come from Entware
  "$PY3" -m venv --system-site-packages --without-pip "$ENV_NEW"

  info "Installing Moonraker requirements offline (streaming-form-data is compiled, takes a few minutes)..."
  # Use the local gcc, not the cross compiler recorded in Python's sysconfig
  TMPDIR="$BUILD_TMP" CC=/opt/bin/gcc LDSHARED="/opt/bin/gcc -shared" \
    "$ENV_NEW/bin/python" -m pip install --no-cache-dir \
    --no-index --find-links "$WHEELS" -r "$REQS"

  info "Checking imports..."
  "$ENV_NEW/bin/python" -c 'import tornado, streaming_form_data, PIL, libnacl.sign, zeroconf, dbus_fast, paho.mqtt, apprise, jinja2, serial; print("  all imports OK")'

  if smoke_test "$ENV_NEW"; then
    info "Build OK. Run 'sh $0 switch' to switch Moonraker to Python $(env_python_version "$ENV_NEW")."
  else
    fail "Test Moonraker didn't start correctly. Nothing was changed on your running Moonraker."
  fi
}

cmd_switch() {
  [ -x "$ENV_NEW/bin/python" ] || fail "New environment not found. Run 'sh $0 build' first."
  [ ! -e "$ENV_PY38" ] || fail "$ENV_PY38 already exists, Moonraker seems to be switched already."

  info "Stopping Moonraker..."
  "$SERVICE" stop || true
  sleep 1
  info "Keeping Python 3.8 environment as $ENV_PY38..."
  mv "$ENV_NOW" "$ENV_PY38"
  mv "$ENV_NEW" "$ENV_NOW"
  sed -i "s#$ENV_NEW#$ENV_NOW#g" "$ENV_NOW"/bin/activate* 2>/dev/null || true
  info "Starting Moonraker..."
  "$SERVICE" start
  if wait_for_port 7125; then
    info "Moonraker is running on Python $(env_python_version "$ENV_NOW")."
    info "To go back: sh $0 rollback"
  else
    echo "Moonraker didn't start, rolling back..."
    cmd_rollback
    fail "Switch failed, Python 3.8 environment restored. See /usr/data/printer_data/logs/moonraker.log"
  fi
}

cmd_rollback() {
  [ -d "$ENV_PY38" ] || fail "No Python 3.8 environment to go back to ($ENV_PY38)."
  info "Stopping Moonraker..."
  "$SERVICE" stop || true
  sleep 1
  rm -rf "$ENV_NEW"
  mv "$ENV_NOW" "$ENV_NEW"
  mv "$ENV_PY38" "$ENV_NOW"
  info "Starting Moonraker..."
  "$SERVICE" start
  if wait_for_port 7125; then
    info "Moonraker is back on Python $(env_python_version "$ENV_NOW")."
  else
    fail "Moonraker didn't start after rollback. See /usr/data/printer_data/logs/moonraker.log"
  fi
}

cmd_status() {
  echo "Moonraker environment: $ENV_NOW (Python $(env_python_version "$ENV_NOW"))"
  [ -d "$ENV_NEW" ] && echo "Built, not active:    $ENV_NEW (Python $(env_python_version "$ENV_NEW"))"
  [ -d "$ENV_PY38" ] && echo "Backup:               $ENV_PY38 (Python $(env_python_version "$ENV_PY38"))"
  return 0
}

case "$1" in
  build) cmd_build ;;
  switch) cmd_switch ;;
  rollback) cmd_rollback ;;
  status) cmd_status ;;
  *) echo "Usage: sh $0 {build|switch|rollback|status}"; exit 1 ;;
esac
