#!/bin/bash

# A simple deployment helper for OpenStack installations.
# Brought to you by Rackspace Cloudbuilders.
#
# This script sets up two lxc containers.  The first of these is used to run
# a Chef server.  The second runs a DHCP/preseed server.
#
# apt-cacher is used to keep from having to download apt packages remotely
# each time a container is built.
#
# Before running this script you should have set up a bridged network.
# Example, assuming wlan0 is your active interface:
#    brctl addbr br0
#    brctl setfd br0 0
#    ifconfig br0 up IP.FROM.PRIMARY.WLAN0 promisc
#    brctl addif br0 wlan0
#    ifconfig wlan0 0.0.0.0 up
#    route add -net default gw GATEWAY.FROM.NESTAT.-r br0
#
# Configuration is done via environment variables.  Listed are the variables
# and their defaults:
#
#    DHCP_LOW=8.21.28.242
#    DHCP_HIGH=8.21.28.250
#    NETMASK=255.255.255.0
#    GATEWAY=8.21.28.1
#    CGROUP_DIR=/var/lib/cgroups
#    MY_IP=(taken from br0 interface at runtime)
#    chef_host=8.21.28.240
#    dhcp_host=8.21.28.241
#    SSH_ID=~/.ssh/id_builder
#    TEMPLATE=ubuntu
#
# This script performs the following actions:
#    1) Setup this host
#       a) cache apt packages
#       b) generate a ssh key
#       c) set up control group for lxc
#    2) Create containers for required components
#       a) Chef
#       b) Dhcp/Pxe/Preseed
#
# TODO
#    * Where does the 10.127.48.40 address for builder come from: not $dhcp_host
#    * Stop catting the files out of a shell script.  This is a git repo.
#    * Can we use knife to setup lxc containers?  Can spin up vms with it.
#    * lvmok, primary, bootable variables used in preseed.conf generation
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
if [ ! -x /usr/share/doc/apt-cacher ]; then
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
cp ${ASSETS}/builder.conf /var/lib/builder.conf

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
    cat > ${ROOTFS}/etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

auto eth0
iface eth0 inet static
      address $IP
      netmask $NETMASK
      gateway $GATEWAY
EOF

    # set up a sane ubuntu repo in the container
    cat > ${ROOTFS}/etc/apt/sources.list <<EOF
deb http://$MY_IP:3142/mirrors.us.kernel.org/ubuntu maverick main universe
EOF

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
    if ( ! ping -W10 -c1 $IP ); then
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
ssh_it "root@${chef_host}" "apt-get install -y ruby ruby-dev libopenssl-ruby rdoc ri irb build-essential wget ssl-cert rubygems"
ssh_it "root@${chef_host}" "gem install chef -y --no-ri --no-rdoc"

TMPDIR=`mktemp -d`

cat > ${TMPDIR}/chef.json <<EOF
{
"bootstrap": {
"chef": {
"url_type": "http",
"init_style": "runit",
"path": "/srv/chef",
"serve_path": "/srv/chef",
"server_fqdn": "chef.`hostname -d`",
"webui_enabled": true
}
},
"run_list": [ "recipe[chef::bootstrap_server]" ]
}
EOF

mkdir -p /var/lib/lxc/chef/rootfs/etc/chef
cp ${ASSETS}/solo.rb /var/lib/lxc/chef/rootfs/etc/chef/
cp ${TMPDIR}/chef.json /var/lib/lxc/chef/rootfs/etc/chef/chef-bootstrap.json

if [ "${TMPDIR}" = "" ]; then
    echo "Close one"
    exit 1
fi

rm -rf "${TMPDIR}"
ssh_it "root@${chef_host}" "/var/lib/gems/1.8/bin/chef-solo -c /etc/chef/solo.rb -j /etc/chef/chef-bootstrap.json -r http://s3.amazonaws.com/chef-solo/bootstrap-latest.tar.gz"

# push up the cookbooks

ssh_it "root@${chef_host}" "apt-get install -y git-core"
ssh_it "root@${chef_host}" "cd /root; git clone https://github.com/openstack/openstack-cookbooks.git"
ssh_it "root@${chef_host}" "ln -s /var/lib/gems/1.8/bin/knife /usr/bin/"
ssh_it "root@${chef_host}" "knife configure -i -y --defaults -r='' -u openstack"
ssh_it "root@${chef_host}" "knife cookbook upload -o /root/openstack-cookbooks/cookbooks -a"

# Chef is done - install dhcp server
ssh_it "root@${dhcp_host}" "apt-get install -y dnsmasq nginx syslinux"
ROOTFS=/var/lib/lxc/dhcp/rootfs

