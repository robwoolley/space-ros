ARG IMAGE_NAME="osrf/space-ros"
ARG IMAGE_TAG="latest"
ARG USERNAME="spaceros-user"
ARG HOME="/home/${USERNAME}"
ARG WORKSPACE_DIR="/spaceros_ws"

###############################################################################
### PreInstallation Stage
# This stage is responsible for setting up the base image with the necessary
# dependencies required for the subsequent stages.
###############################################################################
FROM ubuntu:noble AS pre-installation
ARG USERNAME
ARG HOME
ARG WORKSPACE_DIR

ENV DEBIAN_FRONTEND=noninteractive
ENV ROS_DISTRO="jazzy"
ENV HOME=${HOME}
ENV SPACEROS_DIR="/opt/ros/spaceros"
RUN mkdir -p ${WORKSPACE_DIR}
WORKDIR ${WORKSPACE_DIR}

# Set the locale
RUN apt-get update && apt-get install -y locales
RUN locale-gen en_US en_US.UTF-8
RUN update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
ENV LANG=en_US.UTF-8

# The following commands are based on the source install for ROS 2 Rolling Ridley.
# See: https://docs.ros.org/en/ros2_documentation/rolling/Installation/Ubuntu-Development-Setup.html
# The main variation is getting Space ROS sources instead of the Rolling sources.

# Add the ROS 2 apt repository
RUN apt-get update && apt-get install -y \
      curl \
      git \
      cmake \
      build-essential \
      bison \
      wget \
      gnupg \
      lsb-release \
      python3-pip \
      python3-setuptools \
      software-properties-common
RUN add-apt-repository universe
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key -o /usr/share/keyrings/ros-archive-keyring.gpg
RUN echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] http://packages.ros.org/ros2/ubuntu $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/ros2.list > /dev/null \
  && apt update

###############################################################################
### Setup Stage
# This stage is responsible for setting up the ROS 2 workspace and the required
# dependencies for the workspace.
###############################################################################
FROM pre-installation AS setup
ARG USERNAME
ARG HOME
ARG WORKSPACE_DIR

# Install required software development tools and ROS tools (and vim included for convenience)
RUN apt-get install -y python3-rosinstall-generator

COPY scripts ./
COPY excluded-pkgs.txt spaceros-pkgs.txt spaceros.repos ./

# This is a fresh image, so we do not need to exclude installed packages.
ENV AMENT_PREFIX_PATH=${SPACEROS_DIR}
RUN sh generate-repos.sh \
               --outfile ros2.repos \
               --packages spaceros-pkgs.txt \
               --excluded-packages excluded-pkgs.txt \
               --rosdistro ${ROS_DISTRO}
RUN  python3 merge-repos.py ros2.repos spaceros.repos -o output.repos
# SAVE ARTIFACT output.repos AS LOCAL ros2.repos

###############################################################################
### Sources Stage
# This stage is responsible for fetching the ROS 2 workspace sources.
###############################################################################
FROM setup AS sources
ARG USERNAME
ARG HOME
ARG WORKSPACE_DIR

RUN apt-get update && apt-get install -y python3-vcstool
RUN mkdir src -p \
    && vcs import --retry 3 src < output.repos \
    && vcs export --exact src > exact.repos

RUN ls -al ${WORKSPACE_DIR}

# Save artifacts to be used
# SAVE ARTIFACT exact.repos
# SAVE ARTIFACT src

###############################################################################
### Rosdep Stage
# This stage is responsible for installing the system dependencies required
# for the ROS 2 workspace.
###############################################################################
FROM pre-installation AS rosdep
ARG USERNAME
ARG HOME
ARG WORKSPACE_DIR

# Rosdep updates
RUN apt-get update && apt-get install -y python3-rosdep \
    && rosdep init \
    && rosdep update

# Copy Repos file
COPY --from=sources ${WORKSPACE_DIR}/src/ ./src
COPY excluded-pkgs.txt excluded-deps.txt ./

# Install system package dependencies using rosdep
RUN rosdep install -y \
      --from-paths src --ignore-src \
      --simulate \
      --rosdistro ${ROS_DISTRO} \
      # `urdfdom_headers` is cloned from source, however rosdep can't find it.
      # It is because package.xml manifest is missing. See: https://github.com/ros/urdfdom_headers
      # Additionally, IKOS must be excluded as per: https://github.com/space-ros/docker/issues/99
      --skip-keys "$(tr '\n' ' ' < 'excluded-pkgs.txt') urdfdom_headers ikos" > rosdeps.txt

# Process rosdeps.txt to a shell script
RUN touch rosdeps.sh \
      && echo "#!/bin/bash" > rosdeps.sh \
      && echo "apt-get update" >> rosdeps.sh \
      && echo "apt-get install -y \\" >> rosdeps.sh \
      && grep -v -F -f excluded-deps.txt rosdeps.txt | sed 's/^/  /' >> rosdeps.sh \
      && chmod +x rosdeps.sh

# The generated shell script is used by the prepare-image stage prior to building the image
# saving build time by not having to install dependencies again.
# SAVE ARTIFACT rosdeps.sh

###############################################################################
### Build Stage
# This stage is responsible for building the ROS 2 workspace for either the dev
# or the main image.
###############################################################################
FROM rosdep AS build
ARG USERNAME
ARG HOME
ARG WORKSPACE_DIR

# Uncrustify Vendor has vcstool as a dependency
RUN apt-get update && apt-get install -y \
      python3-vcstool \
      python3-colcon-common-extensions
COPY --from=rosdep ${WORKSPACE_DIR}/rosdeps.sh rosdeps.sh

RUN bash rosdeps.sh
RUN mkdir -p ${SPACEROS_DIR}

# DO +BUILD_WORKSPACE --IMAGE_VARIANT=${IMAGE_VARIANT}

# SAVE ARTIFACT ${SPACEROS_DIR} spaceros_install

