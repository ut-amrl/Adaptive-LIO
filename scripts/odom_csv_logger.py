#!/usr/bin/env python3
import argparse
import csv
import os

import rclpy
from nav_msgs.msg import Odometry
from rclpy.executors import ExternalShutdownException
from rclpy.node import Node


class OdomCsvLogger(Node):
    def __init__(self, topic: str, output_path: str) -> None:
        super().__init__("odom_csv_logger")
        self._output_path = output_path
        os.makedirs(os.path.dirname(output_path), exist_ok=True)
        self._file = open(output_path, "w", newline="", encoding="utf-8")
        self._writer = csv.writer(self._file)
        self._writer.writerow(["timestamp", "x", "y", "z", "qx", "qy", "qz", "qw"])
        self._count = 0
        self.create_subscription(Odometry, topic, self._callback, 200)
        self.get_logger().info(f"logging {topic} to {output_path}")

    def _callback(self, msg: Odometry) -> None:
        stamp = float(msg.header.stamp.sec) + float(msg.header.stamp.nanosec) * 1e-9
        pose = msg.pose.pose
        self._writer.writerow(
            [
                f"{stamp:.9f}",
                f"{pose.position.x:.9f}",
                f"{pose.position.y:.9f}",
                f"{pose.position.z:.9f}",
                f"{pose.orientation.x:.9f}",
                f"{pose.orientation.y:.9f}",
                f"{pose.orientation.z:.9f}",
                f"{pose.orientation.w:.9f}",
            ]
        )
        self._count += 1
        if self._count % 100 == 0:
            self._file.flush()

    def close(self) -> None:
        self._file.flush()
        self._file.close()
        self.get_logger().info(f"wrote {self._count} rows to {self._output_path}")


def main() -> None:
    parser = argparse.ArgumentParser(description="Log nav_msgs/Odometry into CSV.")
    parser.add_argument("--topic", default="/odom", help="Odometry topic name.")
    parser.add_argument("--output", required=True, help="CSV output path.")
    args = parser.parse_args()

    rclpy.init()
    node = OdomCsvLogger(args.topic, args.output)
    try:
        rclpy.spin(node)
    except (KeyboardInterrupt, ExternalShutdownException):
        pass
    finally:
        node.close()
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()


if __name__ == "__main__":
    main()
