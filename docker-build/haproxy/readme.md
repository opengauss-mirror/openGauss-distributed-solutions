haproxy镜像构建

在当前目录中执行下面的命令用于构建haproxy镜像

```
docker build -t haproxy:1.0.0 -f dockerfile .
```

haproxy进行单独运行示例

对应一主三备

```
docker run --name haproxy_1_master_3_slaves --network opengaussnetwork -p 7000:7000 -p 5000:5000 -p 5001:5001 -d -e ips="173.11.0.101,173.11.0.102,173.11.0.103,173.11.0.104" -e ports="5432,5432,5432,5432" haproxy:1.0.0
```

进入镜像里面

```
docker exec -it haproxy_1_master_3_slaves /bin/bash
```

