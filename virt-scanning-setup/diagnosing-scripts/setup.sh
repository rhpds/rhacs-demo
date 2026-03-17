sudo subscription-manager register --username=michael.foster2011 --password='pmb!qnj@uek6dud-PMN'
sudo subscription-manager release --set=9.4
sudo subscription-manager repos \
  --enable=rhel-9-for-x86_64-baseos-eus-rpms \
  --enable=rhel-9-for-x86_64-appstream-eus-rpms
sudo dnf clean all
sudo dnf update -y

# Download for amd64 (x86_64) - this matches your RHEL virtualization box
curl -L -f -o roxagent https://mirror.openshift.com/pub/rhacs/assets/4.9.0/bin/linux/roxagent

# Make it executable and move to PATH
chmod +x roxagent
sudo mv roxagent /usr/local/bin/
sudo /usr/local/bin/roxagent --daemon 


sudo dnf install httpd socat firewalld -y
sudo systemctl start firewalld
sudo systemctl enable firewalld
sudo firewall-cmd --state 
sudo systemctl start httpd
sudo systemctl enable httpd
sudo systemctl status httpd
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https
sudo firewall-cmd --reload



# Download the latest roxagent binary
curl -L -f -o /tmp/roxagent https://mirror.openshift.com/pub/rhacs/assets/4.10.0/bin/linux/roxagent
chmod +x /tmp/roxagent
sudo mv /tmp/roxagent /usr/local/bin/roxagent

# Create a systemd service for roxagent as a background daemon
cat <<EOF | sudo tee /etc/systemd/system/roxagent.service > /dev/null
[Unit]
Description=RHACS roxagent Daemon
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/roxagent --daemon
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd, enable, and start roxagent as a background service
sudo systemctl daemon-reload
sudo systemctl enable roxagent
sudo systemctl start roxagent

# Install httpd and firewalld using DNF
sudo dnf install -y httpd firewalld

# Start and enable firewalld
sudo systemctl start firewalld
sudo systemctl enable firewalld

# Allow HTTP and HTTPS traffic through the firewall
sudo firewall-cmd --permanent --add-service=http
sudo firewall-cmd --permanent --add-service=https

# Allow VSOCK (firewalld custom) - VSOCK typically uses AF_VSOCK and is not governed by TCP/UDP ports.
# However, if the roxagent or your configuration uses socat with TCP fallback, open relevant ports (e.g., 8443 or custom)
# Example for TCP port 8443 (as commonly used for RHACS communication when vsock is port-forwarded or proxied):
sudo firewall-cmd --permanent --add-port=8443/tcp

# You may also need the following if you use socat for vsock:
sudo firewall-cmd --permanent --add-port=5000-6000/tcp

# Reload firewall to apply changes
sudo firewall-cmd --reload

# Start and enable the Apache web server
sudo systemctl start httpd
sudo systemctl enable httpd

# Print status for verification
sudo systemctl status httpd --no-pager



Diagnostics:
oc get vmi rhel-webserver -n default -o yaml | grep -i vsock
[cloud-user@rhel-webserver ~]$
      autoattachVSOCK: true
  VSOCKCID: 964183457

ncat -zv --vsock 2 818 
[cloud-user@rhel-webserver ~]$ ID 2 port 818 failed"erver ~]$ ncat -zv --vsock 2 818 || echo "ncat vsock connect to CID 2 port 818 failed"
Ncat: Version 7.92 ( https://nmap.org/ncat )
Ncat: Connection reset by peer.

ls /dev/vsock*
[cloud-user@rhel-webserver ~]$ /dev/vsock

lsmod | grep -i vsock
[cloud-user@rhel-webserver ~]$ lsmod | grep -i vsock
vmw_vsock_virtio_transport    20480  0
vmw_vsock_virtio_transport_common    61440  1 vmw_vsock_virtio_transport
vsock                  69632  2 vmw_vsock_virtio_transport_common,vmw_vsock_virtio_transport

dmesg | grep -i vsock | tail -20
[cloud-user@rhel-webserver ~]$ dmesg | grep -i vsock | tail -20
[   14.236402] NET: Registered PF_VSOCK protocol family

ncat -v --vsock 2 818 
[cloud-user@rhel-webserver ~]$ ncat -v --vsock 2 818 
Ncat: Version 7.92 ( https://nmap.org/ncat )
Ncat: Connection reset by peer.

oc debug node/control-plane-cluster-hnqwm-1

chroot /host ss --vsock -lpn | grep -i 818

sh-5.1# chroot /host ss --vsock -lpn | grep -i 818
No reponse

chroot /host lsmod | grep -E 'vsock|vmw_vsock|virtio_vsock'
[cloud-user@rhel-webserver ~]$
vhost_vsock            24576  1
vmw_vsock_virtio_transport_common    61440  1 vhost_vsock
vsock                  69632  4 vmw_vsock_virtio_transport_common,vhost_vsock
vhost                  69632  2 vhost_vsock,vhost_net

sh-5.1# chroot /host ss --vsock -lpn
Netid           State            Recv-Q            Send-Q                       Local Address:Port                       Peer Address:Port           Process           
sh-5.1# 

chroot /host ps aux | grep -iE 'vsock|818'