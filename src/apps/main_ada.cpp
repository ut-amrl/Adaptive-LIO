// c++ lib
#include <algorithm>
#include <chrono>
#include <cmath>
#include <functional>
#include <iostream>
#include <memory>
#include <mutex>
#include <queue>
#include <random>
#include <thread>
#include <vector>

// ros2 lib
#include <builtin_interfaces/msg/time.hpp>
#include <geometry_msgs/msg/pose_stamped.hpp>
#include <geometry_msgs/msg/transform_stamped.hpp>
#include <livox_ros_driver2/msg/custom_msg.hpp>
#include <nav_msgs/msg/odometry.hpp>
#include <nav_msgs/msg/path.hpp>
#include <rclcpp/rclcpp.hpp>
#include <sensor_msgs/msg/imu.hpp>
#include <sensor_msgs/msg/point_cloud2.hpp>
#include <std_msgs/msg/float32.hpp>
#include <tf2_ros/transform_broadcaster.h>

#include <gflags/gflags.h>
#include <glog/logging.h>
#include <yaml-cpp/yaml.h>

#include "common/utility.h"
#include "lio/lidarodom.h"
#include "preprocess/cloud_convert/cloud_convert2.h"

nav_msgs::msg::Path laserOdoPath;

zjloc::lidarodom_m *lio;
zjloc::CloudConvert2 *convert;
double gnorm = 1.0;

rclcpp::Publisher<sensor_msgs::msg::Imu>::SharedPtr imu_repub;
rclcpp::Publisher<sensor_msgs::msg::PointCloud2>::SharedPtr pub_scan;
rclcpp::Publisher<nav_msgs::msg::Odometry>::SharedPtr pubLaserOdometry;
rclcpp::Publisher<nav_msgs::msg::Path>::SharedPtr pubLaserOdometryPath;
rclcpp::Publisher<std_msgs::msg::Float32>::SharedPtr vel_pub;
rclcpp::Publisher<std_msgs::msg::Float32>::SharedPtr dist_pub;
std::unique_ptr<tf2_ros::TransformBroadcaster> tf_broadcaster;

#define DEBUG_FILE_DIR(name) (std::string(std::string(ROOT_DIR) + "log/" + name))

static builtin_interfaces::msg::Time ToRosTime(double stamp_seconds)
{
    builtin_interfaces::msg::Time stamp;
    if (stamp_seconds < 0.0)
    {
        stamp_seconds = 0.0;
    }

    stamp.sec = static_cast<int32_t>(std::floor(stamp_seconds));
    stamp.nanosec = static_cast<uint32_t>((stamp_seconds - static_cast<double>(stamp.sec)) * 1e9);
    return stamp;
}

void livox_pcl_cbk(livox_ros_driver2::msg::CustomMsg::ConstSharedPtr msg)
{
    std::vector<std::vector<point3D>> cloud_vec;
    std::vector<double> t_out;
    zjloc::common::Timer::Evaluate([&]() { convert->Process(msg, cloud_vec, t_out); }, "laser convert");

    for (int i = 0; i < static_cast<int>(cloud_vec.size()); i++)
    {
        auto &cloud_out = cloud_vec[i];
        double sample_size = lio->getIndex() < 20 ? 0.01 : 0.01;
        std::mt19937_64 g;
        zjloc::common::Timer::Evaluate(
            [&]() {
                std::shuffle(cloud_out.begin(), cloud_out.end(), g);
                subSampleFrame(cloud_out, sample_size);
                std::shuffle(cloud_out.begin(), cloud_out.end(), g);
            },
            "laser ds");

        lio->pushData(cloud_out, std::make_pair(rclcpp::Time(msg->header.stamp).seconds() + t_out[i] - t_out[0], t_out[0]));
    }
}

