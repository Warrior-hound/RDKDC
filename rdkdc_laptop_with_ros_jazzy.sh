#!/bin/bash
### install combined ROS package by default

### ensure that script is running as sudo
if ! [ $(id -u) = 0 ]; then
   echo "The script needs to be run as root." >&2
   exit 1
fi

### grab users (non-root) usernames to run commands as them later
real_user=$SUDO_USER

### remove duplicate old ROS apt source if the new ros-apt-source file exists
if [ -e /etc/apt/sources.list.d/ros2.list ] && [ -e /etc/apt/sources.list.d/ros2.sources ]; then
   sudo rm -f /etc/apt/sources.list.d/ros2.list
fi

### install git
sudo apt install git --yes

### make sure all packages are up-to-date
sudo apt update

### install ROS
# https://docs.ros.org/en/jazzy/Installation/Ubuntu-Install-Debians.html
locale  # check for UTF-8
sudo apt update && sudo apt install locales
sudo locale-gen en_US en_US.UTF-8
sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8
export LANG=en_US.UTF-8
locale  # verify settings
sudo apt install software-properties-common
sudo add-apt-repository universe
sudo apt update && sudo apt install curl -y
export ROS_APT_SOURCE_VERSION=$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest | grep -F "tag_name" | awk -F\" '{print $4}')
curl -L -o /tmp/ros2-apt-source.deb "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ROS_APT_SOURCE_VERSION}/ros2-apt-source_${ROS_APT_SOURCE_VERSION}.$(. /etc/os-release && echo $VERSION_CODENAME)_all.deb" # If using Ubuntu derivates use $UBUNTU_CODENAME
sudo apt install /tmp/ros2-apt-source.deb

sudo apt update
sudo apt upgrade --yes
sudo apt install ros-jazzy-desktop --yes

# install colcon and other build tools
sudo apt install python3-colcon-common-extensions --yes
sudo apt install ros-dev-tools --yes

### source ROS install for this shell
source /opt/ros/jazzy/setup.bash

### install ur5 driver
sudo apt install ros-jazzy-ur-robot-driver --yes

### install python dependencies
sudo apt install ros-jazzy-tf-transformations --yes

### build rdkdc workspace
# do this as current user so it executes properly
sudo -u "$real_user" bash -c -l "
cd ~/
source /opt/ros/jazzy/setup.bash
mkdir -p ~/rdkdc_ws/src
if ! [ -d ~/rdkdc_ws/src/rdkdc ]; then
    cd ~/rdkdc_ws/src
    git clone https://github.com/Warrior-hound/rdkdc_jazzy.git rdkdc
fi
cd ~/rdkdc_ws
colcon build --cmake-args -DPython3_EXECUTABLE=/usr/bin/python3"

### automatically source files in .bashrc
# does not add if they are already there
# do this as current user so it saves properly
sudo -u $real_user bash -c -l '
ROS_SOURCING="source /opt/ros/jazzy/setup.bash"
if ! grep -qF "$ROS_SOURCING" ~/.bashrc ; then echo "$ROS_SOURCING" >> ~/.bashrc ; fi
RDKDC_SOUCING="source ~/rdkdc_ws/install/local_setup.bash"
if ! grep -qF "$RDKDC_SOUCING" ~/.bashrc ; then echo "$RDKDC_SOUCING" >> ~/.bashrc ; fi'
