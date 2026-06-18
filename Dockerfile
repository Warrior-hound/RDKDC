FROM osrf/ros:jazzy-desktop

ENV DEBIAN_FRONTEND=noninteractive
ENV DISPLAY=:1
ENV QT_X11_NO_MITSHM=1
ENV LIBGL_ALWAYS_SOFTWARE=1
ENV MESA_GL_VERSION_OVERRIDE=3.3

RUN apt-get update && apt-get install -y \
    xfce4 \
    xfce4-terminal \
    dbus-x11 \
    tigervnc-standalone-server \
    tigervnc-common \
    novnc \
    websockify \
    x11-xserver-utils \
    mesa-utils \
    libgl1-mesa-dri \
    libglx-mesa0 \
    libglu1-mesa \
    ros-jazzy-rviz2 \
    ros-jazzy-demo-nodes-cpp \
    ros-jazzy-ur \
    ros-jazzy-ur-simulation-gz \
    ros-jazzy-joint-state-publisher-gui \
    ros-jazzy-xacro \
    && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /root/.vnc && \
    printf '#!/bin/sh\n\
unset SESSION_MANAGER\n\
unset DBUS_SESSION_BUS_ADDRESS\n\
[ -r "$HOME/.Xresources" ] && xrdb "$HOME/.Xresources"\n\
exec startxfce4\n' > /root/.vnc/xstartup && \
    chmod +x /root/.vnc/xstartup

RUN sed -i 's/<title>.*<\/title>/<title>ROS 2 Jazzy Desktop<\/title>/g' /usr/share/novnc/vnc.html || true && \
    sed -i 's/<title>.*<\/title>/<title>ROS 2 Jazzy Desktop<\/title>/g' /usr/share/novnc/vnc_lite.html || true

CMD ["bash", "-lc", "rm -rf /tmp/.X1-lock /tmp/.X11-unix/X1; vncserver :1 -geometry ${VNC_GEOMETRY:-1920x1080} -depth 24 -SecurityTypes None -localhost yes && websockify --web=/usr/share/novnc/ 6080 localhost:5901"]
