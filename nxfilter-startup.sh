#!/bin/sh
#
# Version 1.0.2   3-5-2019
# (c)2019 - Rob Asher
#
# This is a startup script for NxFilter DNS filter based Google Compute Engine instances.
# For questions and instructions:  https://www.reddit.com/r/nxfilter/
#
# Inspired by, derived from, and portions blatantly stolen from work by:
#        Petri Riihikallio Metis Oy  -  https://metis.fi/en/2018/02/unifi-on-gcp/
#
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
#==============================================================================================


ENABLED=true
LOGFILE="/var/log/nxfilter/gcp-nxfilter.log"
HEADER='########## NXFILTER STARTUP SCRIPT ##########'


# only do something if we're enabled
if ${ENABLED} ; then

#==============================================================================================
#
# Set up logging
#
    LOGGER='/usr/bin/logger'

    # CREATE LOG FOLDER IF NOT EXISTS
    mkdir -p $(dirname "${LOGFILE}")

    # TRY TO CREATE LOG FILE IF NOT EXISTS
    ( [ -e "$LOGFILE" ] || touch "$LOGFILE" ) && [ ! -w "$LOGFILE" ] && echo "Unable to create or write to $LOGFILE"

function logthis() {
    TAG='NXFILTER'
    MSG="$1"
    $LOGGER -t "$TAG" "$MSG"
    echo "`date +%Y.%m.%d-%H:%M:%S` - $MSG"
    echo "`date +%Y.%m.%d-%H:%M:%S` - $MSG" >> $LOGFILE
}

logthis "$HEADER"

if [ ! -f /etc/logrotate.d/gcp-nxfilter.conf ]; then
    cat > /etc/logrotate.d/gcp-nxfilter.conf <<_EOF
$LOGFILE {
    monthly
    rotate 4
    compress
}
_EOF
	
    logthis "$LOGFILE rotatation set up"
fi


#==============================================================================================
#
# Turn off IPv6 for now
#
if [ ! -f /etc/sysctl.d/20-disableIPv6.conf ]; then
    echo "net.ipv6.conf.all.disable_ipv6=1" > /etc/sysctl.d/20-disableIPv6.conf
    sysctl --system > /dev/null
    logthis "IPv6 disabled"
fi


#==============================================================================================
#
# Update DynDNS as early in the script as possible
#
ddns=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/ddns-url")
if [ ${ddns} ]; then
    curl -fs ${ddns}
    logthis "Dynamic DNS accessed and updated"
fi


#==============================================================================================
#
# Create a swap file for small memory instances and increase /run
#
if [ ! -f /swapfile ]; then
    memory=$(free -m | grep "^Mem:" | tr -s " " | cut -d " " -f 2)
    logthis "${memory} megabytes of memory detected"
    if [ -z ${memory} ] || [ "0${memory}" -lt "2048" ]; then
        fallocate -l 2G /swapfile
        dd if=/dev/zero of=/swapfile count=2048 bs=1MiB
        chmod 600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        echo 'tmpfs /run tmpfs rw,nodev,nosuid,size=400M 0 0' >> /etc/fstab
        mount -o remount,rw,nodev,nosuid,size=400M tmpfs /run
        logthis "Swap file created"
    fi
fi


#==============================================================================================
#
# Add repositories if they don't exist
#
rpm -q deepwoods-release >/dev/null 2>&1
if [ $? -ne 0 ]; then
    yum -y install http://deepwoods.net/repo/deepwoods/deepwoods-release-6-2.noarch.rpm >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        logthis "DeepWoods repository added"
    else
        logthis "DeepWoods repo installation failed"	
    fi
fi

rpm -q epel-release >/dev/null 2>&1
if [ $? -ne 0 ]; then
    yum -y install epel-release >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        logthis "EPEL repository added"
    else
        logthis "EPEL repo installation failed"	
    fi
fi


#==============================================================================================
#
# Install some stuff
#

# Run initial update
if [ ! -f /usr/share/misc/c7-updated ]; then
    yum -y update >/dev/null
    touch /usr/share/misc/c7-updated
    logthis "System updated"
fi

