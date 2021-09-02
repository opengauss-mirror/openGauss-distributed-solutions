#!/bin/bash

#name:project's name 
#sharding_num:database sharding's number 
#patroni_num:database's mumber 
#db_config:database's config
name="$1";
sharding_num="$2";
patroni_num="$3";
db_config="$4";

if [ ${patroni_num} -lt 3 ] || [ ${patroni_num} -gt 9 ];then
    echo "The number of databases in a single slice must be greater than 3 and less than 9"
    exit
fi

stty -echo
read -p "input openGauss password：" PASSWD
echo ""
read -p "input openGauss password again：" PASSWD_AGAIN
echo ""
stty echo

if [ -z "${PASSWD}" ]; then
    echo "password is empty"
    exit
fi

if [ "${PASSWD}" != "${PASSWD_AGAIN}" ];then
        echo "The two passwords are different"
        exit
fi


sudo rm -rf user_input.yaml

echo "
#dataSources:
#	- ip1 port1 database1 user1 password1
#	- ip2 port2 database2 user2 password2
#	- ip3 port3 database3 user3 password3
#tables:
#	- table1 shard_database_field shard_database_num shard_table_field shard_table_num
#       - table2 shard_database_field shard_database_num shard_table_field shard_table_num
#       - table3 shard_database_field shard_database_num shard_table_field shard_table_num
dataSources:" > user_input.yaml	

for ((i=1; i<=$sharding_num; i++))
do
{

	sudo sh patroni.sh "${name}-${i}" $patroni_num "${name}-${i}" $PASSWD "${db_config}"
	sleep 10s
	res=`sudo kubectl get pod -n "${name}-${i}" -o wide | grep "${name}-${i}-ha"`
	result=`echo $res | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}'`
	echo "    - ${result} 5000 postgres admin ${PASSWD}" >> user_input.yaml
}&
done
wait
echo "tables:" >> user_input.yaml


