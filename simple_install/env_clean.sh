# 环境清理
echo -e "\033[32m## kubeadm reset 清理K8S. ===========================================================\033[0m"
kubeadm reset -f
rm -rf $HOME/.kube 
rm -rf /etc/kubernetes
rm -rf /etc/cni
yum remove kube* -y
echo -e "\033[32m## 清除所有镜像并卸载docker. ===========================================================\033[0m"
sudo systemctl stop docker
sudo yum -y remove docker*
yum clean all
