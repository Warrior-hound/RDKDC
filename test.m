% RDKDC Jazzy Docker/VNC smoke test.
% Runs local MATLAB code against the Docker HTTP bridge, which then commands
% the UR5e ROS 2 controller inside the container.

original_dir = pwd;
bridge_url = "http://127.0.0.1:8765";
matlab_bridge_dir = fullfile(getenv("USERPROFILE"), "ros2_ws", "matlab");

cleanup = onCleanup(@() cd(original_dir));

setenv("RDKDC_BRIDGE_URL", bridge_url);
cd(matlab_bridge_dir);
addpath(matlab_bridge_dir);

disp("Checking RDKDC bridge...");
health = webread(bridge_url + "/health", weboptions("Timeout", 5));
disp(health);

ur5e = ur5_interface();

disp("Initial joints:");
q0 = ur5e.get_current_joints();
disp(q0.');

q1 = [0.40; -1.20; 0.80; -1.90; 0.30; 0.20];
q2 = [0.00; -pi/2; 0.00; -pi/2; 0.00; 0.00];

disp("Moving UR5e to test pose...");
ur5e.move_joints(q1, 4);
pause(5);
disp("Joints after test pose:");
disp(ur5e.get_current_joints().');

disp("Returning UR5e home...");
ur5e.move_joints(q2, 4);
pause(5);
disp("Final joints:");
disp(ur5e.get_current_joints().');

disp("UR5e MATLAB bridge motion test complete.");
