# OAK-D Stereo & IMU Calibration with Docker (ROS 2 + Kalibr)

This guide documents a workflow to extract raw, uncompressed stereo and RGB streams from an OAK-D camera in a ROS 2 (Humble) environment, and calibrate the camera intrinsics, extrinsics, and IMU using the Kalibr tool (ROS 1).

## Why ROS 2?
The ROS 1 Noetic driver (`luxonis/depthai-ros:noetic-latest`) has known memory leak issues that cause 30GB+ instant memory consumption and crashes. The ROS 2 Humble driver is stable and recommended for raw data extraction.

---

## 1. Quickstart: ROS 2 Recording

By default, the `depthai_ros_driver` uses an `RGBD` pipeline and runs Neural Networks, which blocks the raw `/left` and `/right` streams required for calibration.

### Step 1: Create Parameter File
Create a YAML file (e.g., `ros2_oakd_params.yaml`) to override the default pipeline:
```yaml
/oak:
  ros__parameters:
    camera:
      i_nn_type: "none"
      i_pipeline_type: "RGBStereo"
    left:
      i_publish_topic: true
    right:
      i_publish_topic: true
    rgb:
      i_publish_topic: true
```

### Step 2: Launch Camera Node
Launch the driver with your parameter file and explicitly enable infra cameras:
```bash
ros2 launch depthai_ros_driver camera.launch.py \
  params_file:=/path/to/your/ros2_oakd_params.yaml \
  enable_infra1:=true \
  enable_infra2:=true \
  enable_depth:=false
```

### Step 3: Record Calibration Data
Verify the topics (`ros2 topic list`) and record the raw stereo and IMU streams:
```bash
ros2 bag record -o oak_imu_calib \
  /oak/left/image_raw \
  /oak/right/image_raw \
  /oak/rgb/image_raw \
  /oak/imu/data
```

**Recording tips:**
* Move the camera or target **slowly and smoothly** to prevent motion blur.
* Ensure the target is captured in all four corners of the camera's field of view.
* Tilt the target at various angles (pitch, yaw, roll).
* Record for approximately 60-90 seconds.

### Step 4: Convert Bag to ROS 1 Format
Kalibr requires the ROS 1 bag format. Convert the ROS 2 bag on your host machine:
```bash
# Install conversion tool if needed
pip install -r requirements.txt

# Convert ROS 2 directory to a ROS 1 .bag file
rosbags-convert --src oak_imu_calib --dst oak_calib_ros1.bag
```

---

## 2. Kalibr Configuration Files

Prepare your calibration data folder on the host and move the converted `.bag` file there:
```bash
mkdir -p "/home/$USER/oakd_kalibr_data"
```

Place the following configuration files inside `/home/$USER/oakd_kalibr_data`:

### Target Definition (`aprilgrid.yaml`)
> **WARNING:** `tagSize` must be in METERS. `tagSpacing` is a RATIO (spacing width / tag width), not a measurement in meters.
```yaml
target_type: 'aprilgrid'
tagCols: 6
tagRows: 6
tagSize: 0.025      # Example: 2.5 cm expressed in meters
tagSpacing: 0.28    # Example: 0.7 cm / 2.5 cm = 0.28
```

### IMU Definition (`imu.yaml`)
Required for IMU calibration only.
```yaml
rostopic: /oak/imu/data
update_rate: 200.0
accelerometer_noise_density: 1.6e-3 
accelerometer_random_walk: 5.0e-5
gyroscope_noise_density: 1.2e-4
gyroscope_random_walk: 4.0e-6
```

---

## 3. Running Kalibr Calibration

### Step 3.1: Build Image & Start Docker with X11
From the repository root, build the Kalibr image:
```bash
docker build -t kalibr:oakd -f Dockerfile_ros1_20_04 .
```

Allow Docker to access your X11 server for visual debugging (`--show-extraction`):
```bash
xhost +local:docker
```

Run the container (mounting your data folder to `/data` inside the container):
```bash
docker run -it --rm \
  -v "/home/$USER/oakd_kalibr_data:/data" \
  -v "/tmp/.X11-unix:/tmp/.X11-unix" \
  -e DISPLAY=$DISPLAY \
  kalibr:oakd bash
```

Inside the container, initialize the workspace:
```bash
source /catkin_ws/devel/setup.bash
```

### Step 3.2: Camera Calibration (Left, Right, RGB)
Run the calibration algorithm. We use `--approx-focal 850` to assist the PnP initialization and `--sample-rate 4` to prevent massive memory usage on dense 30fps bags.
```bash
rosrun kalibr kalibr_calibrate_cameras \
  --bag /data/oak_calib_ros1.bag \
  --target /data/aprilgrid.yaml \
  --models pinhole-radtan pinhole-radtan pinhole-radtan \
  --topics /oak/left/image_raw /oak/right/image_raw /oak/rgb/image_raw \
  --approx-focal 850 \
  --show-extraction \
  --sample-rate 4
```

### Step 3.3: IMU-Camera Calibration
This step requires the `camchain.yaml` file generated in the previous step.
```bash
rosrun kalibr kalibr_calibrate_imu_camera \
  --bag /data/oak_calib_ros1.bag \
  --target /data/aprilgrid.yaml \
  --cam /data/camchain-oak_calib_ros1.yaml \
  --imu /data/imu.yaml \
  --show-extraction
```

---

## 4. Data Quality Checklist & Common Pitfalls

* **Use `image_raw` topics:** Do not use compressed or rectified streams.
* **Target Size Units:** `tagSize` must be in meters (e.g., 0.025 for 2.5 cm).
* **Spacing Ratio:** `tagSpacing` is a ratio (e.g., 0.28), not a measurement in meters.
* **Stereo Overlap:** Ensure the target is visible in ALL cameras simultaneously.
* **IMU Excitation:** For IMU calibration, keep the target completely still, and move the CAMERA in 6 Degrees of Freedom (6 DoF).
* **Lighting:** Minimize motion blur by ensuring the environment is brightly lit.
* **Initialization Fails:** If `cam1` or `cam2` gets very few extracted corners, check for motion blur or incorrect target dimensions in YAML. Use `--approx-focal` to force initialization.
```
