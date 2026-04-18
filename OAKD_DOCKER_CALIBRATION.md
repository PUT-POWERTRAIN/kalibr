# OAK-D Stereo Calibration with Docker (Record Bag + Run Kalibr)

This guide documents a two-container workflow:
1. Use an OAK-D ROS container to publish camera topics and record a rosbag from hardware.
2. Use this repository Docker image to run Kalibr stereo calibration on that bag.

## Quickstart (automated script)

Use the helper script to automate recording and calibration:

```bash
chmod +x scripts/oakd_kalibr.sh

# 1) Record bag from OAK-D (stop with Ctrl+C)
scripts/oakd_kalibr.sh record \
  --data-dir "$HOME/oakd_kalibr_data" \
  --bag oakd_stereo_kalibr.bag

# 2) Run Kalibr using recorded bag + target yaml
scripts/oakd_kalibr.sh calibrate \
  --data-dir "$HOME/oakd_kalibr_data" \
  --bag oakd_stereo_kalibr.bag \
  --target aprilgrid.yaml
```

Optional one-shot mode (record, then immediately calibrate):

```bash
scripts/oakd_kalibr.sh all \
  --data-dir "$HOME/oakd_kalibr_data" \
  --bag oakd_stereo_kalibr.bag \
  --target aprilgrid.yaml
```

Show script options:

```bash
scripts/oakd_kalibr.sh --help
```

## Assumptions

- Host OS: Ubuntu with Docker installed.
- Camera: OAK-D over USB (PoE users should adapt launch/device configuration).
- Goal: stereo camera calibration only (`left` + `right`), no IMU calibration in this step.
- Shared host folder is used for inputs/outputs (example: `/home/$USER/oakd_kalibr_data`).

## 1) Prepare data folder on host

```bash
mkdir -p "/home/$USER/oakd_kalibr_data"
```

Put your calibration target YAML there (example file: `aprilgrid.yaml`):

```yaml
target_type: 'aprilgrid'
tagCols: 6
tagRows: 6
tagSize: 0.088
tagSpacing: 0.3
```

## 2) Start OAK-D ROS container and publish topics

Run OAK-D driver container:

```bash
docker run --rm -it --name oakd_ros --net=host --privileged \
  -v /dev:/dev \
  -v "/home/$USER/oakd_kalibr_data:/data" \
  luxonis/depthai-ros:noetic-latest bash
```

Inside the container, create a stereo-friendly parameter file (enables left/right mono topics):

```bash
cat > /data/oakd_stereo_params.yaml << 'EOF'
/oak:
  camera_i_nn_type: none
  camera_i_pipeline_type: RGBStereo
  left_i_publish_topic: true
  right_i_publish_topic: true
EOF
```

Then start ROS and launch camera with this config:

```bash
source /opt/ros/noetic/setup.bash
source /ws/devel/setup.bash
roslaunch depthai_ros_driver camera.launch \
  params_file:=/data/oakd_stereo_params.yaml \
  rectify_rgb:=false
```

## 3) Verify raw stereo topics and record bag

Open a second terminal on host and attach to the running container:

```bash
docker exec -it oakd_ros bash
```

Then list topics:

```bash
source /opt/ros/noetic/setup.bash
source /ws/devel/setup.bash
rostopic list
```

Expected topic names for stereo calibration:
- `/oak/left/image_raw`
- `/oak/right/image_raw`
- `/oak/left/camera_info`
- `/oak/right/camera_info`

If these topics are missing, verify runtime params:

```bash
rosparam get /oak/camera_i_pipeline_type
rosparam get /oak/left_i_publish_topic
rosparam get /oak/right_i_publish_topic
```

Record rosbag (replace names if your namespace differs):

```bash
rosbag record -O /data/oakd_stereo_kalibr.bag \
  /oak/left/image_raw \
  /oak/right/image_raw \
  /oak/left/camera_info \
  /oak/right/camera_info
```

Stop recording with `Ctrl+C` after collecting enough data (usually 2-4 minutes with good target coverage).

## 4) Build Kalibr image from this repo

From repository root:

```bash
docker build -t kalibr:oakd -f Dockerfile_ros1_20_04 .
```

## 5) Run Kalibr container and calibrate

Start Kalibr container:

```bash
docker run --rm -it --net=host \
  --entrypoint /bin/bash \
  -e KALIBR_MANUAL_FOCAL_LENGTH_INIT=1 \
  -v "/home/$USER/oakd_kalibr_data:/data" \
  kalibr:oakd
```

Inside container:

```bash
source /catkin_ws/devel/setup.bash
rosrun kalibr kalibr_calibrate_cameras \
  --bag /data/oakd_stereo_kalibr.bag \
  --topics /oak/left/image_raw /oak/right/image_raw \
  --models pinhole-radtan pinhole-radtan \
  --target /data/aprilgrid.yaml \
  --bag-freq 4.0
```

Optional sanity check before calibration:

```bash
rosbag info /data/oakd_stereo_kalibr.bag
```

Outputs are written in `/data`:
- `report-cam-<bagname>.pdf`
- `results-cam-<bagname>.txt`
- `<bagname>-camchain.yaml`

If your bag contains only a wall/desk (no visible calibration target), Kalibr is expected to fail with corner extraction errors. That is still useful to validate Docker, topic wiring, and bag pipeline.

## Data quality checklist (important)

- Use `image_raw` topics (not `image_rect*`, not `compressed`).
- Keep the Aprilgrid visible in both cameras for many frames.
- Move target through center, borders, and corners of the image.
- Vary target distance and orientation (roll/pitch/yaw).
- Ensure good lighting and low motion blur.

## Common pitfalls

- Recording rectified or compressed streams instead of raw images.
- Using mismatched left/right topics or wrong namespace.
- Insufficient overlap/coverage of target in both cameras.
- Motion blur due to fast movement or low light.
- Running calibration on very dense bags without `--bag-freq` (slow runtime).
