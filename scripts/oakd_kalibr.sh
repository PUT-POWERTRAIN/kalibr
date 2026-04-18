#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DEFAULT_DATA_DIR="${REPO_ROOT}/data/oakd_kalibr"
DEFAULT_BAG_NAME="oakd_stereo_kalibr.bag"
DEFAULT_TARGET_NAME="aprilgrid.yaml"
DEFAULT_OAK_IMAGE="luxonis/depthai-ros:noetic-latest"
DEFAULT_KALIBR_IMAGE="kalibr:oakd"
DEFAULT_CONTAINER_NAME="oakd_ros"
DEFAULT_TOPICS="/oak/left/image_raw /oak/right/image_raw"
DEFAULT_MODELS="pinhole-radtan pinhole-radtan"
DEFAULT_BAG_FREQ="4.0"
DEFAULT_DURATION=""
DEFAULT_PIPELINE="RGBStereo"

usage() {
  cat <<'EOF'
Automated OAK-D bag recording + Kalibr stereo calibration.

Usage:
  scripts/oakd_kalibr.sh record [options]
  scripts/oakd_kalibr.sh calibrate [options]
  scripts/oakd_kalibr.sh all [options]
  scripts/oakd_kalibr.sh build-kalibr [options]

Options:
  --data-dir PATH         Shared host folder for bag/yaml/results.
  --bag NAME              Bag filename inside data-dir.
  --target NAME           Target yaml filename inside data-dir.
  --oak-image IMAGE       OAK-D ROS image (default: luxonis/depthai-ros:noetic-latest).
  --kalibr-image IMAGE    Kalibr image tag (default: kalibr:oakd).
  --container-name NAME   OAK-D container name (default: oakd_ros).
  --topics "A B"          Two camera topics for Kalibr.
  --models "A B"          Two camera models for Kalibr.
  --bag-freq HZ           Kalibr bag frequency option (default: 4.0).
  --duration SEC          Recording duration in seconds (record mode).
  --pipeline NAME         depthai pipeline type (default: RGBStereo).
  -h, --help              Show help.

Examples:
  scripts/oakd_kalibr.sh record --data-dir "$HOME/oakd_kalibr_data"
  scripts/oakd_kalibr.sh record --data-dir "$HOME/oakd_kalibr_data" --duration 180
  scripts/oakd_kalibr.sh calibrate --data-dir "$HOME/oakd_kalibr_data" --target aprilgrid.yaml
  scripts/oakd_kalibr.sh all --data-dir "$HOME/oakd_kalibr_data" --target aprilgrid.yaml
EOF
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_data_dir() {
  mkdir -p "$DATA_DIR"
  DATA_DIR="$(cd "$DATA_DIR" && pwd)"
}

ensure_kalibr_image() {
  if ! docker image inspect "$KALIBR_IMAGE" >/dev/null 2>&1; then
    echo "Kalibr image '$KALIBR_IMAGE' not found, building from Dockerfile_ros1_20_04..."
    docker build -t "$KALIBR_IMAGE" -f "${REPO_ROOT}/Dockerfile_ros1_20_04" "$REPO_ROOT"
  fi
}

write_oak_stereo_params() {
  cat > "${DATA_DIR}/oakd_stereo_params.yaml" <<EOF
/oak:
  camera_i_nn_type: none
  camera_i_pipeline_type: ${PIPELINE}
  left_i_publish_topic: true
  right_i_publish_topic: true
EOF
}

remove_container_if_exists() {
  if docker container inspect "$CONTAINER_NAME" >/dev/null 2>&1; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
  fi
}

normalize_bag_name() {
  local bag_path="${DATA_DIR}/${BAG_NAME}"
  if [ -e "$bag_path" ]; then
    local stamp
    stamp="$(date +%Y%m%d_%H%M%S)"
    BAG_NAME="${BAG_NAME%.bag}_${stamp}.bag"
    echo "Bag already exists, using: ${BAG_NAME}"
  fi
}

record_bag() {
  ensure_data_dir
  write_oak_stereo_params
  normalize_bag_name

  echo "Pulling OAK-D image: ${OAK_IMAGE}"
  docker pull "$OAK_IMAGE" >/dev/null
  remove_container_if_exists

  echo "Starting OAK-D launch + rosbag recorder..."
  echo "Data dir: ${DATA_DIR}"
  echo "Bag file: ${BAG_NAME}"
  if [ -n "$DURATION" ]; then
    echo "Recording duration: ${DURATION}s"
  else
    echo "Press Ctrl+C to stop recording."
  fi

  local docker_tty_arg="-i"
  if [ -t 0 ] && [ -t 1 ]; then
    docker_tty_arg="-it"
  fi

  local rc=0
  docker run --rm "$docker_tty_arg" --name "$CONTAINER_NAME" --net=host --privileged \
    -e BAG_NAME="$BAG_NAME" \
    -e BAG_DURATION="$DURATION" \
    -e OAK_PIPELINE="$PIPELINE" \
    -v /dev:/dev \
    -v "${DATA_DIR}:/data" \
    "$OAK_IMAGE" \
    bash -lc '
set -euo pipefail
source /opt/ros/noetic/setup.bash
source /ws/devel/setup.bash

roslaunch depthai_ros_driver camera.launch params_file:=/data/oakd_stereo_params.yaml rectify_rgb:=false >/tmp/oakd_roslaunch.log 2>&1 &
LAUNCH_PID=$!

cleanup() {
  if kill -0 "$LAUNCH_PID" >/dev/null 2>&1; then
    kill "$LAUNCH_PID" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

python3 - <<"PY"
import subprocess
import sys
import time

required = {
    "/oak/left/image_raw",
    "/oak/right/image_raw",
    "/oak/left/camera_info",
    "/oak/right/camera_info",
}
deadline = time.time() + 90.0
last = ""
while time.time() < deadline:
    try:
        out = subprocess.check_output(["rostopic", "list"], text=True, stderr=subprocess.STDOUT)
    except subprocess.CalledProcessError as exc:
        last = exc.output or ""
        time.sleep(1.0)
        continue
    topics = {line.strip() for line in out.splitlines() if line.strip()}
    if required.issubset(topics):
        print("Required stereo topics detected.")
        sys.exit(0)
    last = out
    time.sleep(1.0)

print("Timed out waiting for required stereo topics.", file=sys.stderr)
if last:
    print(last, file=sys.stderr)
try:
    with open("/tmp/oakd_roslaunch.log", "r", encoding="utf-8", errors="ignore") as f:
        log = f.read()
except OSError:
    log = ""
if log:
    print(log, file=sys.stderr)
sys.exit(1)
PY

if [ -n "${BAG_DURATION}" ]; then
  rosbag record --duration="${BAG_DURATION}" -O "/data/${BAG_NAME}" \
    /oak/left/image_raw \
    /oak/right/image_raw \
    /oak/left/camera_info \
    /oak/right/camera_info
else
  rosbag record -O "/data/${BAG_NAME}" \
    /oak/left/image_raw \
    /oak/right/image_raw \
    /oak/left/camera_info \
    /oak/right/camera_info
fi
' || rc=$?

if [ "$rc" -ne 0 ] && [ "$rc" -ne 130 ]; then
    echo "Recording failed (exit code: $rc)" >&2
    exit "$rc"
  fi

  if [ ! -s "${DATA_DIR}/${BAG_NAME}" ]; then
    echo "Bag file is missing or empty: ${DATA_DIR}/${BAG_NAME}" >&2
    exit 1
  fi

  echo "Recorded bag: ${DATA_DIR}/${BAG_NAME}"
}

run_kalibr() {
  ensure_data_dir
  ensure_kalibr_image

  if [ ! -f "${DATA_DIR}/${BAG_NAME}" ]; then
    echo "Bag file not found: ${DATA_DIR}/${BAG_NAME}" >&2
    exit 1
  fi
  if [ ! -f "${DATA_DIR}/${TARGET_NAME}" ]; then
    echo "Target yaml not found: ${DATA_DIR}/${TARGET_NAME}" >&2
    exit 1
  fi

  echo "Running Kalibr stereo calibration..."
  echo "Bag: ${DATA_DIR}/${BAG_NAME}"
  echo "Target: ${DATA_DIR}/${TARGET_NAME}"

  local docker_tty_arg="-i"
  if [ -t 0 ] && [ -t 1 ]; then
    docker_tty_arg="-it"
  fi

  docker run --rm "$docker_tty_arg" --net=host \
    --entrypoint /bin/bash \
    -e KALIBR_MANUAL_FOCAL_LENGTH_INIT=1 \
    -v "${DATA_DIR}:/data" \
    "$KALIBR_IMAGE" \
    -lc "source /catkin_ws/devel/setup.bash && rosrun kalibr kalibr_calibrate_cameras --bag /data/${BAG_NAME} --topics ${TOPICS} --models ${MODELS} --target /data/${TARGET_NAME} --bag-freq ${BAG_FREQ}"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] || [ "${1:-}" = "help" ]; then
  usage
  exit 0
fi

MODE="${1:-}"
if [ -z "$MODE" ]; then
  usage
  exit 1
fi
shift || true

DATA_DIR="$DEFAULT_DATA_DIR"
BAG_NAME="$DEFAULT_BAG_NAME"
TARGET_NAME="$DEFAULT_TARGET_NAME"
OAK_IMAGE="$DEFAULT_OAK_IMAGE"
KALIBR_IMAGE="$DEFAULT_KALIBR_IMAGE"
CONTAINER_NAME="$DEFAULT_CONTAINER_NAME"
TOPICS="$DEFAULT_TOPICS"
MODELS="$DEFAULT_MODELS"
BAG_FREQ="$DEFAULT_BAG_FREQ"
DURATION="$DEFAULT_DURATION"
PIPELINE="$DEFAULT_PIPELINE"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --data-dir)
      DATA_DIR="$2"
      shift 2
      ;;
    --bag)
      BAG_NAME="$2"
      shift 2
      ;;
    --target)
      TARGET_NAME="$2"
      shift 2
      ;;
    --oak-image)
      OAK_IMAGE="$2"
      shift 2
      ;;
    --kalibr-image)
      KALIBR_IMAGE="$2"
      shift 2
      ;;
    --container-name)
      CONTAINER_NAME="$2"
      shift 2
      ;;
    --topics)
      TOPICS="$2"
      shift 2
      ;;
    --models)
      MODELS="$2"
      shift 2
      ;;
    --bag-freq)
      BAG_FREQ="$2"
      shift 2
      ;;
    --duration)
      DURATION="$2"
      shift 2
      ;;
    --pipeline)
      PIPELINE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd docker

case "$MODE" in
  record)
    record_bag
    ;;
  calibrate)
    run_kalibr
    ;;
  all)
    record_bag
    run_kalibr
    ;;
  build-kalibr)
    ensure_kalibr_image
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    usage
    exit 1
    ;;
esac
