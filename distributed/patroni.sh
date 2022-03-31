#!/bin/bash

#create parameter with patroni's config
getPara(){ 
	hostname="${1}-${3}"
	servicename="${1}-service-${3}"
	peerIP=""
	peerHost=""
	for((j=1; j<=$2; j++))
	do
	if [ ${j} -ne ${3} ];then
		if [ -z "${peerIP}" ];then
			peerHost="${1}-${j}"
		        peerIP="${1}-service-${j}.${namespaces}"
		else
			peerHost="${peerHost},${1}-${j}"
		        peerIP="${peerIP},${1}-service-${j}.${namespaces}"
		fi
	fi
	done

}

updataPodFile(){
echo "apiVersion: v1
kind: Pod
metadata:
  name: ${hostname}
  namespace: ${namespaces}
  labels:
    app: ${hostname}
spec:
  restartPolicy: Never
  containers:
  - name: ${hostname}
    image: opengauss:3.0.0
    imagePullPolicy: Never
    securityContext:
      runAsUser: 0
    volumeMounts:
    - mountPath: /var/lib/opengauss/data/
      name: openguass-volume
    ports:
    - containerPort: 5432
      name: opengauss
    env:
    - name: HOST_NAME
      value: ${hostname}
    - name: HOST_IP
      valueFrom:
        fieldRef:
          fieldPath: status.podIP
    - name: PEER_IPS
      value: ${peerIP}
    - name: PEER_HOST_NAMES
      value: ${peerHost}
    - name: PORT
      value: \"5432\"
    - name: GS_PASSWORD
      value: \"${passwd}\"
    - name: SERVER_MODE
      value: ${state}
    - name: db_config
      value: ${db_config}
  volumes:
  - name: openguass-volume
    hostPath:
      path: /data/${hostname}/
      type: DirectoryOrCreate
     

---
" >> "${namespaces}-pod.yaml"
}

updataSVCFile(){
echo "
apiVersion: v1
kind: Service
metadata:
  namespace: ${namespaces}
  name: ${servicename}
spec:
  ports:
  - port: 5432
    protocol: TCP
    targetPort: 5432
    name: gsql
  - port: 5434
    protocol: TCP
    targetPort: 5434
    name: localport
  - port: 2380
    protocol: TCP
    targetPort: 2380
    name: etcd1-service
  - port: 2379
    protocol: TCP
    targetPort: 2379
    name: etcd1-local
  selector:
    app: ${hostname}
  clusterIP: None

---
" >> "${namespaces}-service.yaml"
}

createHA(){
echo "
apiVersion: v1
kind: Pod
metadata:
  name: ${name}-ha
  namespace: ${namespaces}
spec:
  containers:
  - name: ${name}-ha
    image: haproxy:1.0.0
    ports:
    - containerPort: 7000
      name: ${name}
    env:
    - name: ports
      value: \"${haPorts}\"
    - name: ips
      value: \"${ips}\"
" > "${namespaces}-ha.yaml"
}

#name:project's name 
#num:database's mumber 
#namespaces:namespaces 
#passwd:passwd 
#db_config:database's config

name="$1";
num="$2";
namespaces="$3";
passwd="$4";
db_config="$5";

if [ ${num} -lt 3 ] || [ ${num} -gt 9 ];then
    echo "The number of databases in a single slice must be greater than 3 and less than 9"
    exit
fi

#delete all pod
kubectl delete --all pods --namespace=${namespaces}
kubectl delete --all svc --namespace=${namespaces}

#create namespace config file
echo "
apiVersion: v1
kind: Namespace
metadata:
  name: ${namespaces}
" > "${namespaces}.yaml"

#create namespace
kubectl create -f "${namespaces}.yaml"

#delelte patroni config file
sudo rm -rf "${namespaces}-pod.yaml"
sudo rm -rf "${namespaces}-service.yaml"
#create patroni config file
for ((i=1; i<=$num; i++))
do
if [ ${i} -eq 1 ];then
	state="primary"
	haPorts="5432"
else
	state="standby"
	haPorts="${haPorts},5432"
fi
getPara $1 $2 ${i}

updataPodFile
updataSVCFile


done
#create pod/svc
sudo kubectl create -f "${namespaces}-service.yaml"
sudo kubectl create -f "${namespaces}-pod.yaml"


#get opengauss IPs
sleep 20s
res=`sudo kubectl get pod -n ${namespaces} -o wide`
result=`echo $res | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'`
ips=`echo ${result} | sed 's/[ ][ ]*/,/g'`

createHA

sudo kubectl create -f "${namespaces}-ha.yaml"
