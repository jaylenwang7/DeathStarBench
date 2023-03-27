#!/usr/bin/env bash

curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh
sudo curl -L "https://github.com/docker/compose/releases/download/1.29.2/docker-compose-Linux-x86_64" -o /usr/local/bin/docker-compose
sudo chmod +x /usr/local/bin/docker-compose
sudo ln -s /usr/local/bin/docker-compose /usr/bin/docker-compose

wget https://bootstrap.pypa.io/get-pip.py
python3 ./get-pip.py
export PATH="${PATH}:${HOME}/.local/bin"
python3 -m pip install asyncio aiohttp iperf3 argparse

sudo apt-get update
sudo apt-get install make -y
sudo add-apt-repository ppa:sosy-lab/benchmarking -y
sudo apt install cpu-energy-meter -y
sudo apt install iperf3 -y
sudo apt-get install libssl-dev -y
sudo apt-get install libz-dev -y
sudo apt-get install luarocks -y
sudo apt-get install likwid -y
sudo luarocks install luasocket
sudo apt install linux-tools-`uname -r` linux-tools-generic htop -y
sudo apt install libelf-dev libdw-dev systemtap-sdt-dev libunwind-dev libslang2-dev libnuma-dev libiberty-dev -y
