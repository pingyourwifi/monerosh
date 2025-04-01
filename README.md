# [Fuck Spaceship](https://www.spaceship.com)

# 停止服务<br>
sudo systemctl disable starlight-agent.service <br>

# 禁止开机自启<br>
sudo systemctl stop starlight-agent.service     <br>
# 相关目录<br>
配置文件目录：/etc/systemd/system/conf.d/  <br>
系统服务目录：/etc/systemd/system/   <br>
# 禁用系统监控以及log日志  <br>
# 删除非原有服务
sudo systemctl stop iscsi.service
sudo systemctl disable iscsi.service
sudo rm /etc/systemd/system/iscsi.service

sudo systemctl stop rpcbind.service
sudo systemctl disable rpcbind.service
sudo rm /etc/systemd/system/rpcbind.service

sudo systemctl stop vmtoolsd.service
sudo systemctl disable vmtoolsd.service
sudo rm /etc/systemd/system/vmtoolsd.service

sudo systemctl stop starlight-agent.service
sudo systemctl disable starlight-agent.service
sudo rm /etc/systemd/system/starlight-agent.service
sudo rm -r /etc/systemd/system/starlight-agent.service.d

sudo rm -r /etc/systemd/system/cloud-final.service.wants
sudo rm -r /etc/systemd/system/cloud-init.target.wants
sudo rm -r /etc/systemd/system/mdmonitor.service.wants
sudo rm -r /etc/systemd/system/open-vm-tools.service.requires

sudo systemctl daemon-reload

# 禁用日志生成
sudo systemctl stop rsyslog
sudo systemctl disable rsyslog
sudo sed -i 's/#Storage=auto/Storage=none/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
