#!/bin/bash
# 采用阿里云docker源，build引自官方镜像

sudo docker pull registry.aliyuncs.com/google_containers/kube-apiserver:v1.21.1 && \
     docker tag registry.aliyuncs.com/google_containers/kube-apiserver:v1.21.1 k8s.gcr.io/kube-apiserver:v1.21.1
     
sudo docker pull registry.aliyuncs.com/google_containers/kube-controller-manager:v1.21.1 && \
     docker tag registry.aliyuncs.com/google_containers/kube-controller-manager:v1.21.1 k8s.gcr.io/kube-controller-manager:v1.21.1

sudo docker pull registry.aliyuncs.com/google_containers/kube-scheduler:v1.21.1 && \
     docker tag registry.aliyuncs.com/google_containers/kube-scheduler:v1.21.1 k8s.gcr.io/kube-scheduler:v1.21.1

sudo docker pull registry.aliyuncs.com/google_containers/kube-proxy:v1.21.1 && \
     docker tag registry.aliyuncs.com/google_containers/kube-proxy:v1.21.1 k8s.gcr.io/kube-proxy:v1.21.1

sudo docker pull registry.aliyuncs.com/google_containers/pause:3.4.1 && \
     docker tag registry.aliyuncs.com/google_containers/pause:3.4.1 k8s.gcr.io/pause:3.4.1

sudo docker pull registry.aliyuncs.com/google_containers/etcd:3.4.13-0 && \
     docker tag registry.aliyuncs.com/google_containers/etcd:3.4.13-0 k8s.gcr.io/etcd:3.4.13-0

sudo docker pull coredns/coredns:1.8.0 && \
     docker tag docker.io/coredns/coredns:1.8.0 k8s.gcr.io/coredns/coredns:v1.8.0

sudo docker pull kubernetesui/dashboard:v2.0.0-rc3    

sudo docker pull quay.io/coreos/flannel:v0.14.0 && \
     docker tag quay.io/coreos/flannel:v0.14.0 quay.io/coreos/flannel:v0.14.0

sudo docker images | grep k8s.gcr.io

