#!/usr/bin/env python3
"""
Simple ROS 2 / Pure Python starter node for DevKit.
Runs cleanly in ROS 2 (Humble) or fallback pure Python environment.
"""
import sys

def main():
    print("🚀 [DevKit] Starter Node Initialized.")

    # Try importing rclpy if available in ROS 2 mode
    try:
        import rclpy
        from rclpy.node import Node

        rclpy.init()
        node = Node("devkit_starter_node")
        node.get_logger().info("Hello from DevKit ROS 2 Node!")
        print("  - ROS 2 Subsystem: ACTIVE")
        print("  - Node Name: devkit_starter_node")
        rclpy.shutdown()
    except ImportError:
        print("  - ROS 2 Subsystem: Not detected (Running in Pure Python Mode)")
        print(f"  - Python Version: {sys.version.split()[0]}")

if __name__ == "__main__":
    main()
