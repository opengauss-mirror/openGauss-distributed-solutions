#!/bin/bash
#初始化系统  必须使用root或者具备sudo权限帐号运行

#关闭防火墙
sudo systemctl stop firewalld
sudo systemctl disable firewalld
sudo iptables -F && sudo iptables -X && sudo iptables -F -t nat && sudo iptables -X -t nat
sudo iptables -P FORWARD ACCEPT
sudo echo "net.ipv4.ip_forward=1" >> /usr/lib/sysctl.d/00-system.conf
sudo sysctl -w net.ipv4.ip_forward=1

#关闭swap
sudo swapoff -a
sudo sed -i '/ swap / s/^\(.*\)$/#\1/g' /etc/fstab

#关闭selinux
sudo setenforce 0
sudo sed -i "s/SELINUX=enforcing/SELINUX=disabled/g" /etc/selinux/config
sudo sed -i "s/SELINUX=permissive/SELINUX=disabled/g" /etc/selinux/config

#sudo yum -y install ipvsadm  ipset
# 临时生效
sudo modprobe -- ip_vs
sudo modprobe -- ip_vs_rr
sudo modprobe -- ip_vs_wrr
sudo modprobe -- ip_vs_sh
sudo modprobe -- nf_conntrack_ipv4

# 永久生效
sudo cat > /etc/sysconfig/modules/ipvs.modules <<EOF
modprobe -- ip_vs
modprobe -- ip_vs_rr
modprobe -- ip_vs_wrr
modprobe -- ip_vs_sh
modprobe -- nf_conntrack_ipv4
EOF