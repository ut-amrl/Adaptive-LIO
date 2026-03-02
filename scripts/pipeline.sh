#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage:
  scripts/pipeline.sh run [options]
  scripts/pipeline.sh build
  scripts/pipeline.sh help

Environment:
  ROS_DISTRO                 Required (example: ROS_DISTRO=jazzy)
  DATA_MOUNT                 Host path mounted to /data (default: /home/domlee/mnt/ARL_SARA)

Run options:
  --bag-path <path>          Single bag directory (host path or /data path)
  --bag-list <txt>           Text file with one bag path per line
  --config-file <path>       Adaptive-LIO config path (default: config/mapping_m.yaml)
  --rate <auto|num>          Bag play rate (default: auto, minimum fixed rate: 0.5)
  --queue-size <int>         ros2 bag read-ahead queue size (default: 5000)
  --rviz <true|false>        Launch rviz2 (default: true)
  --all-topics               Play all bag topics (default: false)
  --imu-topic <topic>        Override IMU topic (default: from config)
  --lidar-topic <topic>      Override LiDAR topic (default: from config)
  --log-dir <path>           Host log dir mounted to /logs (default: logs)
  --build                    Build image before run
  --no-xhost                 Skip xhost setup even with rviz:=true
  -h, --help                 Show this help
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

trim_line() {
  local line="$1"
  line="${line%%#*}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  printf '%s' "${line}"
}

