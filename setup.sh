#!/bin/bash

# A simple deployment helper for OpenStack installations.
# Brought to you by Rackspace Cloudbuilders.
#
# This script must be run as root.
#
# This script sets up two lxc containers.  The first of these is used to run
# a Chef server.  The second runs a DHCP/preseed server.
#
# apt-cacher is used to keep from having to download apt packages remotely
# each time a container is built.  Enable with USE_APT_CACHER=1.
#
# Before running this script you should have set up a bridged network.
# Example, assuming eth0 is your active interface:
#    brctl addbr br0
#    brctl setfd br0 0
#    ifconfig br0 up IP.FROM.PRIMARY.ETH0 promisc
#    brctl addif br0 eth0
#    ifconfig eth0 0.0.0.0 up
#    route add -net default gw GATEWAY.FROM.NESTAT.-r br0
#
# Wireless networks take a bit different approach, in which you create a bridge
# and use masqurading to forward through your wireless interface.
#    brctl addbr br0
#    brctl setfd br0 0
#    ifconfig br0 up 10.5.5.5
#    brctl stp br0 no
#    iptables -t nat -A POSTROUTING -o wlan0 -j MASQUERADE
#    echo 1 > /proc/sys/net/ipv4/ip_forward
# (taken from http://box.matto.nl/lxconlaptop.html)
# My command looks like this: TEMPLATE=natty dhcp_host=10.5.5.6 chef_host=10.5.5.7 DHCP_LOW=10.5.5.10 DHCP_HIGH=10.5.5.80 GATEWAY=10.5.5.5 ./setup.sh
#
# Configuration is done via environment variables.  Listed are the variables
# and their defaults:
#
#    DHCP_LOW=8.21.28.242
#    DHCP_HIGH=8.21.28.250
#    NETMASK=255.255.255.0
#    GATEWAY=8.21.28.1
#    domain=`hostname -d`
#    CGROUP_DIR=/var/lib/cgroups
#    MY_IP=(taken from br0 interface at runtime)
#    chef_host=8.21.28.240
#    dhcp_host=8.21.28.241
#    SSH_ID=~/.ssh/id_builder
#    TEMPLATE=ubuntu
#    USE_APT_CACHER=0
#
# You may also want to change the root password that gets set by editing
# assets/preseed.txt
#
# This script performs the following actions:
#    1) Setup this host
#       a) cache apt packages (optional)
#       b) generate a ssh key
#       c) set up control group for lxc
#    2) Create containers for required components
#       a) Chef
#       b) Dhcp/Pxe/Preseed
#
# TODO
#    * Can we use knife to setup lxc containers?  Can spin up vms with it.
#    * determine if we need lxcguest package installed in the containers
#
# For more information about OpenStack, see: http://www.openstack.org/
# For more information about LXC containers, see: http://lxc.sourceforge.net/
# For more information about Chef, see: http://www.opscode.com/chef/

##
## Configuration
##

DHCP_LOW=${DHCP_LOW:-8.21.28.242}
DHCP_HIGH=${DHCP_HIGH:-8.21.28.250}

# can be calcualted
NETMASK=${NETMASK:-255.255.255.0}
GATEWAY=${GATEWAY:-8.21.28.1}

# these we should intuit
chef_host=${chef_host:-8.21.28.240}
dhcp_host=${dhcp_host:-8.21.28.241}

# this is only created if a cgroup isn't already mounted
CGROUP_DIR=${CGROUP_DIR:-/var/lib/cgroups}

# broken!
MY_IP=`/sbin/ifconfig br0 | grep "inet " | cut -d ':' -f2 | cut -d ' ' -f1`

SSH_ID=${SSH_ID:-~/.ssh/id_builder}
TEMPLATE=${TEMPLATE:-ubuntu}
USE_APT_CACHER=${USE_APT_CACHER:-0}
domain=${domain:-`hostname -d`}

##
## Function definitions
##

function ssh_it {
   ssh -i ${SSH_ID} -o StrictHostKeyChecking=no $1 "$2"
}

##
## Configure runtime
##

# abort on command failure
set -e

# display conditions
set -x

ASSETS=`dirname $0`/assets

##
## BEGIN SCRIPT
##

# Remove stale containers
for d in chef dhcp; do lxc-stop -n $d; rm -rf /var/lib/lxc/$d; done


# Setup caching of apt packages
if [ ! -x /usr/share/doc/apt-cacher -a "${USE_APT_CACHER}" -eq 1 ]; then
    apt-get install -y apt-cacher apache2
    sed -i -e 's/^#*AUTOSTART.*/AUTOSTART=1/' /etc/default/apt-cacher
    /etc/init.d/apt-cacher restart
fi

# Install pre-reqs
apt-get install -y lxc debootstrap bridge-utils libcap2-bin dsh

# Mount (maybe make) control group info
if ( ! grep -q cgroup /etc/mtab ); then
    mkdir -p ${CGROUP_DIR} 
    mount -t cgroup cgroup ${CGROUP_DIR}
fi

# Make container home
mkdir -p /var/lib/lxc

# Set up networking configuration (bridged veth)
cp ${ASSETS}/builder.conf /var/lib/lxc/builder.conf

# Create a passwordless key to ssh into the containers
if [ ! -f ${SSH_ID} ]; then
    ssh-keygen -d -P "" -f ${SSH_ID}
fi

