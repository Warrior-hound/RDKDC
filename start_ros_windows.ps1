# Student-facing start script for the RDKDC ROS 2 Jazzy Docker environment.
param(
    [switch]$Rebuild,
    [switch]$SkipMatlabTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ImageName = "ros2-jazzy-vnc"
$ContainerName = "rdkdc_ros2_jazzy"
$HostAddress = "127.0.0.1"
$VncPort = 6080
$VncNativePort = 5901
$BridgePort = 8765
$DiscoveryPort = 11811
$Workspace = Join-Path $HOME "ros2_ws"
$WorkspaceSrc = Join-Path $Workspace "src"
$BridgeDir = Join-Path $Workspace "rdkdc_bridge"
$MatlabDir = Join-Path $Workspace "matlab"
$SetupPkgDir = Join-Path $WorkspaceSrc "rdkdc_setup"
$VncUrl = "http://${HostAddress}:${VncPort}/vnc.html?autoconnect=true&resize=scale&quality=9&compression=0"
$BridgeUrl = "http://${HostAddress}:${BridgePort}"

function Resolve-Docker {
    $DockerCommand = Get-Command docker -ErrorAction SilentlyContinue
    if ($DockerCommand) {
        return $DockerCommand.Source
    }

    $DockerDesktopPath = Join-Path $env:ProgramFiles "Docker\Docker\resources\bin\docker.exe"
    if (Test-Path $DockerDesktopPath) {
        return $DockerDesktopPath
    }

    throw "Docker was not found. Install Docker Desktop for Windows, start it, then reopen PowerShell."
}

function Resolve-Matlab {
    $MatlabCommand = Get-Command matlab -ErrorAction SilentlyContinue
    if ($MatlabCommand) {
        return $MatlabCommand.Source
    }

    $Candidates = Get-ChildItem "C:\Program Files\MATLAB" -Directory -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending |
        ForEach-Object { Join-Path $_.FullName "bin\matlab.exe" }

    foreach ($Candidate in $Candidates) {
        if (Test-Path $Candidate) {
            return $Candidate
        }
    }

    return $null
}

function Get-DockerPlatform {
    $Arch = if ($env:PROCESSOR_ARCHITEW6432) {
        $env:PROCESSOR_ARCHITEW6432
    }
    else {
        $env:PROCESSOR_ARCHITECTURE
    }

    switch ($Arch) {
        "ARM64" { return "linux/arm64" }
        "AMD64" { return "linux/amd64" }
        default { throw "Unsupported Windows architecture: $Arch" }
    }
}

function Test-HttpReady {
    param(
        [string]$Uri,
        [int]$TimeoutSeconds = 90
    )

    $Deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        try {
            Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 2 | Out-Null
            return $true
        }
        catch {
            Start-Sleep -Seconds 1
        }
    } until ((Get-Date) -gt $Deadline)

    return $false
}

