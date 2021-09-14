#!/bin/bash -e
# config
#!/bin/bash
set -Eeo pipefail
if [ ! -f "/tmp/config-sharding.yaml" ]; then
        cat >&2 <<-'EOE'
                        Error: Config file dose not exist!

EOE
        exit 1
fi
cp /tmp/config-sharding.yaml ${PROXY_PATH}/conf/config-sharding.yaml -f
if [ -f "/tmp/server.yaml" ]; then
        cp /tmp/server.yaml ${PROXY_PATH}/conf/server.yaml -f
fi
if [ -f "/tmp/config-database-discovery.yaml" ]; then
        cp /tmp/config-database-discovery.yaml ${PROXY_PATH}/conf/config-database-discovery.yaml -f
fi
if [ -f "/tmp/config-encrypt.yaml" ]; then
        cp /tmp/config-encrypt.yaml ${PROXY_PATH}/conf/config-encrypt.yaml -f
fi
if [ -f "/tmp/config-readwrite-splitting.yaml" ]; then
        cp /tmp/config-readwrite-splitting.yaml ${PROXY_PATH}/conf/config-readwrite-splitti.yaml -f
fi
if [ -f "/tmp/config-shadow.yaml" ]; then
        cp /tmp/config-shadow.yaml ${PROXY_PATH}/conf/config-shadow.yaml -f
fi
if [ -f "/tmp/logback.xml" ]; then
        cp /tmp/logback.xml ${PROXY_PATH}/conf/logback.xml -f
fi
if [ -f "/tmp/scaling_server.yaml" ]; then
        cp /tmp/scaling_server.xml ${SCALING_PATH}/conf/server.xml -f
fi

nohup ${ZOOKEEPER_PATH}/bin/zkServer.sh start &
sleep 3
nohup ${SCALING_PATH}/bin/start.sh server &
${PROXY_PATH}/bin/start.sh && tail -f ${PROXY_PATH}/logs/stdout.log
