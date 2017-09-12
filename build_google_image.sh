#!/bin/sh

# Script to create images for use in Google Cloud Compute
# only amd64 is supported

###############################
# tweak these to taste, if you feel the need

# release to use
VERSION=11.1-RELEASE

# group the image with this name, so you can always get the latest
# image for FreeBSD when installing using this name.
IMAGEFAMILY=freebsd-11

# see truncate(1) for acceptable sizes
# minimum size, image will grow at boot time to accomodate larger disks
VMSIZE=5g

# size passed to mkimg(1)
SWAPSIZE=1G

# options passed to newfs(8)
NEWFS_OPTIONS="-U -j -t"

# which OS components to install, choose from:
# base doc games kernel lib32 ports src
COMPONENTS="base kernel"

# package to install into the image
BAKED_IN_PACKAGES="sysutils/py-google-compute-engine sudo"

# which bucket to upload to
MYBUCKET=kci-images

# probably don't need to change things below here

TS=`date -u +%Y%m%d%H%M%S`
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

  # temporarily use the "latest" package repo since py-google-compute-engine is not
  # in current quarterly (2017-SEP-09)
  sed -E -i .save 's/^(  url.*)quarterly/\1latest/' etc/pkg/FreeBSD.conf  

  yes | chroot . usr/bin/env ASSUME_ALWAYS_YES=yes usr/sbin/pkg install -qy ${BAKED_IN_PACKAGES} >/dev/null 2>&1
  
  chroot . usr/bin/env ASSUME_ALWAYS_YES=yes usr/sbin/pkg clean -qya >/dev/null 2>&1
  chroot . usr/sbin/pw lock root
  
  rm -rf var/db/pkg/repo*

  # restore the temporary package config
  mv etc/pkg/FreeBSD.conf.save etc/pkg/FreeBSD.conf

  # this will be overwritten by DHCP anyway.
  cat << EOF > etc/resolv.conf
search google.internal
nameserver 169.254.169.254
EOF
  
  cat << EOF > etc/fstab
# Custom /etc/fstab for FreeBSD Google Cloud VM images
/dev/gpt/rootfs   /       ufs     rw      1       1
/dev/gpt/swapfs   none    swap    sw      0       0
# put /tmp into a ram disk
tmpfs		  /tmp	  tmpfs	  rw,mode=1777	  0	0
EOF
  
  cat << EOF > etc/rc.conf
dumpdev="AUTO"
ifconfig_vtnet0="SYNCDHCP mtu 1460"
ntpd_sync_on_start="YES"
ntpd_enable="YES"
sshd_enable="YES"
# growfs only runs on firstboot
growfs_enable="YES"
# google cloud daemons. these are required.
google_startup_enable="YES"
google_accounts_daemon_enable="YES"
google_clock_skew_daemon_enable="YES"
google_instance_setup_enable="YES"
google_ip_forwarding_daemon_enable="YES"
google_network_setup_enable="YES"
EOF
  
  cat << EOF > boot/loader.conf
autoboot_delay="4"
# the TSC timecounter sucks on GCE, so let it pick one of the ACPI timecounters
machdep.disable_tsc=1
hw.memtest.tests="0"
console="comconsole"
loader_logo="beastie"
hw.vtnet.mq_disable=1
aesni_load="YES"
# nvme and nvd modules are used with local SSD in NVME mode, if attached.
#nvme_load="YES"
EOF
  
  cat << EOF >> etc/hosts
169.254.169.254 metadata.google.internal metadata
EOF
  
  cat << EOF > etc/ntp.conf
server metadata.google.internal iburst

restrict -6 default ignore
restrict default ignore

restrict -6 ::1
restrict 127.0.0.1
restrict metadata.google.internal
EOF
  
  cat << EOF >> etc/ssh/sshd_config
ChallengeResponseAuthentication no
ClientAliveInterval 420
EOF
  
  cat << EOF >> etc/cron.d/freebsd-update
0	3	*	*	*	root	/usr/sbin/freebsd-update cron
EOF
  
  cat << EOF >> etc/sysctl.conf
net.inet.icmp.drop_redirect=1
net.inet.ip.redirect=0
net.inet.tcp.blackhole=2
net.inet.udp.blackhole=1
kern.ipc.somaxconn=1024
EOF
  
  # turn off all virtual ttys and just leave the serial ones.
  sed -E -i '.dist' 's/^([^#].*[[:space:]])on /\1off/' etc/ttys
  
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
echo gcloud compute images create ${IMAGENAME} --description="'FreeBSD ${VERSION}'" --family=${IMAGEFAMILY} --source-uri=https://storage.googleapis.com/${MYBUCKET}/${BUCKETFILE}
