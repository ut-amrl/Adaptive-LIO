from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, ExecuteProcess
from launch.conditions import IfCondition
from launch.substitutions import LaunchConfiguration, PythonExpression
from launch_ros.actions import Node
from ament_index_python.packages import get_package_share_directory
import os


def generate_launch_description():
    pkg_share = get_package_share_directory("adaptive_lio")
    default_config = os.path.join(pkg_share, "config", "mapping_m.yaml")
    rviz_config = os.path.join(pkg_share, "launch", "rviz.rviz")

    rviz_arg = DeclareLaunchArgument(
        "rviz",
        default_value="true",
        description="Whether to launch rviz2",
    )
    config_arg = DeclareLaunchArgument(
        "config_file",
        default_value=default_config,
        description="Adaptive-LIO configuration YAML file",
    )
    play_bag_arg = DeclareLaunchArgument(
        "play_bag",
        default_value="false",
        description="Whether to run ros2 bag play in this launch",
    )
    bag_path_arg = DeclareLaunchArgument(
        "bag_path",
        default_value="",
        description="Path to rosbag2 directory used when play_bag:=true",
    )
    bag_rate_arg = DeclareLaunchArgument(
        "bag_rate",
        default_value="1.0",
        description="ros2 bag play rate",
    )
    bag_queue_arg = DeclareLaunchArgument(
        "bag_read_ahead_queue_size",
        default_value="5000",
        description="ros2 bag play read-ahead queue size",
    )
    bag_only_imu_lidar_arg = DeclareLaunchArgument(
        "bag_only_imu_and_lidar",
        default_value="false",
        description="When true, ros2 bag play publishes only IMU and LiDAR topics",
    )
    bag_imu_topic_arg = DeclareLaunchArgument(
        "bag_imu_topic",
        default_value="/lonebot/sensors/microstrain/imu/data",
        description="IMU topic used when bag_only_imu_and_lidar:=true",
    )
    bag_lidar_topic_arg = DeclareLaunchArgument(
        "bag_lidar_topic",
        default_value="/lonebot/sensors/ouster/points",
        description="LiDAR topic used when bag_only_imu_and_lidar:=true",
    )

    adaptive_lio_node = Node(
        package="adaptive_lio",
        executable="adaptive_lio",
        name="adaptive_lio",
        output="screen",
        parameters=[{"config_file": LaunchConfiguration("config_file")}],
    )

    rviz_node = Node(
        package="rviz2",
        executable="rviz2",
        name="adaptive_lio_rviz",
        output="screen",
        arguments=["-d", rviz_config],
        condition=IfCondition(LaunchConfiguration("rviz")),
    )
    bag_play_all_process = ExecuteProcess(
        cmd=[
            "ros2",
            "bag",
            "play",
            LaunchConfiguration("bag_path"),
            "--rate",
            LaunchConfiguration("bag_rate"),
            "--read-ahead-queue-size",
            LaunchConfiguration("bag_read_ahead_queue_size"),
        ],
        output="screen",
        condition=IfCondition(
            PythonExpression(
                [
                    "'",
                    LaunchConfiguration("play_bag"),
                    "' == 'true' and '",
                    LaunchConfiguration("bag_only_imu_and_lidar"),
                    "' != 'true'",
                ]
            )
        ),
    )
    bag_play_imu_lidar_process = ExecuteProcess(
        cmd=[
            "ros2",
            "bag",
            "play",
            LaunchConfiguration("bag_path"),
            "--rate",
            LaunchConfiguration("bag_rate"),
            "--read-ahead-queue-size",
            LaunchConfiguration("bag_read_ahead_queue_size"),
            "--topics",
            LaunchConfiguration("bag_imu_topic"),
            LaunchConfiguration("bag_lidar_topic"),
        ],
        output="screen",
        condition=IfCondition(
            PythonExpression(
                [
                    "'",
                    LaunchConfiguration("play_bag"),
                    "' == 'true' and '",
                    LaunchConfiguration("bag_only_imu_and_lidar"),
                    "' == 'true'",
                ]
            )
        ),
    )

    return LaunchDescription(
        [
            rviz_arg,
            config_arg,
            play_bag_arg,
            bag_path_arg,
            bag_rate_arg,
            bag_queue_arg,
            bag_only_imu_lidar_arg,
            bag_imu_topic_arg,
            bag_lidar_topic_arg,
            adaptive_lio_node,
            rviz_node,
            bag_play_all_process,
            bag_play_imu_lidar_process,
        ]
    )