mkdir -p ${ROOTFS}/var/lib/builder
touch ${ROOTFS}/var/lib/builder/hosts.mac

cat > ${ROOTFS}/etc/dnsmasq.conf <<EOF
enable-tftp
tftp-root=/var/lib/builder/tftpboot

interface=eth0
dhcp-no-override
dhcp-hostsfile=/var/lib/builder/hosts.macs
dhcp-boot=pxelinux.0
dhcp-range=eth0,$DHCP_LOW,$DHCP_HIGH,255.255.255.0
EOF

mkdir -p ${ROOTFS}/var/lib/builder/tftpboot
cat > ${ROOTFS}/var/lib/builder/tftpboot/pxelinux.cfg <<EOF
TIMEOUT 1
ONTIMEOUT maverick

LABEL maverick
        MENU LABEL ^Install Maverick
        MENU DEFAULT
        kernel ubuntu-installer/amd64/linux
        append tasksel:tasksel/first="" vga=3841 locale=en_US setup/layoutcode=en_US console-setup/layoutcode=us netcfg/get_hostname=openstack initrd=ubuntu-installer/amd64/initrd.gz preseed/url=http://10.127.48.40/preseed.txt -- console=tty interface=eth0 netcfg/dhcp_timeout=60
EOF

mkdir -p ${ROOTFS}/var/lib/builder/www
cp ${SSH_ID}.pub ${ROOTFS}/var/lib/builder/www/id_dsa.pub
cat > ${ROOTFS}/var/lib/builder/www/preseed.txt <<EOF
d-i pkgsel/install-language-support boolean false
d-i debian-installer/locale string en_US
d-i console-setup/ask_detect boolean false
d-i console-setup/layoutcode string us
d-i clock-setup/utc boolean true
d-i time/zone string UTC

d-i clock-setup/ntp boolean true

d-i netcfg/choose_interface select auto
d-i netcfg/dhcp_timeout string 120
d-i netcfg/get_hostname string os
d-i netcfg/get_domain string openstack.org

d-i mirror/country string manual
d-i mirror/http/directory string /ubuntu
d-i mirror/http/hostname string $MY_IP:3142
d-i mirror/http/proxy string

d-i passwd/root-login boolean true
d-i passwd/root-password password 0penstack
d-i passwd/root-password-again password 0penstack

d-i passwd/make-user boolean false
d-i user-setup/encrypt-home boolean false

d-i pkgsel/include string openssh-server screen vim-nox
d-i pkgsel/update-policy select none

d-i grub-installer/only_debian boolean true
d-i grub-installer/with_other_os boolean true
d-i grub-installer/bootdev string /dev/sdc
d-i finish-install/reboot_in_progress note

d-i partman-auto/disk string /dev/sda /dev/sdb /dev/sdc

d-i partman-auto/method string lvm
d-i partman-auto-lvm/guided_size string max
d-i partman-lvm/device_remove_lvm boolean true
d-i partman-lvm/device_remove_lvm_span boolean true
d-i partman-auto/purge_lvm_from_device boolean true
d-i partman-md/device_remove_md boolean true
d-i partman-auto-lvm/new_vg_name string raid
d-i partman-lvm/confirm boolean true

d-i partman-auto/expert_recipe string                           \
        boot-root ::                                            \
                40 1 100 ext3                                   \
                        $primary{ } $bootable{ }                \
                        method{ format } format{ }              \
                        use_filesystem{ } filesystem{ ext3 }    \
                        mountpoint{ /boot }                     \
                .                                               \
                10240 2 500000 ext4                             \
                        $lvmok{ }                               \
                        method{ format } format{ }              \
                        use_filesystem{ } filesystem{ ext4 }    \
                        mountpoint{ / }                         \
                .                                               \
                1024 3 120% linux-swap                          \
                        $lvmok{ }                               \
                        method{ swap } format{ }                \
                .

d-i partman/confirm_write_new_label boolean true
d-i partman/choose_partition select Finish partitioning and write changes to disk
d-i partman/confirm boolean true

d-i pkgsel/install-pattern string ~t^ubuntu-standard$

d-i preseed/late_command string in-target mkdir -p /root/.ssh; in-target chmod 700 /root/.ssh; in-target wget -O /root/.ssh/authorized_keys http://$MY_IP/id_dsa.pub
EOF

mkdir -p ${ROOTFS}/etc/nginx/sites-enabled
cp ${ASSETS}/nginx.conf ${ROOTFS}/etc/nginx/sites-enabled/default
