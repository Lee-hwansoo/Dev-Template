# 🎭 Package Overlay

This directory is designated for overriding (overlaying) configurations and files of external ROS packages downloaded via `vcstool`.

It is particularly useful for resolving build order issues or excluding specific sub-packages from the build process without modifying the original source repositories.

## Usage

Place files inside the `dependencies/overlay/` directory, **mimicking the exact directory structure of the cloned package**.

When you run the `sync_deps` command from the container's terminal:
1. `vcs import` completes the initial download of external repositories.
2. The contents of this folder are then automatically copied into the `src/` path, recursively overwriting the original files.

### Example 1: Modifying Build Order (Overwriting `package.xml`)

If you need to adjust the build sequence by adding specific `<depend>` tags to an external package's `package.xml`:

1. Prepare the modified file at `dependencies/overlay/<repository_name>/package.xml`.
2. Run `sync_deps`. The original `package.xml` will be replaced by your overlay file.

### Example 2: Excluding Specific Directories (`COLCON_IGNORE`, `CATKIN_IGNORE`)

To reduce build time or avoid dependency errors by excluding unnecessary examples or sub-packages from an external repository:

1. Create an empty `COLCON_IGNORE` (or `CATKIN_IGNORE`) file at `dependencies/overlay/<repository_name>/<target_subpackage>/COLCON_IGNORE`.
2. The compiler will ignore the specified directory and skip the build for that sub-package.
