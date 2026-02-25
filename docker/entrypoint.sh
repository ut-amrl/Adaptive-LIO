#!/usr/bin/env bash
set -eo pipefail

log() { echo "[entrypoint] $*"; }

safe_source() {
  local f="$1"
  if [ -f "$f" ]; then
    set +u
    # shellcheck disable=SC1090
    source "$f"
    set -u 2>/dev/null || true
  fi
}

ros_distro="${ROS_DISTRO:-jazzy}"
ros_setup="/opt/ros/${ros_distro}/setup.bash"

log "starting (ROS_DISTRO=${ros_distro})"

if [ -f "$ros_setup" ]; then
  safe_source "$ros_setup"
else
  log "ERROR: ROS setup not found at $ros_setup"
  exec "$@"
fi

safe_source /root/livox_ws/install/setup.bash

ws="/root/adaptive_lio_ws"
if [ ! -d "${ws}/src" ]; then
  log "ERROR: ${ws}/src does not exist"
  log "Mount your repo into ${ws}/src/adaptive_lio"
  exec "$@"
fi

if [ -z "$(ls -A "${ws}/src" 2>/dev/null)" ]; then
  log "WARNING: ${ws}/src is empty; skipping build"
  exec "$@"
fi

install_setup="${ws}/install/setup.bash"
need_build=0
if [ ! -f "$install_setup" ]; then
  need_build=1
elif find "${ws}/src" -type f -newer "$install_setup" -print -quit | grep -q .; then
  need_build=1
fi

if [ "$need_build" -eq 0 ]; then
  log "Adaptive-LIO already built; sourcing overlay"
  safe_source "$install_setup"
else
  log "building Adaptive-LIO"
  cd "$ws"
  colcon build --symlink-install --cmake-args -DCMAKE_BUILD_TYPE=Release

  log "build done; sourcing overlay"
  safe_source "$install_setup"
fi

if [ "${USE_TMUX:-0}" = "1" ]; then
  SESSION="${TMUX_SESSION:-adaptive_lio}"

  if [ $# -eq 0 ] || { [ "$1" = "bash" ] && [ $# -eq 1 ]; } || { [ "$1" = "bash" ] && [ "${2:-}" = "-l" ]; }; then
    log "starting tmux session: ${SESSION}"
    exec tmux new -A -s "${SESSION}"
  fi
fi

exec "$@"
