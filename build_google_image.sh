#!/bin/sh

set -e

# Script to create images for use in Google Cloud Compute

###############################
# tweak these to taste

# release to use
VERSION=10.1-RELEASE
# see truncate(1) for acceptable sizes
VMSIZE=10g
# size passed to mkimg(1)
SWAPSIZE=1G

# which bucket to upload to
MYBUCKET=swills-test-bucket
TS=`env TZ=UTC date +%Y%m%d%H%M%S`
IMAGENAME=`echo FreeBSD-${VERSION}-amd64-${TS} | tr '[A-Z]' '[a-z]' | sed -e 's/\.//g'`
BUCKETFILE=FreeBSD-${VERSION}-amd64-${TS}.tar.gz

TMPFILE=FreeBSD-${VERSION}-amd64-gcloud-image-${TS}.raw

# which OS components to install, base doc games kernel lib32 ports src

COMPONENTS="base kernel"

###############################

BASEDIR=$(dirname $0)
WRKDIR=${PWD}

# ensure commands we need are installed

ensureinstalled() {
  set +e
  hash $1 > /dev/null 2>&1
  if [ $? -ne 0 ]; then
    set -e
    /usr/bin/env ASSUME_ALWAYS_YES=yes pkg install -y $2
  fi
  set -e
}

fetchcomp() {
  if [ ! -f ${1}.txz ]; then
    fetch http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64/${VERSION}/${1}.txz
  fi
}

ensureinstalled bar bar
ensureinstalled gcloud google-cloud-sdk

# fetch OS components
mkdir -p ${VERSION}
cd ${VERSION}

for comp in ${COMPONENTS} ; do
  fetchcomp ${comp}
done

cd ${WRKDIR}

truncate -s ${VMSIZE} ${TMPFILE}
MD_UNIT=$(mdconfig -f ${TMPFILE})

newfs -j ${MD_UNIT}

mkdir -p /mnt/g/new

mount /dev/${MD_UNIT} /mnt/g/new

cd /mnt/g/new
for comp in ${COMPONENTS} ; do
  bar -n ${WRKDIR}/${VERSION}/${comp}.txz   | tar -xzf -
done

# temporarily use the local systems resolv.conf so packages can be installed
cp /etc/resolv.conf etc/resolv.conf

yes | chroot . usr/bin/env ASSUME_ALWAYS_YES=yes usr/sbin/pkg install sudo google-daemon firstboot-freebsd-update firstboot-pkgs panicmail
chroot . usr/bin/env ASSUME_ALWAYS_YES=yes usr/sbin/pkg clean -ya
chroot . usr/sbin/pw lock root

rm -rf var/db/pkg/repo*

cat << EOF > etc/resolv.conf
search google.internal
nameserver 169.254.169.254
nameserver 8.8.8.8
EOF

cat << EOF > etc/fstab
# Custom /etc/fstab for FreeBSD VM images
/dev/gpt/rootfs   /       ufs     rw      1       1
/dev/gpt/swapfs   none    swap    sw      0       0
EOF

cat << EOF > etc/rc.conf
console="comconsole"
dumpdev="AUTO"
ifconfig_vtnet0="SYNCDHCP mtu 1460"
ntpd_sync_on_start="YES"
ntpd_enable="YES"
sshd_enable="YES"
google_accounts_manager_enable="YES"
firstboot_freebsd_update_enable="YES"
firstboot_pkgs_enable="YES"
firstboot_pkgs_list="google-cloud-sdk"
panicmail_autosubmit="YES"
panicmail_enable="YES"
panicmail_sendto="FreeBSD Panic Reporting <swills-panicmail@mouf.net>"
EOF

cat << EOF > boot/loader.conf
autoboot_delay="-1"
beastie_disable="YES"
loader_logo="none"
hw.memtest.tests="0"
console="comconsole"
hw.vtnet.mq_disable=1
kern.timecounter.hardware=ACPI-safe
aesni_load="YES"
nvme_load="YES"
EOF

cat << EOF >> etc/hosts
169.254.169.254 metadata.google.internal metadata
EOF

cat << EOF > etc/ntp.conf
server metadata.google.internal iburst

restrict default kod nomodify notrap nopeer noquery
restrict -6 default kod nomodify notrap nopeer noquery

restrict 127.0.0.1
restrict -6 ::1
restrict 127.127.1.0
EOF

cat << EOF >> etc/syslog.conf
*.err;kern.warning;auth.notice;mail.crit                /dev/console
EOF

cat << EOF >> etc/ssh/sshd_config
ChallengeResponseAuthentication no
X11Forwarding no
AcceptEnv LANG
Ciphers aes128-ctr,aes192-ctr,aes256-ctr,arcfour256,arcfour128,aes128-cbc,3des-cbc
AllowAgentForwarding no
ClientAliveInterval 420
EOF

cat << EOF >> etc/crontab
0	3	*	*	*	root	/usr/sbin/freebsd-update cron
EOF

cat << EOF >> etc/sysctl.conf
net.inet.icmp.drop_redirect=1
net.inet.ip.redirect=0
net.inet.tcp.blackhole=2
net.inet.udp.blackhole=1
kern.ipc.somaxconn=1024
debug.trace_on_panic=1
debug.debugger_on_panic=0
EOF

sed -E -i '' 's/^([^#].*[[:space:]])on/\1off/' etc/ttys

# disabled until I can figure out why the reboot for updates is hanging
#touch ./firstboot

cp boot/pmbr ${WRKDIR}
cp boot/gptboot ${WRKDIR}

cd ${WRKDIR}

umount /mnt/g/new

mdconfig -d -u ${MD_UNIT}

mkimg -s gpt -b pmbr \
        -p freebsd-boot/bootfs:=gptboot \
        -p freebsd-swap/swapfs::${SWAPSIZE} \
        -p freebsd-ufs/rootfs:=${TMPFILE} \
        -o disk.raw

tar --format=gnutar -Szcf ${BUCKETFILE} disk.raw
rm ${TMPFILE} disk.raw pmbr gptboot

echo gcloud auth login
echo gsutil cp ${BUCKETFILE} gs://${MYBUCKET}
echo gcutil addimage ${IMAGENAME} gs://${MYBUCKET}/${BUCKETFILE}
