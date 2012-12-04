#!/usr/bin/bash

. /usbkey/config

TESTED_VERSIONS=joyent_20120906T221231Z

DST=/opt

IFACE=`dladm show-phys -m | grep $admin_nic | awk -e '{print $1}'`
IP=`ifconfig $IFACE | grep inet | awk -e '{print $2}'`

DIR=`dirname $0`;
if [[ "x$DIR" = "x." ]]
then
    DIR=`pwd`
fi
BASE=`basename $0`;

if uname -a | grep $TESTED_VERSIONS
then
    echo "This SnartOS release is tested!"
else
    echo -n  "This SnartOS release WAS NOT tested! Are you sure you want to go on? [yes|NO] "
    read SKIP
    if [[ "$SKIP" = "yes" ]]
    then
	echo "Okay we go on, but it mit not work!"
    else
	echo "Exiting."
	exit 1
    fi
fi

(cd $DST; uudecode -p $DIR/$BASE|tar xzf -)
mkdir -p /var/log/chunter
sed -i .bak -e "s/127.0.0.1/${IP}/g" /opt/chunter/etc/app.config
sed -i .bak -e "s/127.0.0.1/${IP}/g" /opt/chunter/etc/vm.args

svccfg import /opt/chunter/etc/epmd.xml
svccfg import /opt/chunter/etc/chunter.xml

cat <<EOF

EOF

exit 0;
