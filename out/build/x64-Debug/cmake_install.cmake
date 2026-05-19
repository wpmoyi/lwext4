# Install script for directory: D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master

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

if(NOT CMAKE_INSTALL_LOCAL_ONLY)
  # Include the install script for each subdirectory.
  include("D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/build/x64-Debug/fs_test/cmake_install.cmake")
  include("D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/build/x64-Debug/blockdev/cmake_install.cmake")
  include("D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/build/x64-Debug/src/cmake_install.cmake")

endif()

if(CMAKE_INSTALL_COMPONENT)
  set(CMAKE_INSTALL_MANIFEST "install_manifest_${CMAKE_INSTALL_COMPONENT}.txt")
else()
  set(CMAKE_INSTALL_MANIFEST "install_manifest.txt")
endif()

string(REPLACE ";" "\n" CMAKE_INSTALL_MANIFEST_CONTENT
       "${CMAKE_INSTALL_MANIFEST_FILES}")
file(WRITE "D:/Program Files (x86)/WiseUCEnt/DATA/魏帅帅@115871/Downloads/刘春蒙/存储芯片+文件系统/存储芯片+文件系统/lwext4输入内网/lwext4输入内网/lwext4-master/lwext4-master/out/build/x64-Debug/${CMAKE_INSTALL_MANIFEST}"
     "${CMAKE_INSTALL_MANIFEST_CONTENT}")
