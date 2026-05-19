# Install script for directory: D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/src

# Set the install prefix
if(NOT DEFINED CMAKE_INSTALL_PREFIX)
  set(CMAKE_INSTALL_PREFIX "D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/install/x64-Debug")
endif()
string(REGEX REPLACE "/$" "" CMAKE_INSTALL_PREFIX "${CMAKE_INSTALL_PREFIX}")

# Set the install configuration name.
if(NOT DEFINED CMAKE_INSTALL_CONFIG_NAME)
  if(BUILD_TYPE)
    string(REGEX REPLACE "^[^A-Za-z0-9_]+" ""
           CMAKE_INSTALL_CONFIG_NAME "${BUILD_TYPE}")
  else()
    set(CMAKE_INSTALL_CONFIG_NAME "Debug")
  endif()
  message(STATUS "Install configuration: \"${CMAKE_INSTALL_CONFIG_NAME}\"")
endif()

# Set the component getting installed.
if(NOT CMAKE_INSTALL_COMPONENT)
  if(COMPONENT)
    message(STATUS "Install component: \"${COMPONENT}\"")
    set(CMAKE_INSTALL_COMPONENT "${COMPONENT}")
  else()
    set(CMAKE_INSTALL_COMPONENT)
  endif()
endif()

# Is this installation the result of a crosscompile?
if(NOT DEFINED CMAKE_CROSSCOMPILING)
  set(CMAKE_CROSSCOMPILING "FALSE")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/install/x64-Debug/lib/lwext4.lib")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/install/x64-Debug/lib" TYPE STATIC_LIBRARY FILES "D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/build/x64-Debug/src/lwext4.lib")
endif()

if(CMAKE_INSTALL_COMPONENT STREQUAL "Unspecified" OR NOT CMAKE_INSTALL_COMPONENT)
  list(APPEND CMAKE_ABSOLUTE_DESTINATION_FILES
   "D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/install/x64-Debug/include/lwext4/.")
  if(CMAKE_WARN_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(WARNING "ABSOLUTE path INSTALL DESTINATION : ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  if(CMAKE_ERROR_ON_ABSOLUTE_INSTALL_DESTINATION)
    message(FATAL_ERROR "ABSOLUTE path INSTALL DESTINATION forbidden (by caller): ${CMAKE_ABSOLUTE_DESTINATION_FILES}")
  endif()
  file(INSTALL DESTINATION "D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/install/x64-Debug/include/lwext4" TYPE DIRECTORY FILES "D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/build/x64-Debug/include/.")
endif()