function Write-BridgeFiles {
    New-Item -ItemType Directory -Force -Path $BridgeDir, $MatlabDir, $WorkspaceSrc | Out-Null

    $BridgePy = @'
#!/usr/bin/env python3
import json
import math
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import rclpy
from builtin_interfaces.msg import Duration
from geometry_msgs.msg import TransformStamped
from rclpy.node import Node
from sensor_msgs.msg import JointState
from trajectory_msgs.msg import JointTrajectory, JointTrajectoryPoint

try:
    import tf2_ros
except Exception:
    tf2_ros = None


JOINT_NAMES = [
    "shoulder_pan_joint",
    "shoulder_lift_joint",
    "elbow_joint",
    "wrist_1_joint",
    "wrist_2_joint",
    "wrist_3_joint",
]


def duration_from_seconds(seconds):
    whole = int(math.floor(float(seconds)))
    frac = float(seconds) - whole
    msg = Duration()
    msg.sec = whole
    msg.nanosec = int(round(frac * 1_000_000_000))
    return msg


class RdkdcBridge(Node):
    def __init__(self):
        super().__init__("rdkdc_http_bridge")
        self.joint_state = None
        self.joint_state_lock = threading.Lock()
        self.create_subscription(JointState, "/joint_states", self._joint_state_cb, 10)
        self.trajectory_pub = self.create_publisher(JointTrajectory, "rdkdc/joint_pos_msg", 10)
        self.scaled_trajectory_pub = self.create_publisher(
            JointTrajectory,
            "/scaled_joint_trajectory_controller/joint_trajectory",
            10,
        )
        self.tf_pub = self.create_publisher(TransformStamped, "rdkdc/tf_msg", 10)
        self.tf_buffer = None
        self.tf_listener = None
        if tf2_ros is not None:
            self.tf_buffer = tf2_ros.Buffer()
            self.tf_listener = tf2_ros.TransformListener(self.tf_buffer, self)

    def _joint_state_cb(self, msg):
        with self.joint_state_lock:
            self.joint_state = {
                "name": list(msg.name),
                "position": list(msg.position),
                "velocity": list(msg.velocity),
                "effort": list(msg.effort),
                "stamp": {
                    "sec": int(msg.header.stamp.sec),
                    "nanosec": int(msg.header.stamp.nanosec),
                },
            }

    def current_joint_state(self):
        with self.joint_state_lock:
            return self.joint_state

    def move_joints(self, payload):
        positions = payload.get("positions")
        if positions is None:
            raise ValueError("JSON body must include positions")

        if positions and not isinstance(positions[0], list):
            positions = [positions]

        time_interval = payload.get("time_interval", payload.get("time", 5.0))
        if isinstance(time_interval, list):
            times = [float(x) for x in time_interval]
        else:
            times = [float(time_interval)] * len(positions)

        if len(times) != len(positions):
            raise ValueError("time_interval must be scalar or match number of waypoints")

        msg = JointTrajectory()
        msg.joint_names = payload.get("joint_names", JOINT_NAMES)

        elapsed = 0.0
        for waypoint, dt in zip(positions, times):
            if len(waypoint) != 6:
                raise ValueError("each waypoint must contain 6 joint values")
            elapsed += dt
            point = JointTrajectoryPoint()
            point.positions = [float(x) for x in waypoint]
            point.velocities = [0.0] * 6
            point.accelerations = [0.0] * 6
            point.time_from_start = duration_from_seconds(elapsed)
            msg.points.append(point)

        self.trajectory_pub.publish(msg)
        self.scaled_trajectory_pub.publish(msg)
        return {
            "ok": True,
            "waypoints": len(msg.points),
            "topics": [
                "rdkdc/joint_pos_msg",
                "/scaled_joint_trajectory_controller/joint_trajectory",
            ],
        }

    def publish_frame(self, payload):
        msg = TransformStamped()
        msg.header.stamp = self.get_clock().now().to_msg()
        msg.header.frame_id = str(payload["base_frame"])
        msg.child_frame_id = str(payload["frame"])
        translation = payload.get("translation", [0, 0, 0])
        rotation = payload.get("rotation_quat_wxyz", [1, 0, 0, 0])
        msg.transform.translation.x = float(translation[0])
        msg.transform.translation.y = float(translation[1])
        msg.transform.translation.z = float(translation[2])
        msg.transform.rotation.w = float(rotation[0])
        msg.transform.rotation.x = float(rotation[1])
        msg.transform.rotation.y = float(rotation[2])
        msg.transform.rotation.z = float(rotation[3])
        self.tf_pub.publish(msg)
        return {"ok": True, "topic": "rdkdc/tf_msg"}

    def lookup_transform(self, target, source):
        if self.tf_buffer is None:
            raise RuntimeError("tf2_ros is not available in this container")
        transform = self.tf_buffer.lookup_transform(target, source, rclpy.time.Time())
        t = transform.transform.translation
        q = transform.transform.rotation
        return {
            "translation": [t.x, t.y, t.z],
            "rotation_quat_wxyz": [q.w, q.x, q.y, q.z],
        }


bridge = None


class Handler(BaseHTTPRequestHandler):
    def _send(self, status, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_json(self):
        length = int(self.headers.get("Content-Length", "0"))
        if length <= 0:
            return {}
        return json.loads(self.rfile.read(length).decode("utf-8"))

    def log_message(self, fmt, *args):
        return

    def do_GET(self):
        try:
            parsed = urlparse(self.path)
            if parsed.path == "/health":
                self._send(200, {"ok": True, "node": bridge.get_name(), "time": time.time()})
            elif parsed.path == "/joint_states":
                state = bridge.current_joint_state()
                if state is None:
                    self._send(503, {"ok": False, "error": "No /joint_states message received yet"})
                else:
                    state["ok"] = True
                    self._send(200, state)
            elif parsed.path == "/transform":
                query = parse_qs(parsed.query)
                target = query.get("target", [None])[0]
                source = query.get("source", [None])[0]
                if not target or not source:
                    self._send(400, {"ok": False, "error": "target and source query parameters are required"})
                else:
                    result = bridge.lookup_transform(target, source)
                    result["ok"] = True
                    self._send(200, result)
            else:
                self._send(404, {"ok": False, "error": "unknown endpoint"})
        except Exception as exc:
            self._send(500, {"ok": False, "error": str(exc)})

    def do_POST(self):
        try:
            if self.path == "/move_joints":
                self._send(200, bridge.move_joints(self._read_json()))
            elif self.path == "/frame":
                self._send(200, bridge.publish_frame(self._read_json()))
            else:
                self._send(404, {"ok": False, "error": "unknown endpoint"})
        except Exception as exc:
            self._send(400, {"ok": False, "error": str(exc)})


def main():
    global bridge
    rclpy.init()
    bridge = RdkdcBridge()
    spin_thread = threading.Thread(target=rclpy.spin, args=(bridge,), daemon=True)
    spin_thread.start()
    server = ThreadingHTTPServer(("0.0.0.0", 8765), Handler)
    bridge.get_logger().info("RDKDC HTTP bridge listening on 0.0.0.0:8765")
    try:
        server.serve_forever()
    finally:
        server.shutdown()
        bridge.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    main()
'@

    $Ur5Interface = @'
classdef ur5_interface < handle
    properties (SetAccess = immutable)
        speed_limit = 0.25
        home = [0 -pi 0 -pi 0 0]'/2
        joint_names = { ...
            'shoulder_pan_joint', ...
            'shoulder_lift_joint', ...
            'elbow_joint', ...
            'wrist_1_joint', ...
            'wrist_2_joint', ...
            'wrist_3_joint'}
    end

    properties (SetAccess = private)
        bridge_url
    end

    methods
        function self = ur5_interface()
            self.bridge_url = getenv("RDKDC_BRIDGE_URL");
            if strlength(self.bridge_url) == 0
                self.bridge_url = "http://127.0.0.1:8765";
            end
            webread(self.bridge_url + "/health", weboptions("Timeout", 5));
        end

        function joint_angles = get_current_joints(self)
            data = webread(self.bridge_url + "/joint_states", weboptions("Timeout", 10));
            joint_angles = zeros(6,1);
            for i = 1:numel(data.name)
                for j = 1:6
                    if strcmp(data.name{i}, self.joint_names{j})
                        joint_angles(j) = data.position(i);
                    end
                end
            end
        end

        function move_joints(self, joint_goal, time_interval)
            validateattributes(joint_goal, {'numeric'}, {'nrows',6,'2d'})
            validateattributes(time_interval, {'numeric'}, {'nonnegative','nonzero'})

            payload = struct();
            payload.positions = joint_goal';
            payload.time_interval = time_interval;
            payload.joint_names = self.joint_names;

            opts = weboptions("MediaType", "application/json", "Timeout", 10);
            webwrite(self.bridge_url + "/move_joints", payload, opts);
        end

        function g = get_current_transformation(self, target, source)
            url = self.bridge_url + "/transform?target=" + string(target) + "&source=" + string(source);
            data = webread(url, weboptions("Timeout", 10));
            R = quat2rotm(data.rotation_quat_wxyz);
            t = data.translation(:);
            g = [R t; 0 0 0 1];
        end
    end
end
'@

    $TfFrame = @'
classdef tf_frame < handle
    properties (SetAccess = protected)
        frame_name
        base_frame_name
        pose
    end

    properties (SetAccess = private)
        bridge_url
    end

    methods
        function self = tf_frame(base_frame_name, frame_name, g)
            self.bridge_url = getenv("RDKDC_BRIDGE_URL");
            if strlength(self.bridge_url) == 0
                self.bridge_url = "http://127.0.0.1:8765";
            end
            self.frame_name = frame_name;
            self.base_frame_name = base_frame_name;
            self.pose = g;
            self.move_frame(base_frame_name, g);
        end

        function move_frame(self, ref_frame_name, g)
            q = rotm2quat(g(1:3,1:3));
            t = g(1:3,4);
            payload = struct();
            payload.base_frame = char(ref_frame_name);
            payload.frame = char(self.frame_name);
            payload.translation = t(:)';
            payload.rotation_quat_wxyz = q;
            opts = weboptions("MediaType", "application/json", "Timeout", 10);
            webwrite(self.bridge_url + "/frame", payload, opts);
        end

        function g = read_frame(self, ref_frame_name)
            url = self.bridge_url + "/transform?target=" + string(ref_frame_name) + "&source=" + string(self.frame_name);
            data = webread(url, weboptions("Timeout", 10));
            R = quat2rotm(data.rotation_quat_wxyz);
            t = data.translation(:);
            g = [R t; 0 0 0 1];
        end

        function disappear(self)
            payload = struct();
            payload.base_frame = "Delete";
            payload.frame = char(self.frame_name);
            payload.translation = [0 0 0];
            payload.rotation_quat_wxyz = [1 0 0 0];
            opts = weboptions("MediaType", "application/json", "Timeout", 10);
            webwrite(self.bridge_url + "/frame", payload, opts);
        end
    end
end
'@

    Set-Content -Path (Join-Path $BridgeDir "rdkdc_http_bridge.py") -Value $BridgePy -Encoding UTF8
    Set-Content -Path (Join-Path $MatlabDir "ur5_interface.m") -Value $Ur5Interface -Encoding UTF8
    $Ur5eInterface = $Ur5Interface.Replace("classdef ur5_interface", "classdef ur5e_interface").Replace("function self = ur5_interface()", "function self = ur5e_interface()")
    Set-Content -Path (Join-Path $MatlabDir "ur5e_interface.m") -Value $Ur5eInterface -Encoding UTF8
    Set-Content -Path (Join-Path $MatlabDir "tf_frame.m") -Value $TfFrame -Encoding UTF8
}

function Write-LaunchPackage {
    $LaunchDir = Join-Path $SetupPkgDir "launch"
    $RvizDir = Join-Path $SetupPkgDir "rviz"
    $ResourceDir = Join-Path $SetupPkgDir "resource"
    $PythonDir = Join-Path $SetupPkgDir "rdkdc_setup"
    New-Item -ItemType Directory -Force -Path $LaunchDir, $RvizDir, $ResourceDir, $PythonDir | Out-Null

    $PackageXml = @'
<?xml version="1.0"?>
<package format="3">
  <name>rdkdc_setup</name>
  <version>0.0.1</version>
  <description>RDKDC Docker launch helpers for ROS 2 Jazzy.</description>
  <maintainer email="rdkdc@example.com">RDKDC Course Staff</maintainer>
  <license>BSD-3-Clause</license>

  <buildtool_depend>ament_python</buildtool_depend>

  <exec_depend>launch</exec_depend>
  <exec_depend>launch_ros</exec_depend>
  <exec_depend>ur_simulation_gz</exec_depend>
  <exec_depend>ur_description</exec_depend>
  <exec_depend>controller_manager</exec_depend>
  <exec_depend>rviz2</exec_depend>

  <export>
    <build_type>ament_python</build_type>
  </export>
</package>
'@

    $SetupPy = @'
from glob import glob
from setuptools import setup

package_name = "rdkdc_setup"

setup(
    name=package_name,
    version="0.0.1",
    packages=[package_name],
    data_files=[
        ("share/ament_index/resource_index/packages", ["resource/" + package_name]),
        ("share/" + package_name, ["package.xml"]),
        ("share/" + package_name + "/launch", glob("launch/*.launch.py")),
        ("share/" + package_name + "/rviz", glob("rviz/*.rviz")),
    ],
    install_requires=["setuptools"],
    zip_safe=True,
    maintainer="RDKDC Course Staff",
    maintainer_email="rdkdc@example.com",
    description="RDKDC Docker launch helpers for ROS 2 Jazzy.",
    license="BSD-3-Clause",
)
'@

    $LaunchPy = @'
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess, IncludeLaunchDescription, TimerAction
from launch.conditions import IfCondition
from launch.launch_description_sources import PythonLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration, PathJoinSubstitution
from launch_ros.actions import Node
from launch_ros.substitutions import FindPackageShare


def controller_call(service_name, service_type, request):
    return ExecuteProcess(
        cmd=[
            "bash",
            "-lc",
            (
                "source /opt/ros/jazzy/setup.bash && "
                "ros2 service call "
                + service_name
                + " "
                + service_type
                + " '"
                + request
                + "' || true"
            ),
        ],
        output="screen",
    )


def generate_launch_description():
    ur_type = LaunchConfiguration("ur_type")
    launch_rviz = LaunchConfiguration("launch_rviz")
    gazebo_gui = LaunchConfiguration("gazebo_gui")

    ur_sim = IncludeLaunchDescription(
        PythonLaunchDescriptionSource(
            PathJoinSubstitution(
                [FindPackageShare("ur_simulation_gz"), "launch", "ur_sim_control.launch.py"]
            )
        ),
        launch_arguments={
            "ur_type": ur_type,
            "launch_rviz": "false",
            "gazebo_gui": gazebo_gui,
            "activate_joint_controller": "false",
            "initial_joint_controller": "scaled_joint_trajectory_controller",
        }.items(),
    )

    rviz = Node(
        package="rviz2",
        executable="rviz2",
        name="rviz2",
        arguments=[
            "-d",
            PathJoinSubstitution(
                [FindPackageShare("rdkdc_setup"), "rviz", "ur_frames.rviz"]
            ),
        ],
        output="log",
        condition=IfCondition(launch_rviz),
    )

    activate_controllers = TimerAction(
        period=30.0,
        actions=[
            controller_call(
                "/controller_manager/load_controller",
                "controller_manager_msgs/srv/LoadController",
                "{name: joint_state_broadcaster}",
            ),
            controller_call(
                "/controller_manager/load_controller",
                "controller_manager_msgs/srv/LoadController",
                "{name: scaled_joint_trajectory_controller}",
            ),
            controller_call(
                "/controller_manager/configure_controller",
                "controller_manager_msgs/srv/ConfigureController",
                "{name: joint_state_broadcaster}",
            ),
            controller_call(
                "/controller_manager/configure_controller",
                "controller_manager_msgs/srv/ConfigureController",
                "{name: scaled_joint_trajectory_controller}",
            ),
            controller_call(
                "/controller_manager/switch_controller",
                "controller_manager_msgs/srv/SwitchController",
                "{activate_controllers: [joint_state_broadcaster, scaled_joint_trajectory_controller], deactivate_controllers: [], strictness: 2, activate_asap: true, timeout: {sec: 10, nanosec: 0}}",
            ),
        ],
    )

    start_rviz = TimerAction(period=35.0, actions=[rviz])

    return LaunchDescription(
        [
            DeclareLaunchArgument(
                "ur_type",
                default_value="ur5e",
                choices=["ur5", "ur5e"],
                description="Robot model to simulate.",
            ),
            DeclareLaunchArgument("launch_rviz", default_value="true"),
            DeclareLaunchArgument("gazebo_gui", default_value="false"),
            ur_sim,
            activate_controllers,
            start_rviz,
        ]
    )
'@

    $RvizConfig = @'
Panels:
  - Class: rviz_common/Displays
    Name: Displays
Visualization Manager:
  Class: ""
  Displays:
    - Alpha: 0.5
      Cell Size: 1
      Class: rviz_default_plugins/Grid
      Color: 160; 160; 164
      Enabled: true
      Line Style:
        Line Width: 0.03
        Value: Lines
      Name: Grid
      Plane: XY
      Plane Cell Count: 10
      Reference Frame: <Fixed Frame>
      Value: true
    - Alpha: 1
      Class: rviz_default_plugins/RobotModel
      Collision Enabled: false
      Description Source: Topic
      Description Topic:
        Depth: 5
        Durability Policy: Volatile
        History Policy: Keep Last
        Reliability Policy: Reliable
        Value: /robot_description
      Enabled: true
      Name: RobotModel
      TF Prefix: ""
      Update Interval: 0
      Value: true
      Visual Enabled: true
    - Class: rviz_default_plugins/TF
      Enabled: true
      Frame Timeout: 15
      Frames:
        All Enabled: true
      Marker Scale: 0.35
      Name: TF
      Show Arrows: true
      Show Axes: true
      Show Names: true
      Tree:
        world:
          base_link:
            {}
      Update Interval: 0
      Value: true
  Enabled: true
  Global Options:
    Background Color: 48; 48; 48
    Fixed Frame: base_link
    Frame Rate: 30
  Name: root
  Tools:
    - Class: rviz_default_plugins/Interact
      Hide Inactive Objects: true
    - Class: rviz_default_plugins/MoveCamera
    - Class: rviz_default_plugins/Select
    - Class: rviz_default_plugins/FocusCamera
  Transformation:
    Current:
      Class: rviz_default_plugins/TF
  Value: true
  Views:
    Current:
      Class: rviz_default_plugins/Orbit
      Distance: 3.5
      Focal Point:
        X: -0.05
        Y: -0.07
        Z: 0.5
      Name: Current View
      Pitch: 0.15
      Target Frame: <Fixed Frame>
      Value: Orbit (rviz)
      Yaw: 0.55
Window Geometry:
  Height: 1000
  Width: 1500
'@

    Set-Content -Path (Join-Path $SetupPkgDir "package.xml") -Value $PackageXml -Encoding UTF8
    Set-Content -Path (Join-Path $SetupPkgDir "setup.py") -Value $SetupPy -Encoding UTF8
    Set-Content -Path (Join-Path $ResourceDir "rdkdc_setup") -Value "" -Encoding UTF8
    Set-Content -Path (Join-Path $PythonDir "__init__.py") -Value "" -Encoding UTF8
    Set-Content -Path (Join-Path $LaunchDir "ur5e_sim.launch.py") -Value $LaunchPy -Encoding UTF8
    Set-Content -Path (Join-Path $RvizDir "ur_frames.rviz") -Value $RvizConfig -Encoding UTF8
}

$Docker = Resolve-Docker
$Matlab = Resolve-Matlab
$Platform = Get-DockerPlatform

Write-Host "RDKDC ROS 2 Jazzy Docker/VNC setup"
Write-Host "Docker: $Docker"
Write-Host "Platform: $Platform"
if ($Matlab) {
    Write-Host "MATLAB: $Matlab"
}
else {
    Write-Warning "MATLAB was not found on PATH or under C:\Program Files\MATLAB. Setup will continue without MATLAB smoke test."
    $SkipMatlabTest = $true
}

Write-BridgeFiles
Write-LaunchPackage
Write-Host "Workspace: $Workspace"
Write-Host "Generated MATLAB bridge files: $MatlabDir"
Write-Host "Generated ROS launch package: $SetupPkgDir"

$ImageExists = $false
& $Docker image inspect $ImageName *> $null
if ($LASTEXITCODE -eq 0) {
    $ImageExists = $true
}
if ($Rebuild -or -not $ImageExists) {
    Write-Host "Building Docker image $ImageName..."
    & $Docker build --platform $Platform -t $ImageName .
}
else {
    Write-Host "Docker image $ImageName already exists. Use -Rebuild to force a rebuild."
}

$ExistingContainers = & $Docker ps -a --format "{{.Names}}"
if ($ExistingContainers -contains $ContainerName) {
    Write-Host "Removing existing container $ContainerName..."
    & $Docker rm -f $ContainerName | Out-Null
}

foreach ($LegacyContainer in @("ros2_jazzy_vnc", "ros2_jazzy_discovery_test", "ros2_jazzy_host_test")) {
    if ($ExistingContainers -contains $LegacyContainer) {
        Write-Host "Removing old test/container $LegacyContainer..."
        & $Docker rm -f $LegacyContainer | Out-Null
    }
}

$Width = 1920
$Height = 1080
try {
    Add-Type -AssemblyName System.Windows.Forms
    $WorkingArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $Width = [int]$WorkingArea.Width
    $Height = [Math]::Max(720, [int]$WorkingArea.Height - 140)
}
catch {
    Write-Warning "Could not detect screen size; using ${Width}x${Height}."
}
$VncGeometry = "${Width}x${Height}"

Write-Host "Starting container $ContainerName..."
& $Docker run -d `
    --platform $Platform `
    --name $ContainerName `
    -e "VNC_GEOMETRY=$VncGeometry" `
    -e "ROS_DOMAIN_ID=0" `
    -p "${HostAddress}:${VncPort}:6080" `
    -p "${HostAddress}:${VncNativePort}:5901" `
    -p "${HostAddress}:${BridgePort}:8765" `
    -p "${HostAddress}:${DiscoveryPort}:11811/udp" `
    -v "${Workspace}:/root/ros2_ws" `
    $ImageName | Out-Null

if (-not (Test-HttpReady -Uri "http://${HostAddress}:${VncPort}" -TimeoutSeconds 90)) {
    & $Docker logs --tail 80 $ContainerName
    throw "noVNC did not become ready on $VncUrl"
}

Write-Host "Starting RDKDC HTTP bridge..."
& $Docker exec -d $ContainerName bash -lc "source /opt/ros/jazzy/setup.bash && unset ROS_DISCOVERY_SERVER ROS_SUPER_CLIENT && export ROS_DOMAIN_ID=0 && python3 /root/ros2_ws/rdkdc_bridge/rdkdc_http_bridge.py > /tmp/rdkdc_bridge.log 2>&1"

if (-not (Test-HttpReady -Uri "${BridgeUrl}/health" -TimeoutSeconds 45)) {
    Write-Host "Bridge log:"
    & $Docker exec $ContainerName bash -lc "cat /tmp/rdkdc_bridge.log || true"
    throw "RDKDC HTTP bridge did not become ready on ${BridgeUrl}/health"
}

Write-Host "Building RDKDC launch package in /root/ros2_ws..."
& $Docker exec $ContainerName bash -lc "source /opt/ros/jazzy/setup.bash && cd /root/ros2_ws && colcon build --packages-select rdkdc_setup --symlink-install"

Write-Host "Updating container shell profile..."
& $Docker exec $ContainerName bash -c "grep -q 'rdkdc_setup' /root/.bashrc || printf '\n# RDKDC workspace\nsource /root/ros2_ws/install/setup.bash\nexport DISPLAY=:1\n' >> /root/.bashrc"

[Environment]::SetEnvironmentVariable("RDKDC_BRIDGE_URL", $BridgeUrl, "User")
$env:RDKDC_BRIDGE_URL = $BridgeUrl

if (-not $SkipMatlabTest) {
    Write-Host "Running MATLAB bridge smoke test..."
    & $Matlab -batch "setenv('RDKDC_BRIDGE_URL','$BridgeUrl'); cd('$($MatlabDir.Replace('\','/'))'); addpath(pwd); data=webread('$BridgeUrl/health'); disp(data.ok); u=ur5_interface(); disp('RDKDC MATLAB bridge client OK');"
    if ($LASTEXITCODE -ne 0) {
        throw "MATLAB smoke test failed"
    }
}

Start-Process $VncUrl

Write-Host ""
Write-Host "RDKDC ROS 2 Jazzy desktop is ready."
Write-Host "VNC/RViz desktop: $VncUrl"
Write-Host ""
Write-Host "Inside the Docker/VNC terminal, launch UR5e/RViz with:"
Write-Host "  ros2 launch rdkdc_setup ur5e_sim.launch.py ur_type:=ur5e"
Write-Host ""
Write-Host "To stop:"
Write-Host "  .\stop_ros_windows.ps1"
