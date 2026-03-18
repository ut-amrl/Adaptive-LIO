#!/usr/bin/env bash
set -euo pipefail

print_usage() {
  cat <<'EOF'
Usage:
  scripts/pipeline.sh run [options]
  scripts/pipeline.sh build
  scripts/pipeline.sh help

Environment:
  ROS_DISTRO                 Optional (default: humble; override with ROS_DISTRO=jazzy)
  DATA_MOUNT                 Optional host path mounted to /data when using /data/... bag paths

Run options:
  --bag-path <path>          Single bag directory (host path or /data path)
  --bag-list <txt>           Text file with one bag path per line
  --config-file <path>       Adaptive-LIO config path (default: config/mapping_lonebot.yaml)
  --rate <auto|num>          Bag play rate (default: auto, minimum fixed rate: 0.5)
  --queue-size <int>         ros2 bag read-ahead queue size (default: 5000)
  --rviz <true|false>        Launch rviz2 (default: false)
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

resolve_candidate_path() {
  local input="$1"
  local base_dir="$2"
  if [[ "${input}" == /* ]]; then
    printf '%s\n' "${input}"
  else
    printf '%s/%s\n' "${base_dir}" "${input}"
  fi
}

canonicalize_existing_path() {
  local input="$1"
  local base_dir="$2"
  local candidate
  local resolved_dir

  candidate="$(resolve_candidate_path "${input}" "${base_dir}")"
  resolved_dir="$(cd -- "$(dirname -- "${candidate}")" && pwd -P)" || return 1
  printf '%s/%s\n' "${resolved_dir}" "$(basename -- "${candidate}")"
}

path_is_inside_repo() {
  local path="$1"
  [[ "${path}" == "${REPO_ROOT}" || "${path}" == "${REPO_ROOT}/"* ]]
}

repo_path_to_container() {
  local path="$1"
  if [[ "${path}" == "${REPO_ROOT}" ]]; then
    printf '/root/adaptive_lio_ws/src/adaptive_lio\n'
  else
    printf '/root/adaptive_lio_ws/src/adaptive_lio/%s\n' "${path#"${REPO_ROOT}/"}"
  fi
}

require_data_mount() {
  if [[ -z "${DATA_MOUNT}" ]]; then
    echo "DATA_MOUNT is required when using /data paths." >&2
    exit 1
  fi
  if [[ ! -d "${DATA_MOUNT}" ]]; then
    echo "DATA_MOUNT path not found: ${DATA_MOUNT}" >&2
    exit 1
  fi
}

data_path_to_host_path() {
  local path="$1"
  require_data_mount
  if [[ "${path}" == "/data" ]]; then
    printf '%s\n' "${DATA_MOUNT%/}"
  else
    printf '%s/%s\n' "${DATA_MOUNT%/}" "${path#/data/}"
  fi
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

validate_bool() {
  case "$1" in
    true|false) ;;
    *)
      echo "Expected true or false, got: $1" >&2
      exit 2
      ;;
  esac
}

validate_rate_mode() {
  if [[ "${RATE_MODE}" == "auto" ]]; then
    return 0
  fi

  set +e
  python3 - "${RATE_MODE}" <<'PY'
import sys

try:
    value = float(sys.argv[1])
except ValueError:
    raise SystemExit(1)

if value < 0.5:
    raise SystemExit(2)
PY
  local status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    return 0
  fi

  if [[ "${status}" -eq 2 ]]; then
    echo "Rate must be at least 0.5" >&2
  else
    echo "Rate must be 'auto' or a numeric value" >&2
  fi
  exit 2
}

validate_queue_size() {
  if [[ ! "${QUEUE_SIZE}" =~ ^[0-9]+$ ]] || [[ "${QUEUE_SIZE}" == "0" ]]; then
    echo "Queue size must be a positive integer" >&2
    exit 2
  fi
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

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd -P)"
COMPOSE_FILE="${REPO_ROOT}/docker/compose.yaml"

SUBCOMMAND="${1:-run}"
if [[ $# -gt 0 ]]; then
  shift
fi

DATA_MOUNT="${DATA_MOUNT:-}"
ROS_DISTRO="${ROS_DISTRO:-humble}"

case "${SUBCOMMAND}" in
  help|-h|--help)
    print_usage
    exit 0
    ;;
  build)
    env ROS_DISTRO="${ROS_DISTRO}" docker compose -f "${COMPOSE_FILE}" build adaptive_lio
    exit 0
    ;;
  run)
    ;;
  *)
    echo "Unknown command: ${SUBCOMMAND}" >&2
    print_usage >&2
    exit 2
    ;;
esac

BAG_PATH=""
BAG_LIST=""
CONFIG_FILE="config/mapping_lonebot.yaml"
RATE_MODE="auto"
QUEUE_SIZE="5000"
RVIZ="false"
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

validate_bool "${RVIZ}"
validate_rate_mode
validate_queue_size

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

LOG_DIR_INPUT="$(resolve_candidate_path "${LOG_DIR}" "${REPO_ROOT}")"
mkdir -p "${LOG_DIR_INPUT}"
LOG_DIR_ABS="$(cd -- "${LOG_DIR_INPUT}" && pwd -P)"

CONFIG_CONTAINER_PATH=""
declare -a CONFIG_MOUNT_ARGS=()
USE_DATA_MOUNT="false"
if [[ "${CONFIG_FILE}" == /data/* || "${CONFIG_FILE}" == "/data" ]]; then
  CONFIG_HOST_PATH="$(data_path_to_host_path "${CONFIG_FILE}")"
  if [[ ! -f "${CONFIG_HOST_PATH}" ]]; then
    echo "config file not found: ${CONFIG_HOST_PATH}" >&2
    exit 1
  fi
  CONFIG_CONTAINER_PATH="${CONFIG_FILE}"
  USE_DATA_MOUNT="true"
else
  CONFIG_HOST_PATH="$(canonicalize_existing_path "${CONFIG_FILE}" "${REPO_ROOT}")" || {
    echo "config file not found: ${CONFIG_FILE}" >&2
    exit 1
  }
  if [[ ! -f "${CONFIG_HOST_PATH}" ]]; then
    echo "config file not found: ${CONFIG_HOST_PATH}" >&2
    exit 1
  fi

  if path_is_inside_repo "${CONFIG_HOST_PATH}"; then
    CONFIG_CONTAINER_PATH="$(repo_path_to_container "${CONFIG_HOST_PATH}")"
  else
    CONFIG_CONTAINER_PATH="/input_config/$(basename -- "${CONFIG_HOST_PATH}")"
    CONFIG_MOUNT_ARGS=(-v "$(dirname -- "${CONFIG_HOST_PATH}"):/input_config:ro")
  fi
fi

declare -a BAG_INPUTS=()
if [[ -n "${BAG_PATH}" ]]; then
  if [[ "${BAG_PATH}" == /data/* || "${BAG_PATH}" == "/data" ]]; then
    require_data_mount
    BAG_INPUTS+=("${BAG_PATH}")
  else
    BAG_INPUTS+=("$(resolve_candidate_path "${BAG_PATH}" "${REPO_ROOT}")")
  fi
else
  if [[ "${BAG_LIST}" == /data/* || "${BAG_LIST}" == "/data" ]]; then
    BAG_LIST_PATH="$(data_path_to_host_path "${BAG_LIST}")"
    USE_DATA_MOUNT="true"
  else
    BAG_LIST_PATH="$(canonicalize_existing_path "${BAG_LIST}" "${REPO_ROOT}")" || {
      echo "bag list file not found: ${BAG_LIST}" >&2
      exit 1
    }
  fi

  if [[ ! -f "${BAG_LIST_PATH}" ]]; then
    echo "bag list file not found: ${BAG_LIST_PATH}" >&2
    exit 1
  fi

  BAG_LIST_DIR="$(cd -- "$(dirname -- "${BAG_LIST_PATH}")" && pwd -P)"
  while IFS= read -r raw_line || [[ -n "${raw_line}" ]]; do
    line="$(trim_line "${raw_line}")"
    if [[ -z "${line}" ]]; then
      continue
    fi
    if [[ "${line}" == /data/* || "${line}" == "/data" ]]; then
      require_data_mount
      BAG_INPUTS+=("${line}")
    else
      BAG_INPUTS+=("$(resolve_candidate_path "${line}" "${BAG_LIST_DIR}")")
    fi
  done < "${BAG_LIST_PATH}"
fi

if [[ ${#BAG_INPUTS[@]} -eq 0 ]]; then
  echo "no bag entries found" >&2
  exit 1
fi

RUN_STAMP="$(date +%Y%m%d_%H%M%S)"
RUN_LOG_DIR="${LOG_DIR_ABS}/${RUN_STAMP}"
mkdir -p "${RUN_LOG_DIR}"

read -r -d '' INNER_SCRIPT <<'EOF' || true
set -euo pipefail

log() {
  echo "[pipeline] $*"
}

safe_source() {
  local path="$1"
  if [[ -f "${path}" ]]; then
    set +u
    # shellcheck disable=SC1090
    source "${path}"
    set -u 2>/dev/null || true
  fi
}

stop_process() {
  local pid="${1:-}"
  if [[ -z "${pid}" ]]; then
    return 0
  fi
  if kill -0 "${pid}" >/dev/null 2>&1; then
    kill -INT "${pid}" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      if ! kill -0 "${pid}" >/dev/null 2>&1; then
        break
      fi
      sleep 0.25
    done
    if kill -0 "${pid}" >/dev/null 2>&1; then
      kill -TERM "${pid}" >/dev/null 2>&1 || true
    fi
  fi
  wait "${pid}" >/dev/null 2>&1 || true
}

cleanup_processes() {
  stop_process "${BAG_PID:-}"
  BAG_PID=""
  stop_process "${LOGGER_PID:-}"
  LOGGER_PID=""
  stop_process "${LAUNCH_PID:-}"
  LAUNCH_PID=""
}

handle_interrupt() {
  cleanup_processes
  exit 130
}

wait_for_node() {
  local node_name="$1"
  local timeout_seconds="$2"
  local monitor_pid="${3:-}"
  local elapsed=0

  while (( elapsed < timeout_seconds )); do
    if ros2 node list 2>/dev/null | grep -qx "${node_name}"; then
      return 0
    fi
    if [[ -n "${monitor_pid}" ]] && ! kill -0 "${monitor_pid}" >/dev/null 2>&1; then
      wait "${monitor_pid}" || true
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  return 1
}

csv_has_rows() {
  local csv_path="$1"
  [[ -f "${csv_path}" ]] && [[ "$(wc -l < "${csv_path}")" -gt 1 ]]
}

read_config_topic() {
  local topic_key="$1"
  python3 - "${CONFIG_CONTAINER_PATH}" "${topic_key}" <<'PY'
import sys
import yaml

config_path, topic_key = sys.argv[1], sys.argv[2]
with open(config_path, "r", encoding="utf-8") as fh:
    data = yaml.safe_load(fh) or {}

common = data.get("common") or {}
value = common.get(topic_key)
if value:
    print(value)
    raise SystemExit(0)

root = data.get("/**") or {}
ros_params = root.get("ros__parameters") or {}
common = ros_params.get("common") or {}
value = common.get(topic_key)
if value:
    print(value)
    raise SystemExit(0)

raise SystemExit(1)
PY
}

ensure_bag_readable() {
  local info_output

  set +e
  info_output="$(ros2 bag info "${BAG_PATH_IN_CONTAINER}" 2>&1)"
  local status=$?
  set -e

  if [[ "${status}" -eq 0 ]]; then
    return 0
  fi

  echo "${info_output}" >&2
  if grep -q "yaml-cpp: error" <<<"${info_output}"; then
    echo "Bag metadata is not readable by ROS_DISTRO=${ROS_DISTRO}." >&2
    echo "This bag was likely recorded with a newer rosbag2 metadata schema. Try ROS_DISTRO=jazzy for playback or convert the bag metadata for Humble." >&2
  fi
  return 1
}

run_attempt() {
  local rate="$1"
  local bag_status
  local -a play_cmd=(
    ros2 bag play "${BAG_PATH_IN_CONTAINER}"
    --rate "${rate}"
    --read-ahead-queue-size "${QUEUE_SIZE}"
  )

  cleanup_processes
  rm -f "${LOG_CSV_CONTAINER_PATH}"
  mkdir -p "$(dirname -- "${LOG_CSV_CONTAINER_PATH}")"

  ros2 launch adaptive_lio run.launch.py \
    config_file:="${CONFIG_CONTAINER_PATH}" \
    rviz:="${RVIZ}" \
    play_bag:=false &
  LAUNCH_PID=$!

  if ! wait_for_node "/adaptive_lio" 30 "${LAUNCH_PID}"; then
    echo "adaptive_lio node did not become ready" >&2
    cleanup_processes
    return 1
  fi

  python3 /root/adaptive_lio_ws/src/adaptive_lio/scripts/odom_csv_logger.py \
    --topic /odom \
    --output "${LOG_CSV_CONTAINER_PATH}" &
  LOGGER_PID=$!

  if ! wait_for_node "/odom_csv_logger" 15 "${LOGGER_PID}"; then
    echo "odom_csv_logger node did not become ready" >&2
    cleanup_processes
    return 1
  fi

  if [[ "${ALL_TOPICS}" != "true" ]]; then
    play_cmd+=(--topics "${IMU_TOPIC}" "${LIDAR_TOPIC}")
  fi

  log "playing bag at rate=${rate}"
  set +e
  "${play_cmd[@]}" &
  BAG_PID=$!
  wait "${BAG_PID}"
  bag_status=$?
  BAG_PID=""
  set -e

  sleep 3
  stop_process "${LOGGER_PID:-}"
  LOGGER_PID=""
  stop_process "${LAUNCH_PID:-}"
  LAUNCH_PID=""

  if [[ "${bag_status}" -ne 0 ]]; then
    echo "ros2 bag play failed with exit ${bag_status}" >&2
    return "${bag_status}"
  fi

  if ! csv_has_rows "${LOG_CSV_CONTAINER_PATH}"; then
    echo "No odometry rows were logged to ${LOG_CSV_CONTAINER_PATH}" >&2
    return 10
  fi

  return 0
}

BAG_PID=""
LOGGER_PID=""
LAUNCH_PID=""
ROS_DISTRO="${ROS_DISTRO:-humble}"

trap cleanup_processes EXIT
trap handle_interrupt INT TERM

safe_source "/opt/ros/${ROS_DISTRO}/setup.bash"
safe_source /root/livox_ws/install/setup.bash
safe_source /root/adaptive_lio_ws/install/setup.bash

if [[ -z "${BAG_PATH_IN_CONTAINER:-}" || -z "${CONFIG_CONTAINER_PATH:-}" || -z "${LOG_CSV_CONTAINER_PATH:-}" ]]; then
  echo "BAG_PATH_IN_CONTAINER, CONFIG_CONTAINER_PATH, and LOG_CSV_CONTAINER_PATH are required" >&2
  exit 2
fi

if [[ ! -e "${BAG_PATH_IN_CONTAINER}" ]]; then
  echo "bag path not found: ${BAG_PATH_IN_CONTAINER}" >&2
  exit 1
fi

if [[ ! -f "${CONFIG_CONTAINER_PATH}" ]]; then
  echo "config file not found: ${CONFIG_CONTAINER_PATH}" >&2
  exit 1
fi

ensure_bag_readable

if [[ "${ALL_TOPICS}" != "true" ]]; then
  if [[ -n "${IMU_TOPIC_OVERRIDE:-}" ]]; then
    IMU_TOPIC="${IMU_TOPIC_OVERRIDE}"
  else
    IMU_TOPIC="$(read_config_topic "imu_topic")" || {
      echo "Failed to read common.imu_topic from ${CONFIG_CONTAINER_PATH}" >&2
      exit 1
    }
  fi

  if [[ -n "${LIDAR_TOPIC_OVERRIDE:-}" ]]; then
    LIDAR_TOPIC="${LIDAR_TOPIC_OVERRIDE}"
  else
    LIDAR_TOPIC="$(read_config_topic "lid_topic")" || {
      echo "Failed to read common.lid_topic from ${CONFIG_CONTAINER_PATH}" >&2
      exit 1
    }
  fi
fi

log "ROS_DISTRO=${ROS_DISTRO}"
log "bag_path=${BAG_PATH_IN_CONTAINER}"
log "config_file=${CONFIG_CONTAINER_PATH}"
log "log_csv=${LOG_CSV_CONTAINER_PATH}"
if [[ "${ALL_TOPICS}" == "true" ]]; then
  log "playing all bag topics"
else
  log "imu_topic=${IMU_TOPIC}"
  log "lidar_topic=${LIDAR_TOPIC}"
fi

if [[ "${RATE_MODE}" == "auto" ]]; then
  set +e
  run_attempt "1.0"
  attempt_status=$?
  set -e

  if [[ "${attempt_status}" -eq 0 ]]; then
    exit 0
  fi
  if [[ "${attempt_status}" -ne 10 ]]; then
    exit "${attempt_status}"
  fi

  log "retrying with rate=0.5 after empty odometry log"
  run_attempt "0.5"
  exit $?
fi

run_attempt "${RATE_MODE}"
EOF

echo "[run] ROS_DISTRO=${ROS_DISTRO}"
echo "[run] config_file=${CONFIG_CONTAINER_PATH}"
if [[ "${USE_DATA_MOUNT}" == "true" || -n "${DATA_MOUNT}" ]]; then
  echo "[run] DATA_MOUNT=${DATA_MOUNT:-<unset>}"
fi
echo "[run] total_bags=${#BAG_INPUTS[@]}"
echo "[run] logs=${RUN_LOG_DIR}"

trap handle_interrupt INT TERM

declare -i success_count=0
declare -i fail_count=0
declare -a failed_items=()

for raw_bag_path in "${BAG_INPUTS[@]}"; do
  if [[ "${STOP_REQUESTED}" -eq 1 ]]; then
    break
  fi

  bag_host_path=""
  bag_container_path=""
  declare -a EXTRA_MOUNT_ARGS=()
  run_uses_data_mount="${USE_DATA_MOUNT}"

  if [[ "${raw_bag_path}" == /data/* || "${raw_bag_path}" == "/data" ]]; then
    bag_host_path="$(data_path_to_host_path "${raw_bag_path}")"
    bag_container_path="${raw_bag_path}"
    run_uses_data_mount="true"
  else
    if [[ -e "${raw_bag_path}" ]]; then
      bag_host_path="$(canonicalize_existing_path "${raw_bag_path}" "/")"
    else
      bag_host_path="${raw_bag_path}"
    fi
    if [[ -e "${bag_host_path}" ]]; then
      bag_parent_dir="$(dirname -- "${bag_host_path}")"
      bag_basename="$(basename -- "${bag_host_path}")"
      bag_container_path="/input_bag/${bag_basename}"
      EXTRA_MOUNT_ARGS=(-v "${bag_parent_dir}:/input_bag:ro")
    fi
  fi

  if [[ ! -e "${bag_host_path}" ]]; then
    fail_count+=1
    failed_items+=("${raw_bag_path}")
    echo "[run] bag path not found: ${raw_bag_path}" >&2
    continue
  fi

  bag_name="$(sanitize_name "${bag_host_path}")"
  csv_name="${bag_name}_trajectory.csv"
  csv_host_path="${RUN_LOG_DIR}/${csv_name}"
  csv_container="/logs/${RUN_STAMP}/${csv_name}"

  echo "[run] bag=${bag_container_path}"
  echo "[run] csv=${csv_host_path}"

  docker_args=(
    compose -f "${COMPOSE_FILE}" run --rm
    -e USE_TMUX=0
    -e "BAG_PATH_IN_CONTAINER=${bag_container_path}"
    -e "CONFIG_CONTAINER_PATH=${CONFIG_CONTAINER_PATH}"
    -e "LOG_CSV_CONTAINER_PATH=${csv_container}"
    -e "RATE_MODE=${RATE_MODE}"
    -e "QUEUE_SIZE=${QUEUE_SIZE}"
    -e "RVIZ=${RVIZ}"
    -e "ALL_TOPICS=${ALL_TOPICS}"
    -e "IMU_TOPIC_OVERRIDE=${IMU_TOPIC_OVERRIDE}"
    -e "LIDAR_TOPIC_OVERRIDE=${LIDAR_TOPIC_OVERRIDE}"
    -v "${LOG_DIR_ABS}:/logs"
  )

  if [[ "${run_uses_data_mount}" == "true" ]]; then
    require_data_mount
    docker_args+=(-v "${DATA_MOUNT%/}:/data")
  fi

  if [[ ${#CONFIG_MOUNT_ARGS[@]} -gt 0 ]]; then
    docker_args+=("${CONFIG_MOUNT_ARGS[@]}")
  fi

  if [[ ${#EXTRA_MOUNT_ARGS[@]} -gt 0 ]]; then
    docker_args+=("${EXTRA_MOUNT_ARGS[@]}")
  fi

  docker_args+=(adaptive_lio bash -lc "${INNER_SCRIPT}")

  set +e
  env ROS_DISTRO="${ROS_DISTRO}" docker "${docker_args[@]}" &
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
    failed_items+=("${raw_bag_path}")
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
