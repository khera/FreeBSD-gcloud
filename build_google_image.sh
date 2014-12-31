#!/bin/sh

# Script to create images for use in Google Cloud Compute
# only amd64 is supported

###############################
# tweak these to taste, if you feel the need

# release to use
# 10.1 has been tested, others may not work
VERSION=10.1-RELEASE

# see truncate(1) for acceptable sizes
# minimum size, image will grow at boot time to accomodate larger disks
VMSIZE=10g

# size passed to mkimg(1)
SWAPSIZE=1G

# options passed to newfs(8)
NEWFS_OPTIONS="-U -j -t"

# which OS components to install, choose from:
# base doc games kernel lib32 ports src
COMPONENTS="base kernel"

# package to install into the image
BAKED_IN_PACKAGES="firstboot-freebsd-update firstboot-pkgs google-cloud-sdk google-daemon panicmail sudo"
#BAKED_IN_PACKAGES+="firstboot-growfs google-startup-scripts"

# package to install at boot time
FIRST_BOOT_PKGS="bsdinfo"

# which bucket to upload to
MYBUCKET=swills-test-bucket

# probably don't need to change things below here

TS=`env TZ=UTC date +%Y%m%d%H%M%S`
IMAGENAME=`echo FreeBSD-${VERSION}-amd64-${TS} | tr '[A-Z]' '[a-z]' | sed -e 's/\.//g'`

# filename for tar file in bucket
BUCKETFILE=FreeBSD-${VERSION}-amd64-${TS}.tar.gz
TMPFILE=FreeBSD-${VERSION}-amd64-gcloud-image-${TS}.raw

# local dir where we keep things
WRKDIR=${PWD}

# local dir where we mount the image temporarily
TMPMOUNT=/mnt/gcloud_new_${TS}

###############################

cleanup() {
  set +e
  echo "Error or interrupt detected, cleaning up and exiting"
  cd ${WRKDIR}
  umount -f ${TMPMOUNT} >/dev/null 2>&1
  rmdir ${TMPMOUNT} >/dev/null 2>&1
  mdconfig -d -u ${MD_UNIT} >/dev/null 2>&1
  rm -f ${TMPFILE} disk.raw pmbr gptboot /tmp/mkimg-?????? >/dev/null 2>&1
  trap - SIGHUP SIGINT SIGTERM EXIT
  echo
  exit 1
}

# fetch OS components
build_mirror() {
  cd ${WRKDIR}
  mkdir -p ${VERSION}
  cd ${VERSION}

  for comp in ${COMPONENTS} ; do
    if [ ! -f ${comp}.txz ]; then
      fetch http://ftp.freebsd.org/pub/FreeBSD/releases/amd64/amd64/${VERSION}/${comp}.txz
    fi
  done
}

build_image() {
  cd ${WRKDIR}
  truncate -s ${VMSIZE} ${TMPFILE}
  MD_UNIT=$(mdconfig -f ${TMPFILE})
  
  echo "  Creating filesystem"
  newfs ${NEWFS_OPTIONS} ${MD_UNIT} >/dev/null 2>&1
  
  mkdir -p ${TMPMOUNT}
  
  mount /dev/${MD_UNIT} ${TMPMOUNT}
  
  cd ${TMPMOUNT}
  for comp in ${COMPONENTS} ; do
    echo "  Installing ${comp} into image"
    tar -xzf ${WRKDIR}/${VERSION}/${comp}.txz
  done
}

setup_image() {
  cd ${TMPMOUNT}
  # temporarily use the local systems resolv.conf so packages can be installed
  cp /etc/resolv.conf etc/resolv.conf
  
  yes | chroot . usr/bin/env ASSUME_ALWAYS_YES=yes usr/sbin/pkg install -qy ${BAKED_IN_PACKAGES} >/dev/null 2>&1
  
  chroot . usr/bin/env ASSUME_ALWAYS_YES=yes usr/sbin/pkg clean -qya >/dev/null 2>&1
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
#disabled until I can figure out why the reboot for updates is hanging
#firstboot_freebsd_update_enable="YES"
firstboot_pkgs_enable="YES"
firstboot_pkgs_list="${FIRST_BOOT_PKGS}"
panicmail_autosubmit="YES"
panicmail_enable="YES"
panicmail_sendto="FreeBSD Panic Reporting <swills-panicmail@mouf.net>"
firstboot_growfs_enable="YES"
google_startup_enable="YES"
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
  
  touch ./firstboot
}

finish_image() {
  cd ${TMPMOUNT}
  cp boot/pmbr ${WRKDIR}
  cp boot/gptboot ${WRKDIR}
  
  cd ${WRKDIR}
  
  umount ${TMPMOUNT}
  rmdir ${TMPMOUNT}
  
  mdconfig -d -u ${MD_UNIT}
  
  echo "  Creating partitioned file"
  mkimg -s gpt -b pmbr \
          -p freebsd-boot/bootfs:=gptboot \
          -p freebsd-swap/swapfs::${SWAPSIZE} \
          -p freebsd-ufs/rootfs:=${TMPFILE} \
          -o disk.raw
  
  rm ${TMPFILE} pmbr gptboot
  echo "  Creating image tar"
  tar --format=gnutar -Szcf ${BUCKETFILE} disk.raw
  rm disk.raw
}

###############################

if [ $(id -u) != 0 ]; then
   echo "This script must be run as root" 1>&2
   exit 1
fi

set -e

trap cleanup SIGHUP SIGINT SIGTERM EXIT

cd ${WRKDIR}

echo "Building mirror of OS components"
build_mirror
echo "Creating image"
build_image
echo "Setting up image"
setup_image
echo "Finishing image"
finish_image
trap - SIGHUP SIGINT SIGTERM EXIT

echo "Now run:"
echo
echo gcloud auth login
echo gsutil cp ${BUCKETFILE} gs://${MYBUCKET}
echo gcutil addimage ${IMAGENAME} gs://${MYBUCKET}/${BUCKETFILE}
