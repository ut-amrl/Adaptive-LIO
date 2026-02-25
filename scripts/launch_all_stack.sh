#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage:
  scripts/launch_all_stack.sh [options]

Launches the full Adaptive-LIO stack in one command:
  - Docker container
  - Adaptive-LIO node
  - rviz2
  - ros2 bag play

Defaults are tuned for ARL Lonebot and queue starvation mitigation.

Options:
  --bag-path <path>          Rosbag path inside container (default: /data/ARL_Jackal/rosbags/2-17-pickle/run_05_pickle-north-baseline_2026-02-17-10-52-50/)
  --rate <value>             Bag playback rate (default: 0.5)
  --queue-size <int>         ros2 bag read-ahead queue size (default: 5000)
  --imu-topic <topic>        IMU topic when filtering bag topics
  --lidar-topic <topic>      LiDAR topic when filtering bag topics
  --rviz <true|false>        Launch rviz2 (default: true)
  --config-file <path>       Config file path inside container
  --all-topics               Do not filter bag topics (play all topics)
  --build                    Build docker image before run
  --no-xhost                 Do not run xhost setup
  -h, --help                 Show this help

Environment overrides:
  ROS_DISTRO                 Default: jazzy
  DATA_MOUNT                 Host path mounted to /data (default: /home/domlee/mnt/ARL_SARA)
EOF
}

require_arg() {
  local opt="$1"
  local value="${2:-}"
  if [[ -z "${value}" ]]; then
    echo "Missing value for ${opt}" >&2
    print_usage >&2
    exit 2
  fi
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker/compose.yaml"

ROS_DISTRO="${ROS_DISTRO:-jazzy}"
DATA_MOUNT="${DATA_MOUNT:-/home/domlee/mnt/ARL_SARA}"

BAG_PATH="/data/ARL_Jackal/rosbags/2-17-pickle/run_05_pickle-north-baseline_2026-02-17-10-52-50/"
BAG_RATE="0.5"
QUEUE_SIZE="5000"
RVIZ="true"
CONFIG_FILE="/root/adaptive_lio_ws/src/adaptive_lio/config/mapping_m.yaml"

ONLY_IMU_LIDAR="true"
IMU_TOPIC="/lonebot/sensors/microstrain/imu/data"
LIDAR_TOPIC="/lonebot/sensors/ouster/points"

DO_BUILD="false"
DO_XHOST="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bag-path)
      require_arg "$1" "${2:-}"
      BAG_PATH="$2"
      shift 2
      ;;
    --rate)
      require_arg "$1" "${2:-}"
      BAG_RATE="$2"
      shift 2
      ;;
    --queue-size)
      require_arg "$1" "${2:-}"
      QUEUE_SIZE="$2"
      shift 2
      ;;
    --imu-topic)
      require_arg "$1" "${2:-}"
      IMU_TOPIC="$2"
      shift 2
      ;;
    --lidar-topic)
      require_arg "$1" "${2:-}"
      LIDAR_TOPIC="$2"
      shift 2
      ;;
    --rviz)
      require_arg "$1" "${2:-}"
      RVIZ="$2"
      shift 2
      ;;
    --config-file)
      require_arg "$1" "${2:-}"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --all-topics)
      ONLY_IMU_LIDAR="false"
      shift
      ;;
    --build)
      DO_BUILD="true"
      shift
      ;;
    --no-xhost)
      DO_XHOST="false"
      shift
      ;;
    -h|--help)
      print_usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

if [[ ! -d "${DATA_MOUNT}" ]]; then
  echo "data mount path not found: ${DATA_MOUNT}" >&2
  echo "Set DATA_MOUNT or create the path." >&2
  exit 1
fi

if [[ "${DO_XHOST}" == "true" ]]; then
  if command -v xhost >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    xhost +si:localuser:root >/dev/null
  else
    echo "[warn] skipping xhost setup (xhost missing or DISPLAY unset)"
  fi
fi

cd "${REPO_ROOT}"

if [[ "${DO_BUILD}" == "true" ]]; then
  ROS_DISTRO="${ROS_DISTRO}" docker compose -f "${COMPOSE_FILE}" build adaptive_lio
fi

LAUNCH_CMD="ros2 launch adaptive_lio run.launch.py"
for arg in \
  "rviz:=${RVIZ}" \
  "config_file:=${CONFIG_FILE}" \
  "play_bag:=true" \
  "bag_path:=${BAG_PATH}" \
  "bag_rate:=${BAG_RATE}" \
  "bag_read_ahead_queue_size:=${QUEUE_SIZE}" \
  "bag_only_imu_and_lidar:=${ONLY_IMU_LIDAR}" \
  "bag_imu_topic:=${IMU_TOPIC}" \
  "bag_lidar_topic:=${LIDAR_TOPIC}"
do
  printf -v LAUNCH_CMD '%s %q' "${LAUNCH_CMD}" "${arg}"
done

INNER_CMD=$(cat <<EOF
set -e
source /opt/ros/${ROS_DISTRO}/setup.bash
source /root/livox_ws/install/setup.bash
source /root/adaptive_lio_ws/install/setup.bash
${LAUNCH_CMD}
EOF
)

echo "[run] ROS_DISTRO=${ROS_DISTRO}"
echo "[run] DATA_MOUNT=${DATA_MOUNT} -> /data"
echo "[run] bag_path=${BAG_PATH} rate=${BAG_RATE} queue=${QUEUE_SIZE} only_imu_lidar=${ONLY_IMU_LIDAR}"

ROS_DISTRO="${ROS_DISTRO}" docker compose -f "${COMPOSE_FILE}" run --rm \
  -v "${DATA_MOUNT}:/data" \
  --entrypoint bash adaptive_lio -lc "${INNER_CMD}"
