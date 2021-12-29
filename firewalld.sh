#!/bin/bash

# {
#     "insecure-registries":[
#         "172.18.241.158:8889",
#         "172.18.241.180:8888",
#         "172.18.241.182:8888"
#     ],
#     "default-address-pools":[
#         {
#             "base":"173.20.0.1/16",
#             "size":24
#         }
#     ]
# }

# 以下地方需要修改

# 后端服务器地址，以空格分开,可改为网段如172.18.241.181/24
server_ips="172.17.72.231 172.17.72.232 172.17.72.233"
# 负载均衡地址，不可以写域名，需要写域名实际解析的地址，也以空格分开
lb_ips="172.17.228.209"

# 需要对所有主机都开放的端口
tcp_ports="22 8080 8081 8082 8889 6061 10000"
udp_ports=""
# docker网段
docker_range="173.16.0.0/8"
# flannel网段
cni_range="10.244.0.0/8"


# 以下地方禁止修改

# 开启k8s端口
k8s_tcp_ports="6443 2379-2380 10250-10255 53 9153 30000-32767 443 15010-15020"
k8s_udp_ports="8472 443 53"

# 根据ip获取网卡名称
ipaddress=$(ip r get 1 | awk 'NR==1 {print $NF}')
net_name=$(ip r get 1|awk "/$ipaddress/ {print \$5}")

# 获取docker0ip
docker0_ip=$(ip addr show docker0|grep "inet\b"|awk '{print $2}')

# 首先开启firewalld
systemctl restart firewalld
systemctl enable firewalld

# 修改firewalld默认可用区
firewall-cmd --set-default-zone=trusted

# 移除掉DOCKER-USER并新建一个(这步非常重要，即便DOCKER-USER存在，也要执行删除。不然不生效)
firewall-cmd --permanent --direct --remove-rules ipv4 filter DOCKER-USER
firewall-cmd --permanent --direct --remove-chain ipv4 filter DOCKER-USER
firewall-cmd --permanent --direct --add-chain ipv4 filter DOCKER-USER

# 添加规则，注意REJECT规则一定要在最后执行，同时注意不建议多个IP地址写在同一条规则，格式上没有问题，但是通过iptables -L确认时，顺序会打乱。导致先被REJECT

# Docker Container <-> Container communication
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -i docker0 -o $net_name -j ACCEPT -m comment --comment "allows docker to $net_name"
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT -m comment --comment 'Allow docker containers to connect to the outside world'


# 允许后端服务器之间的所有流量
for server_ip in $server_ips
do
  firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -m multiport -p tcp --dports 1:65535 -s $server_ip -j ACCEPT -m comment --comment "Allow $server_ip to docker all ports"
  firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -m multiport -p udp --dports 1:65535 -s $server_ip -j ACCEPT -m comment --comment "Allow $server_ip to docker all ports"
  firewall-cmd --permanent --add-source=$server_ip
done

# 允许lb的所有流量
for lb_ip in $lb_ips
do
  firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -m multiport -p tcp --dports 1:65535 -s $lb_ip -j ACCEPT -m comment --comment "Allow $lb_ip to docker all ports"
  firewall-cmd --permanent --add-source=$lb_ip
done

firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -m multiport -p tcp --dports 1:65535 -s $docker_range -j ACCEPT -m comment --comment "Allow $docker_range to docker all ports"
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -m multiport -p udp --dports 1:65535 -s $docker_range -j ACCEPT -m comment --comment "Allow $docker_range to docker all ports"

firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -m multiport -p udp --dports 1:65535 -s $cni_range -j ACCEPT -m comment --comment "Allow $docker_range to docker all ports"
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -m multiport -p tcp --dports 1:65535 -s $cni_range -j ACCEPT -m comment --comment "Allow $docker_range to docker all ports"

firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -j RETURN -s $docker_range -m comment --comment 'allow internal docker communication'
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 0 -j RETURN -s $cni_range -m comment --comment 'allow internal docker communication'
firewall-cmd --permanent --direct --add-rule ipv4 filter DOCKER-USER 1 -j REJECT -m comment --comment 'reject all other traffic to DOCKER-USER'

# 指定public开通端口页面访问的端口
for port in $tcp_ports
do
  firewall-cmd --zone=public --permanent --add-port=$port/tcp
done

for port in $udp_ports
do
  firewall-cmd --zone=public --permanent --add-port=$port/udp
done

for port in $k8s_tcp_ports
do
  firewall-cmd --zone=public --permanent --add-port=$port/tcp
done

for port in $k8s_udp_ports
do
  firewall-cmd --zone=public --permanent --add-port=$port/udp
done

firewall-cmd --permanent --zone=trusted --change-interface=cni0
firewall-cmd --permanent --zone=trusted --change-interface=docker0

# 永久保存
firewall-cmd --zone=public  --add-masquerade --permanent

# 重新加载
firewall-cmd --reload

