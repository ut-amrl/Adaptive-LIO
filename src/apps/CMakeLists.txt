add_executable(${PROJECT_NAME} main_ada.cpp  
                               common_utility.cpp)
target_link_libraries(${PROJECT_NAME} 
                         ${PROJECT_NAME}.common
                         ${PROJECT_NAME}.pre
                         ${PROJECT_NAME}.lio
                         ${PROJECT_NAME}.algo
                         ${third_party_libs}
                        )

ament_target_dependencies(${PROJECT_NAME}
                         rclcpp
                         sensor_msgs
                         nav_msgs
                         geometry_msgs
                         std_msgs
                         tf2
                         tf2_ros
                         tf2_geometry_msgs
                         pcl_conversions
                         livox_ros_driver2
                         )