# Build ubuntu-styled containers with networking as configured above
# assigning ip as configured (or defaulted) with CONTAINER_host variable
for d in dhcp chef; do
    ROOTFS=/var/lib/lxc/${d}/rootfs
    if [ ! -x ${ROOTFS} ]; then
        lxc-create -n ${d} -f /var/lib/lxc/builder.conf -t ${TEMPLATE}
    fi
    var=\$${d}_host
    IP=`eval echo $var`
    echo Setting ip of ${d} continer to ${IP}
    cat ${ASSETS}/interfaces | sed -e "s^{IP}^${IP}^" \
                             | sed -e "s^{NETMASK}^${NETMASK}^" \
                             | sed -e "s^{GATEWAY}^${GATEWAY}^" \
                             > ${ROOTFS}/etc/network/interfaces

    # set up a sane ubuntu repo in the container
	if [ "${USE_APT_CACHER}" == "1" ] ; then
        cat ${ASSETS}/sources.list | sed -e "s^{IP}^${MY_IP}^" \
                                   > ${ROOTFS}/etc/apt/sources.list
	fi

    # working resolver in the container (Google's DNS)
    rm -f ${ROOTFS}/etc/resolv.conf
    cp ${ASSETS}/resolv.conf ${ROOTFS}/etc/resolv.conf

    # drop the builder ssh key in
    mkdir -p ${ROOTFS}/root/.ssh
    chmod 700 ${ROOTFS}/root/.ssh
    cp ${SSH_ID}.pub ${ROOTFS}/root/.ssh/authorized_keys
    chmod 600 ${ROOTFS}/root/.ssh/authorized_keys

    # NOTE(todd): I don't know what this is?!
    if [ ! -f /etc/dsh-builder.conf ]; then
        touch /etc/dsh-builder.conf
        chmod 600 /etc/dsh-builder.conf
    fi

    if ( ! grep -q ${IP} /etc/dsh-builder.conf ); then
        echo $USER@$IP >> /etc/dsh-builder.conf
    fi

    # Let root ssh into the continers using a key
    sed -i -e 's/^#*PermitRoot.*/PermitRootLogin without-password/' ${ROOTFS}/etc/ssh/sshd_config

    # Start the container
    lxc-start -dn ${d}

    # Wait for machine to come up
    if ( ! ping -W30 -c1 $IP ); then
        echo "Can't start server.  Bad."
        exit 1
    fi

    # Install packages common to each container
    ssh_it "root@${IP} apt-get update"
    ssh_it "root@${IP} apt-get install -y --force-yes ubuntu-keyring netbase gnupg"
    ssh_it "root@${IP} apt-get update"

    # TODO(todd): see if this should include lxcguest
done


# Install packages on the chef host.
ssh_it "root@${chef_host}" "apt-get install -y ruby ruby-dev libopenssl-ruby rdoc ri irb build-essential wget ssl-cert rubygems curl"
ssh_it "root@${chef_host}" "gem install chef -y --no-ri --no-rdoc"

mkdir -p /var/lib/lxc/chef/rootfs/etc/chef
cp ${ASSETS}/solo.rb /var/lib/lxc/chef/rootfs/etc/chef/
cat ${ASSETS}/chef.json | sed -e "s^{DOMAIN}^${domain}^" \
                        > /var/lib/lxc/chef/rootfs/etc/chef/chef-bootstrap.json

ssh_it "root@${chef_host}" "ln -s /var/lib/gems/1.8/bin/knife /usr/bin/"
ssh_it "root@${chef_host}" "ln -s /var/lib/gems/1.8/bin/chef-solr-installer /usr/bin/"
ssh_it "root@${chef_host}" "/var/lib/gems/1.8/bin/chef-solo -c /etc/chef/solo.rb -j /etc/chef/chef-bootstrap.json -r http://s3.amazonaws.com/chef-solo/bootstrap-latest.tar.gz"

# push up the cookbooks

ssh_it "root@${chef_host}" "apt-get install -y git-core"
ssh_it "root@${chef_host}" "cd /root; git clone https://github.com/openstack/openstack-cookbooks.git"
ssh_it "root@${chef_host}" "knife configure -i -y --defaults -r='' -u openstack"
ssh_it "root@${chef_host}" "knife cookbook upload -o /root/openstack-cookbooks/cookbooks -a"

# Chef is done - install dhcp server
ssh_it "root@${dhcp_host}" "apt-get install -y dnsmasq nginx syslinux"
ROOTFS=/var/lib/lxc/dhcp/rootfs

mkdir -p ${ROOTFS}/var/lib/builder
touch ${ROOTFS}/var/lib/builder/hosts.mac

cat ${ASSETS}/dnsmasq.conf | sed -e "s^{DHCP_LOW}^${DHCP_LOW}^" \
                           | sed -e "s^{DHCP_HIGH}^${DHCP_HIGH}^" \
                           > ${ROOTFS}/etc/dnsmasq.conf

mkdir -p ${ROOTFS}/var/lib/builder/tftpboot
cat ${ASSETS}/pxelinux.cfg | sed -e "s^{IP}^${dhcp_host}^" \
                           > ${ROOTFS}/var/lib/builder/tftpboot/pxelinux.cfg

mkdir -p ${ROOTFS}/var/lib/builder/www
cp ${SSH_ID}.pub ${ROOTFS}/var/lib/builder/www/id_dsa.pub

cat ${ASSETS}/preseed.txt | sed -e "s^{IP}^${MY_IP}^" \
                          > ${ROOTFS}/var/lib/builder/www/preseed.txt

mkdir -p ${ROOTFS}/etc/nginx/sites-available
cp ${ASSETS}/nginx.conf ${ROOTFS}/etc/nginx/sites-available/default
