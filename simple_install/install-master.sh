#!/bin/bash
# 安装master
# cd 到目录中运行 ./install-master.sh 就可以
K8sVersion="1.21.1"
WORKDIR=$(cd `dirname $0`;pwd)      #脚本所在路径
PROFILE_PATH=${WORKDIR}/profile
#提取所有节点的IP地址
all_ip=($(grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}' ${PROFILE_PATH}))
#提取master节点的IP
master_ip=($(grep 'master' ${PROFILE_PATH} |awk -F'=' '{print $2}')) 
#提取node节点的IP
node_ip=($(grep 'node' ${PROFILE_PATH} |awk -F'=' '{print $2}')) 



Init_master(){
    echo -e "\033[32m## 安装并初始化master =======================================================================\033[0m"
    if [ -z $master_ip ] ;then
    	echo "kubeadm init --kubernetes-version=v$K8sVersion --pod-network-cidr=10.244.0.0/16"
    	echo "Please wait a few minutes!"
    	kubeadm init --kubernetes-version=v$K8sVersion --pod-network-cidr=10.244.0.0/16 > init.log
    else
        echo "kubeadm init --kubernetes-version=v$K8sVersion --apiserver-advertise-address $master_ip --pod-network-cidr=10.244.0.0/16" 
        echo "Please wait a few minutes!"
    	kubeadm init --kubernetes-version=v$K8sVersion --apiserver-advertise-address $master_ip --pod-network-cidr=10.244.0.0/16 > init.log
    fi
    
    JoinCommand=`kubeadm token create --print-join-command`
    if [ $? -eq 0 ]; then
        echo -e "\033[32m## k8s-master安装成功，节点加入集群命令如下: =============================================\033[0m"
        echo "$JoinCommand"
        sudo cp node-template.sh install-node.sh
        sudo chmod +x install-node.sh
        echo "$JoinCommand" >> install-node.sh
        sudo mkdir -p $HOME/.kube
        sudo cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
        sudo chown $(id -u):$(id -g) $HOME/.kube/config
    
        echo -e "\033[32m## k8s安装插件: ==========================================================================\033[0m"
        /bin/bash install-addons.sh
    
        echo -e "\033[32m## 生成node节点安装包 =====================================================================\033[0m"
        mkdir -p /tmp/k8s-node-install
        cp setupconfig.sh install-docker.sh pull-docker.sh install-k8s.sh install-node.sh /tmp/k8s-node-install
        cd /tmp
        tar -czf k8s-node-install.tar.gz k8s-node-install
        sudo mv k8s-node-install.tar.gz /root/
        rm -rf /tmp/k8s-node-install
        echo -e "\033[32m## 安装包路径在 /root/k8s-node-install.tar.gz scp到你node节点解压后运行./install-node.sh 即可.\033[0m"
    else
        echo -e "\033[31m kubeadm init failed! 初始化失败!请查看安装日志 cat init.log \033[0m"
        exit 1
    fi
}

#发送安装脚本到Node节点
Config_Ssh(){
    echo -e "\033[32m## ssh至Node节点并发送安装包=========================================================\033[0m"
    echo "excute time:$(date +"%Y-%m-%d %H:%M:%S")"
    for((i=0;i<${#node_ip[@]};i++))
    do
        scp -r /root/k8s-node-install.tar.gz root@${node_ip[i]}:/root/
        ssh root@${node_ip[i]} -t -t "tar xf /root/k8s-node-install.tar.gz"
    done
}

#网络检测
Check_Net(){
    echo -e "\033[32m## 检测网络=================================================\033[0m" && sleep 1
	echo "excute time:$(date +"%Y-%m-%d %H:%M:%S")"
	for((i=0;i<${#all_ip[@]};i++))
	do
	    ssh root@${all_ip[i]} -t -t "curl -I www.baidu.com --connect-timeout 5 &>/dev/null"
	    if [ $? -ne 0 ];then
                echo -e "\033[31m## ${all_ip[i]}不能访问外网,按crtl+c退出安装=====\033[0m"
		exit 1
	    fi
	done
	echo -e "\033[32m## 网络正常=================================================\033[0m"
}

#将node加入集群
Init_Node(){
    for((i=0;i<${#node_ip[@]};i++))
    do
        ssh root@${node_ip[i]} -t -t "kubeadm reset -f"
		ssh root@${node_ip[i]} -t -t "cd /root/k8s-node-install && chmod +x *sh && sh install-node.sh"
    done
}

main(){
    Check_Net
    echo -e "\033[32m## 初始化k8s所需要环境. =====================================================================\033[0m"
    /bin/bash setupconfig.sh

    echo -e "\033[32m## 安装docker,如果不需要请注释该行,安装新版docker修改下面这句 /bin/bash install-docker.sh ===\033[0m"
    /bin/bash install-docker.sh new
    #/bin/bash install-docker.sh

    echo -e "\033[32m## 下载kubeadm所需要的镜像. =================================================================\033[0m"
    echo -e "\033[32m## 针对国内网络，采用阿里云镜像源，build引自官方镜像 \033[0m"
    /bin/bash pull-docker.sh

    echo -e "\033[32m## yum安装k8s ===============================================================================\033[0m"
    /bin/bash install-k8s.sh $K8sVersion
    Init_master
    Config_Ssh
    Init_Node
    echo -e "\033[32m## 集群初始化成功，执行kubectl get nodes -o wide查看节点信息 ===============================================================================\033[0m"
    kubectl get nodes -o wide
}
main
