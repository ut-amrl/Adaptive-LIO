ARG ROS_DISTRO=jazzy

FROM ros:${ROS_DISTRO}-ros-base

ARG ROS_DISTRO
ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    cmake \
    curl \
    git \
    tmux \
    libeigen3-dev \
    libpcl-dev \
    libyaml-cpp-dev \
    libgoogle-glog-dev \
    libgflags-dev \
    libceres-dev \
    libsuitesparse-dev \
    libopencv-dev \
    python3-colcon-common-extensions \
    python3-rosdep \
    python3-numpy \
    python3-scipy \
    ros-${ROS_DISTRO}-pcl-conversions \
    ros-${ROS_DISTRO}-pcl-ros \
    ros-${ROS_DISTRO}-plotjuggler \
    ros-${ROS_DISTRO}-plotjuggler-msgs \
    ros-${ROS_DISTRO}-plotjuggler-ros \
    ros-${ROS_DISTRO}-rviz2 \
    ros-${ROS_DISTRO}-tf2-ros \
    ros-${ROS_DISTRO}-tf2-geometry-msgs \
    && rm -rf /var/lib/apt/lists/*

SHELL ["/bin/bash", "-c"]

# Build Livox SDK
RUN git clone https://github.com/Livox-SDK/Livox-SDK2.git /root/Livox-SDK2 \
 && cd /root/Livox-SDK2 \
 && curl -fsSL https://patch-diff.githubusercontent.com/raw/Livox-SDK/Livox-SDK2/pull/85.patch | git apply

WORKDIR /root/Livox-SDK2
RUN mkdir -p build \
    && cd build \
    && cmake .. -DCMAKE_CXX_FLAGS="-Wno-c++20-compat" \
    && make -j"$(nproc)" \
    && make install \
    && ldconfig

# Build Livox ROS2 driver package
WORKDIR /root/livox_ws/src
RUN git clone --recursive --branch feature/use-standard-unit https://github.com/Ericsii/livox_ros_driver2.git

WORKDIR /root/livox_ws
RUN source /opt/ros/${ROS_DISTRO}/setup.bash \
    && colcon build --symlink-install

# Setup Adaptive-LIO workspace
WORKDIR /root/adaptive_lio_ws

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

RUN tee /etc/profile.d/adaptive_lio.sh > /dev/null <<'EOF'
if [ -f /opt/ros/${ROS_DISTRO}/setup.bash ]; then
  source /opt/ros/${ROS_DISTRO}/setup.bash
fi
if [ -f /root/livox_ws/install/setup.bash ]; then
  source /root/livox_ws/install/setup.bash
fi
if [ -f /root/adaptive_lio_ws/install/setup.bash ]; then
  source /root/adaptive_lio_ws/install/setup.bash
fi
EOF

ENTRYPOINT ["/entrypoint.sh"]
CMD ["bash", "-l"]