void standard_pcl_cbk(sensor_msgs::msg::PointCloud2::ConstSharedPtr msg)
{
    std::vector<std::vector<point3D>> cloud_vec;
    std::vector<double> t_out;
    zjloc::common::Timer::Evaluate([&]() { convert->Process(msg, cloud_vec, t_out); }, "laser convert");

    for (int i = 0; i < static_cast<int>(cloud_vec.size()); i++)
    {
        auto &cloud_out = cloud_vec[i];
        double sample_size = lio->getIndex() < 30 ? 0.02 : 0.1;
        zjloc::common::Timer::Evaluate(
            [&]() {
                std::mt19937_64 g;
                std::shuffle(cloud_out.begin(), cloud_out.end(), g);
                sub_sample_frame(cloud_out, sample_size);
                std::shuffle(cloud_out.begin(), cloud_out.end(), g);
            },
            "laser ds");

        lio->pushData(cloud_out, std::make_pair(rclcpp::Time(msg->header.stamp).seconds() + t_out[i] - t_out[0], t_out[0]));
    }
}

void imuHandler(sensor_msgs::msg::Imu::ConstSharedPtr msg)
{
    IMUPtr imu = std::make_shared<zjloc::IMU>(
        rclcpp::Time(msg->header.stamp).seconds(),
        Vec3d(msg->angular_velocity.x, msg->angular_velocity.y, msg->angular_velocity.z),
        Vec3d(msg->linear_acceleration.x, msg->linear_acceleration.y, msg->linear_acceleration.z) * gnorm);

    lio->pushData(imu);

    sensor_msgs::msg::Imu repub_msg = *msg;
    repub_msg.linear_acceleration.x *= gnorm;
    repub_msg.linear_acceleration.y *= gnorm;
    repub_msg.linear_acceleration.z *= gnorm;
    imu_repub->publish(repub_msg);
}

