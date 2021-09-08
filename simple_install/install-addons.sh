#!/bin/bash
NameSpace="default"

echo -e "\033[32m## 安装网络组件flannel. =====================================================================\033[0m"
#sudo sed -i "s/quay.io/quay-mirror.qiniu.com/g" addons/flannel/kube-flannel.yaml
sudo kubectl apply -f addons/flannel/kube-flannel.yaml


#echo -e "\033[32m## k8s-web组件Dashboard =====================================================================\033[0m"
#sudo kubectl apply -f addons/dashboard/recommended.yaml
#sudo kubectl create sa dashboard-admin -n kube-system
#sudo kubectl create clusterrolebinding dashboard-admin --clusterrole=cluster-admin --serviceaccount=kube-system:dashboard-admin
#ADMIN_SECRET=$(sudo kubectl get secrets -n kube-system | grep dashboard-admin | awk '{print $1}')
#DASHBOARD_LOGIN_TOKEN=$(sudo kubectl describe secret -n kube-system ${ADMIN_SECRET} | grep -E '^token' | awk '{print $2}')
#echo ${DASHBOARD_LOGIN_TOKEN} > token.txt

#echo -e "\033[32m 浏览方式: 用firefox 浏览 https://nodes-ip:30001 (要用命令查看pod-dashboard所对应的node节点),跳出不安全提示，然后高级点添加网站到安全例外\033[0m"
#echo -e "\033[33m 登录token见 安装目录下token.txt \033[0m"

