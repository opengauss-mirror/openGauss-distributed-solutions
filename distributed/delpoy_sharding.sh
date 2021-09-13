#!/bin/bash

#name:shardingphere's name
#dir: which node is shardingphere deploy
#hostname:shardingphere's config path

name="$1";
dir="$2";
hostname="$3"


sudo kubectl delete pod ${name}-sha
sudo kubectl delete svc ${name}-service-sha


res=`sudo kubectl describe node ${hostname} | grep InternalIP:`
result=`echo $res | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'`

sudo ssh root@${result} "mkdir -p ${dir}"
sudo scp -r ./config-sharding_tmp.yaml root@${result}:${dir}config-sharding.yaml

echo "
apiVersion: v1
kind: Pod
metadata:
  name: ${name}-sha
  labels:
    app: ${name}-sha
spec:
  nodeName: ${hostname}
  containers:
  - name: ${name}-sha
    image: shardingsphere:1.0.1
    imagePullPolicy: Never
    volumeMounts:
    - name: config-file
      mountPath: /tmp/
    ports:
    - containerPort: 3307
      name: ${name}
  volumes:
  - name: config-file
    hostPath:
      path: ${dir}
      type: Directory
" > shardingsphere.yaml


echo "
apiVersion: v1
kind: Service
metadata:
  name: ${name}-service-sha
spec:
  type: NodePort
  ports:
  - port: 3307
    protocol: TCP
    targetPort: 3307
    nodePort: 30400
  - port: 8888
    protocol: TCP
    targetPort: 8888
    nodePort: 30600
  - port: 2181
    protocol: TCP
    targetPort: 2181
    nodePort: 30700
  selector:
    app: ${name}-sha
" > shardingsphere-svc.yaml

sudo kubectl create -f shardingsphere-svc.yaml
sudo kubectl create -f shardingsphere.yaml
