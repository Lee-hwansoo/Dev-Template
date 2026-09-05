#!/usr/bin/env python3
"""
Starter test for DevKit — the counterpart of starter_node.py.

Runs under `mtest` (pure Python / CMake workspaces, via pytest) and under
`colcon test` in a ROS 2 ament_python package, which invokes pytest itself.
Keep it, replace it, or delete it: `mtest` reports an empty suite as a note
rather than a failure.
"""

import subprocess
import sys
from functools import lru_cache
from pathlib import Path

NODE = Path(__file__).with_name("starter_node.py")


@lru_cache(maxsize=1)
def run_node():
    """One launch, shared by both assertions — importing rclpy is not cheap."""
    return subprocess.run(
        [sys.executable, str(NODE)], capture_output=True, text=True, timeout=60, check=False
    )


def test_starter_node_runs():
    """The starter node must exit cleanly with or without a ROS installation."""
    result = run_node()
    assert result.returncode == 0, result.stderr
    assert "Starter Node Initialized" in result.stdout


def test_starter_node_reports_its_mode():
    """Whichever subsystem is active, the node must say which one it is."""
    assert "ROS 2 Subsystem:" in run_node().stdout
