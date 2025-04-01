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
sudo systemctl stop iscsi.service<br>
sudo systemctl disable iscsi.service<br>
sudo rm /etc/systemd/system/iscsi.service<br>

sudo systemctl stop rpcbind.service<br>
sudo systemctl disable rpcbind.service<br>
sudo rm /etc/systemd/system/rpcbind.service<br>

sudo systemctl stop vmtoolsd.service<br>
sudo systemctl disable vmtoolsd.service<br>
sudo rm /etc/systemd/system/vmtoolsd.service<br>

sudo systemctl stop starlight-agent.service<br>
sudo systemctl disable starlight-agent.service<br>
sudo rm /etc/systemd/system/starlight-agent.service<br>
sudo rm -r /etc/systemd/system/starlight-agent.service.d<br>

sudo rm -r /etc/systemd/system/cloud-final.service.wants<br>
sudo rm -r /etc/systemd/system/cloud-init.target.wants<br>
sudo rm -r /etc/systemd/system/mdmonitor.service.wants<br>
sudo rm -r /etc/systemd/system/open-vm-tools.service.requires<br>

sudo systemctl daemon-reload<br>

# 禁用日志生成
sudo systemctl stop rsyslog<br>
sudo systemctl disable rsyslog<br>
sudo sed -i 's/#Storage=auto/Storage=none/' /etc/systemd/journald.conf<br>
sudo systemctl restart systemd-journald<br>