to_abs_host_path() {
  local path="$1"
  if [[ "${path}" == /* ]]; then
    printf '%s\n' "${path}"
  else
    printf '%s\n' "${REPO_ROOT}/${path}"
  fi
}

to_container_bag_path() {
  local path="$1"
  local data_mount="${DATA_MOUNT%/}"
  if [[ "${path}" == /data/* || "${path}" == "/data" ]]; then
    printf '%s\n' "${path}"
    return
  fi
  if [[ "${path}" == "${data_mount}" ]]; then
    printf '/data\n'
    return
  fi
  if [[ "${path}" == "${data_mount}/"* ]]; then
    printf '/data/%s\n' "${path#"${data_mount}/"}"
    return
  fi
  printf '%s\n' "${path}"
}

to_container_config_path() {
  local path="$1"
  local data_mount="${DATA_MOUNT%/}"
  if [[ "${path}" == /root/adaptive_lio_ws/src/adaptive_lio/* || "${path}" == /data/* ]]; then
    printf '%s\n' "${path}"
    return
  fi
  if [[ "${path}" == "${REPO_ROOT}" ]]; then
    printf '/root/adaptive_lio_ws/src/adaptive_lio\n'
    return
  fi
  if [[ "${path}" == "${REPO_ROOT}/"* ]]; then
    printf '/root/adaptive_lio_ws/src/adaptive_lio/%s\n' "${path#"${REPO_ROOT}/"}"
    return
  fi
  if [[ "${path}" == "${data_mount}" ]]; then
    printf '/data\n'
    return
  fi
  if [[ "${path}" == "${data_mount}/"* ]]; then
    printf '/data/%s\n' "${path#"${data_mount}/"}"
    return
  fi
  if [[ "${path}" != /* ]]; then
    printf '/root/adaptive_lio_ws/src/adaptive_lio/%s\n' "${path}"
    return
  fi
  printf '%s\n' "${path}"
}

sanitize_name() {
  local raw="$1"
  raw="$(basename -- "${raw}")"
  raw="${raw// /_}"
  raw="${raw//\//_}"
  raw="$(printf '%s' "${raw}" | tr -cd 'A-Za-z0-9._-')"
  if [[ -z "${raw}" ]]; then
    raw="bag"
  fi
  printf '%s\n' "${raw}"
}

STOP_REQUESTED=0
CURRENT_DOCKER_PID=""

handle_interrupt() {
  if [[ "${STOP_REQUESTED}" -eq 0 ]]; then
    echo "[run] interrupt received; stopping current run..."
  fi
  STOP_REQUESTED=1
  if [[ -n "${CURRENT_DOCKER_PID}" ]] && kill -0 "${CURRENT_DOCKER_PID}" >/dev/null 2>&1; then
    kill -INT "${CURRENT_DOCKER_PID}" >/dev/null 2>&1 || true
    sleep 1
    kill -TERM "${CURRENT_DOCKER_PID}" >/dev/null 2>&1 || true
  fi
}

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
COMPOSE_FILE="${REPO_ROOT}/docker/compose.yaml"
INNER_SCRIPT="/root/adaptive_lio_ws/src/adaptive_lio/scripts/pipeline_inside_container.sh"

SUBCOMMAND="${1:-run}"
if [[ $# -gt 0 ]]; then
  shift
fi

DATA_MOUNT="${DATA_MOUNT:-/home/domlee/mnt/ARL_SARA}"

case "${SUBCOMMAND}" in
  help|-h|--help)
    print_usage
    exit 0
    ;;
  build)
    if [[ -z "${ROS_DISTRO:-}" ]]; then
      echo "ROS_DISTRO is required. Example: ROS_DISTRO=jazzy scripts/pipeline.sh build" >&2
      exit 2
    fi
    env ROS_DISTRO="${ROS_DISTRO}" docker compose -f "${COMPOSE_FILE}" build adaptive_lio
    exit 0
    ;;
  run)
    if [[ -z "${ROS_DISTRO:-}" ]]; then
      echo "ROS_DISTRO is required. Example: ROS_DISTRO=jazzy scripts/pipeline.sh run ..." >&2
      exit 2
    fi
    ;;
  *)
    echo "Unknown command: ${SUBCOMMAND}" >&2
    print_usage >&2
    exit 2
    ;;
esac

BAG_PATH=""
BAG_LIST=""
CONFIG_FILE="config/mapping_m.yaml"
RATE_MODE="auto"
QUEUE_SIZE="5000"
RVIZ="true"
ALL_TOPICS="false"
IMU_TOPIC_OVERRIDE=""
LIDAR_TOPIC_OVERRIDE=""
LOG_DIR="logs"
DO_BUILD="false"
DO_XHOST="true"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --bag-path)
      require_arg "$1" "${2:-}"
      BAG_PATH="$2"
      shift 2
      ;;
    --bag-list)
      require_arg "$1" "${2:-}"
      BAG_LIST="$2"
      shift 2
      ;;
    --config-file)
      require_arg "$1" "${2:-}"
      CONFIG_FILE="$2"
      shift 2
      ;;
    --rate)
      require_arg "$1" "${2:-}"
      RATE_MODE="$2"
      shift 2
      ;;
    --queue-size)
      require_arg "$1" "${2:-}"
      QUEUE_SIZE="$2"
      shift 2
      ;;
    --rviz)
      require_arg "$1" "${2:-}"
      RVIZ="$2"
      shift 2
      ;;
    --all-topics)
      ALL_TOPICS="true"
      shift
      ;;
    --imu-topic)
      require_arg "$1" "${2:-}"
      IMU_TOPIC_OVERRIDE="$2"
      shift 2
      ;;
    --lidar-topic)
      require_arg "$1" "${2:-}"
      LIDAR_TOPIC_OVERRIDE="$2"
      shift 2
      ;;
    --log-dir)
      require_arg "$1" "${2:-}"
      LOG_DIR="$2"
      shift 2
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

if [[ -z "${BAG_PATH}" && -z "${BAG_LIST}" ]]; then
  echo "One input is required: --bag-path or --bag-list" >&2
  exit 2
fi

if [[ -n "${BAG_PATH}" && -n "${BAG_LIST}" ]]; then
  echo "Use either --bag-path or --bag-list, not both" >&2
  exit 2
fi

if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "compose file not found: ${COMPOSE_FILE}" >&2
  exit 1
fi

if [[ ! -d "${DATA_MOUNT}" ]]; then
  echo "DATA_MOUNT path not found: ${DATA_MOUNT}" >&2
  echo "Set DATA_MOUNT to your dataset root mounted as /data." >&2
  exit 1
fi

if [[ "${DO_BUILD}" == "true" ]]; then
  env ROS_DISTRO="${ROS_DISTRO}" docker compose -f "${COMPOSE_FILE}" build adaptive_lio
fi

if [[ "${RVIZ}" == "true" && "${DO_XHOST}" == "true" ]]; then
  if command -v xhost >/dev/null 2>&1 && [[ -n "${DISPLAY:-}" ]]; then
    xhost +si:localuser:root >/dev/null
  else
    echo "[warn] RViz requested but xhost or DISPLAY is unavailable. Continuing."
  fi
fi

LOG_DIR_ABS="$(to_abs_host_path "${LOG_DIR}")"
if [[ ! -d "${LOG_DIR_ABS}" ]]; then
  if ! mkdir -p "${LOG_DIR_ABS}" >/dev/null 2>&1; then
    echo "cannot create log dir: ${LOG_DIR_ABS}" >&2
    exit 1
  fi
fi

CONFIG_HOST_PATH="$(to_abs_host_path "${CONFIG_FILE}")"
if [[ "${CONFIG_FILE}" == /root/adaptive_lio_ws/src/adaptive_lio/* || "${CONFIG_FILE}" == /data/* ]]; then
  CONFIG_HOST_PATH="${CONFIG_FILE}"
fi
CONFIG_CONTAINER_PATH="$(to_container_config_path "${CONFIG_HOST_PATH}")"

declare -a BAG_INPUTS=()
if [[ -n "${BAG_PATH}" ]]; then
  if [[ "${BAG_PATH}" == /* ]]; then
    BAG_INPUTS+=("${BAG_PATH}")
  else
    BAG_INPUTS+=("${REPO_ROOT}/${BAG_PATH}")
  fi
else
  BAG_LIST_PATH="$(to_abs_host_path "${BAG_LIST}")"
  if [[ ! -f "${BAG_LIST_PATH}" ]]; then
    echo "bag list file not found: ${BAG_LIST_PATH}" >&2
    exit 1
  fi
  BAG_LIST_DIR="$(cd -- "$(dirname -- "${BAG_LIST_PATH}")" && pwd)"
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line="$(trim_line "${raw_line}")"
    if [[ -z "${line}" ]]; then
      continue
    fi
    if [[ "${line}" == /* ]]; then
      BAG_INPUTS+=("${line}")
    else
      BAG_INPUTS+=("${BAG_LIST_DIR}/${line}")
    fi
  done < "${BAG_LIST_PATH}"
fi

if [[ ${#BAG_INPUTS[@]} -eq 0 ]]; then
  echo "no bag entries found" >&2
  exit 1
fi

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG_DIR="${LOG_DIR_ABS}/${RUN_STAMP}"

echo "[run] ROS_DISTRO=${ROS_DISTRO}"
echo "[run] DATA_MOUNT=${DATA_MOUNT} -> /data"
echo "[run] config_file=${CONFIG_CONTAINER_PATH}"
echo "[run] total_bags=${#BAG_INPUTS[@]}"
echo "[run] logs=${RUN_LOG_DIR}"

trap handle_interrupt INT TERM

declare -i success_count=0
declare -i fail_count=0
declare -a failed_items=()

for bag_host_path in "${BAG_INPUTS[@]}"; do
  if [[ "${STOP_REQUESTED}" -eq 1 ]]; then
    break
  fi

  bag_container_path="$(to_container_bag_path "${bag_host_path}")"
  bag_name="$(sanitize_name "${bag_host_path}")"
  csv_name="${bag_name}_trajectory.csv"
  csv_host_path="${RUN_LOG_DIR}/${csv_name}"
  csv_container="/logs/${RUN_STAMP}/${csv_name}"
  extra_mount_args=()

  if [[ "${bag_container_path}" != /data/* && "${bag_container_path}" != "/data" ]]; then
    if [[ "${bag_host_path}" == /* && -e "${bag_host_path}" ]]; then
      bag_parent_dir="$(dirname -- "${bag_host_path}")"
      bag_basename="$(basename -- "${bag_host_path}")"
      bag_container_path="/input_bag/${bag_basename}"
      extra_mount_args=(-v "${bag_parent_dir}:/input_bag:ro")
    fi
  fi

  echo "[run] bag=${bag_container_path}"
  echo "[run] csv=${csv_host_path}"

  inner_args=(
    "${INNER_SCRIPT}"
    --bag-path "${bag_container_path}"
    --config-file "${CONFIG_CONTAINER_PATH}"
    --rate "${RATE_MODE}"
    --queue-size "${QUEUE_SIZE}"
    --rviz "${RVIZ}"
    --log-csv "${csv_container}"
  )
  if [[ "${ALL_TOPICS}" == "true" ]]; then
    inner_args+=(--all-topics)
  fi
  if [[ -n "${IMU_TOPIC_OVERRIDE}" ]]; then
    inner_args+=(--imu-topic "${IMU_TOPIC_OVERRIDE}")
  fi
  if [[ -n "${LIDAR_TOPIC_OVERRIDE}" ]]; then
    inner_args+=(--lidar-topic "${LIDAR_TOPIC_OVERRIDE}")
  fi

  printf -v inner_cmd '%q ' "${inner_args[@]}"

  set +e
  env ROS_DISTRO="${ROS_DISTRO}" docker compose -f "${COMPOSE_FILE}" run --rm \
    -e USE_TMUX=0 \
    -e FORCE_REBUILD=1 \
    -v "${DATA_MOUNT%/}:/data" \
    -v "${LOG_DIR_ABS}:/logs" \
    "${extra_mount_args[@]}" \
    adaptive_lio \
    bash -lc "${inner_cmd}" &
  CURRENT_DOCKER_PID=$!
  wait "${CURRENT_DOCKER_PID}"
  bag_status=$?
  CURRENT_DOCKER_PID=""
  set -e

  if [[ "${STOP_REQUESTED}" -eq 1 || ${bag_status} -eq 130 || ${bag_status} -eq 143 ]]; then
    STOP_REQUESTED=1
    echo "[run] interrupted: ${bag_container_path}" >&2
    break
  fi

  if [[ ${bag_status} -eq 0 ]]; then
    success_count+=1
    echo "[run] csv saved: ${csv_host_path}"
  else
    fail_count+=1
    failed_items+=("${bag_container_path}")
    echo "[run] bag failed (exit=${bag_status}): ${bag_container_path}" >&2
  fi
done

trap - INT TERM

if [[ "${STOP_REQUESTED}" -eq 1 ]]; then
  echo "[summary] interrupted by user"
  echo "[summary] success=${success_count} fail=${fail_count}"
  exit 130
fi

echo "[summary] success=${success_count} fail=${fail_count}"
if [[ ${fail_count} -gt 0 ]]; then
  for item in "${failed_items[@]}"; do
    echo "[summary] failed=${item}"
  done
  exit 1
fi