int main(int argc, char **argv)
{
    google::InitGoogleLogging(argv[0]);
    FLAGS_stderrthreshold = google::INFO;
    FLAGS_colorlogtostderr = true;

    rclcpp::init(argc, argv);
    auto node = std::make_shared<rclcpp::Node>("adaptive_lio");

    std::string default_config = std::string(ROOT_DIR) + "config/mapping_m.yaml";
    node->declare_parameter<std::string>("config_file", default_config);
    std::string config_file = node->get_parameter("config_file").as_string();
    std::cout << ANSI_COLOR_GREEN << "config_file:" << config_file << ANSI_COLOR_RESET << std::endl;

    lio = new zjloc::lidarodom_m();
    if (!lio->init(config_file))
    {
        return -1;
    }

    pub_scan = node->create_publisher<sensor_msgs::msg::PointCloud2>("scan", 10);
    auto cloud_pub_func = std::function<bool(std::string &, zjloc::CloudPtr &, double)>(
        [&](std::string &topic_name, zjloc::CloudPtr &cloud, double time) {
            sensor_msgs::msg::PointCloud2 cloud_output;
            pcl::toROSMsg(*cloud, cloud_output);

            cloud_output.header.stamp = ToRosTime(time);
            cloud_output.header.frame_id = "map";
            if (topic_name == "laser")
            {
                pub_scan->publish(cloud_output);
            }
            return true;
        });

    pubLaserOdometry = node->create_publisher<nav_msgs::msg::Odometry>("/odom", 100);
    pubLaserOdometryPath = node->create_publisher<nav_msgs::msg::Path>("/odometry_path", 5);
    tf_broadcaster = std::make_unique<tf2_ros::TransformBroadcaster>(node);

    auto pose_pub_func = std::function<bool(std::string &, SE3 &, double)>(
        [&](std::string &topic_name, SE3 &pose, double stamp) {
            Eigen::Quaterniond q_current(pose.so3().matrix());

            geometry_msgs::msg::TransformStamped transform;
            transform.header.stamp = ToRosTime(stamp);
            transform.transform.translation.x = pose.translation().x();
            transform.transform.translation.y = pose.translation().y();
            transform.transform.translation.z = pose.translation().z();
            transform.transform.rotation.x = q_current.x();
            transform.transform.rotation.y = q_current.y();
            transform.transform.rotation.z = q_current.z();
            transform.transform.rotation.w = q_current.w();

            if (topic_name == "laser")
            {
                transform.header.frame_id = "map";
                transform.child_frame_id = "base_link";
                tf_broadcaster->sendTransform(transform);

                nav_msgs::msg::Odometry laserOdometry;
                laserOdometry.header.frame_id = "map";
                laserOdometry.child_frame_id = "base_link";
                laserOdometry.header.stamp = ToRosTime(stamp);

                laserOdometry.pose.pose.orientation.x = q_current.x();
                laserOdometry.pose.pose.orientation.y = q_current.y();
                laserOdometry.pose.pose.orientation.z = q_current.z();
                laserOdometry.pose.pose.orientation.w = q_current.w();
                laserOdometry.pose.pose.position.x = pose.translation().x();
                laserOdometry.pose.pose.position.y = pose.translation().y();
                laserOdometry.pose.pose.position.z = pose.translation().z();
                pubLaserOdometry->publish(laserOdometry);

                geometry_msgs::msg::PoseStamped laserPose;
                laserPose.header = laserOdometry.header;
                laserPose.pose = laserOdometry.pose.pose;
                laserOdoPath.header.stamp = laserOdometry.header.stamp;
                laserOdoPath.header.frame_id = "map";
                laserOdoPath.poses.push_back(laserPose);
                pubLaserOdometryPath->publish(laserOdoPath);
            }
            else if (topic_name == "world")
            {
                transform.header.frame_id = "world";
                transform.child_frame_id = "map";
                tf_broadcaster->sendTransform(transform);
            }

            return true;
        });

    vel_pub = node->create_publisher<std_msgs::msg::Float32>("/velocity", 1);
    dist_pub = node->create_publisher<std_msgs::msg::Float32>("/move_dist", 1);
    imu_repub = node->create_publisher<sensor_msgs::msg::Imu>("/repub_imu", 1);

    auto data_pub_func = std::function<bool(std::string &, double, double)>(
        [&](std::string &topic_name, double time1, double) {
            std_msgs::msg::Float32 time_rviz;
            time_rviz.data = time1;
            if (topic_name == "velocity")
            {
                vel_pub->publish(time_rviz);
            }
            else
            {
                dist_pub->publish(time_rviz);
            }
            return true;
        });

    lio->setFunc(cloud_pub_func);
    lio->setFunc(pose_pub_func);
    lio->setFunc(data_pub_func);

    convert = new zjloc::CloudConvert2;
    convert->LoadFromYAML(config_file);

    lio->setCloudConvert(convert);
    std::cout << ANSI_COLOR_GREEN_BOLD << "init successful" << ANSI_COLOR_RESET << std::endl;

    auto yaml = YAML::LoadFile(config_file);
    std::string laser_topic = yaml["common"]["lid_topic"].as<std::string>();
    std::string imu_topic = yaml["common"]["imu_topic"].as<std::string>();
    gnorm = yaml["common"]["gnorm"].as<double>();

    rclcpp::Subscription<livox_ros_driver2::msg::CustomMsg>::SharedPtr sub_livox;
    rclcpp::Subscription<sensor_msgs::msg::PointCloud2>::SharedPtr sub_points;
    if (convert->lidar_type_ == zjloc::CloudConvert2::LidarType::AVIA)
    {
        sub_livox = node->create_subscription<livox_ros_driver2::msg::CustomMsg>(
            laser_topic,
            rclcpp::SensorDataQoS(),
            livox_pcl_cbk);
    }
    else
    {
        sub_points = node->create_subscription<sensor_msgs::msg::PointCloud2>(
            laser_topic,
            rclcpp::SensorDataQoS(),
            standard_pcl_cbk);
    }

    auto sub_imu_ori = node->create_subscription<sensor_msgs::msg::Imu>(
        imu_topic,
        rclcpp::SensorDataQoS(),
        imuHandler);

    std::thread measurement_process(&zjloc::lidarodom_m::run, lio);
    measurement_process.detach();

    rclcpp::spin(node);

    zjloc::common::Timer::PrintAll();
    zjloc::common::Timer::DumpIntoFile(DEBUG_FILE_DIR("log_time.txt"));

    std::cout << ANSI_COLOR_GREEN_BOLD << " out done. " << ANSI_COLOR_RESET << std::endl;

    if (rclcpp::ok())
    {
        rclcpp::shutdown();
    }
    return 0;
}