# yum-utils install
rpm -q yum-utils >/dev/null 2>&1
if [ $? -ne 0 ]; then
    yum -y install yum-utils >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        logthis "yum-utils installed"
    else
        logthis "yum-utils installation failed"	
    fi
fi

# HAVEGEd install
rpm -q haveged >/dev/null 2>&1
if [ $? -ne 0 ]; then
    yum -y install haveged >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        systemctl reload-or-restart haveged
        systemctl enable haveged
        logthis "HAVEGEd installed"
    else
        logthis "HAVEGEd installation failed"	
    fi
fi

# nxfilter-sslsplit install
rpm -q nxfilter-sslsplit >/dev/null 2>&1
if [ $? -ne 0 ]; then
    yum -y install nxfilter-sslsplit >/dev/null 2>&1
    if [ $? -eq 0 ]; then
        logthis "NxFilter with SSLsplit installed"
        systemctl enable nxfilter
        systemctl enable sslsplit
        systemctl reload-or-restart nxfilter
        systemctl reload-or-restart sslsplit
    else
        logthis "NxFilter-SSLsplit installation failed"	
    fi
fi


#==============================================================================================
#
# Set the time zone
#
tz=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/timezone")
if [ ${tz} ] && [ -f /usr/share/zoneinfo/${tz} ]; then
    if timedatectl set-timezone $tz; then logthis "Localtime set to ${tz}"; fi
    systemctl reload-or-restart rsyslog
fi


#==============================================================================================
#
# Set the CA certificate common name
#
cn=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/cn-name")
if [ ${cn} ]; then
    echo "${cn}" > /usr/local/src/nxfilter-sslsplit/name.txt
    logthis "Certificate CN name set to ${cn}"
    systemctl reload-or-restart sslsplit
fi


#==============================================================================================
#
# yum-cron already enabled for unattended updates in GC CentOS 7 base image
#

# check daily to see if installed updates require system reboot
if [ ! -f /usr/local/sbin/check-restart.sh ]; then
    cat > /usr/local/sbin/check-restart.sh <<_EOF
#!/bin/sh
/usr/bin/needs-restarting -r >/dev/null 2>&1
if [ $? -ne 0 ]; then
    echo >> $LOGFILE
    shutdown -r +5 "Updates require reboot. Restarting in 5 minutes"
    echo "=== Updates triggered system reboot in 5 minutes ===" >> $LOGFILE
    echo >> $LOGFILE
fi
_EOF
fi
chmod +x /usr/local/sbin/check-restart.sh

if [ ! -f /etc/systemd/system/needs-restart.service ]; then
    cat > /etc/systemd/system/needs-restart.service <<_EOF
[Unit]
Description=Daily check if reboot is required
[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/local/sbin/check-restart.sh
_EOF

    cat > /etc/systemd/system/needs-restart.timer <<_EOF
[Unit]
Description=Daily check if reboot is required timer
[Timer]
OnCalendar=*-*-* 04:15:00
Persistent=true
[Install]
WantedBy=timers.target
_EOF
    
    systemctl daemon-reload
    systemctl start needs-restart.timer
    logthis "Daily check if reboot required set up"
fi


#==============================================================================================
#
# Set up daily backup to a bucket after 01:00
#
bucket=$(curl -fs -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/attributes/bucket")
if [ ${bucket} ]; then
    cat > /etc/systemd/system/nxfilter-backup.service <<_EOF
[Unit]
Description=Daily backup to ${bucket} service
After=network-online.target
Wants=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/bin/gsutil rsync -r -d /nxfilter/backup gs://$bucket
_EOF

    cat > /etc/systemd/system/nxfilter-backup.timer <<_EOF
[Unit]
Description=Daily backup to ${bucket} timer
[Timer]
OnCalendar=1:00
RandomizedDelaySec=30m
[Install]
WantedBy=timers.target
_EOF
    
    systemctl daemon-reload
    systemctl start nxfilter-backup.timer
    logthis "Backups to ${bucket} set up"
fi

#==============================================================================================

    logthis "########## STARTUP SCRIPT FINISHED ##########"
fi
