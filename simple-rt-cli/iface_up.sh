#!/bin/bash

# SimpleRT: Reverse tethering utility for Android
# Copyright (C) 2016 Konstantin Menyaev
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

PLATFORM=$1
ACTION=$2
TUN_DEV=$3
TUNNEL_NET=$4
HOST_ADDR=$5
TUNNEL_CIDR=$6
NAMESERVER=$7
NAMESERVER_IS_LOCALHOST=$([[ "$NAMESERVER" =~ ^127\. ]] && echo 1 || echo 0)
LOCAL_INTERFACES=$8
if [ "$LOCAL_INTERFACES" = "all" ]; then
    LOCAL_INTERFACES=$(ifconfig -a | sed -E 's/[[:space:]:].*//;/^$/d' | grep -xv "lo" | grep -xv "lo0" | grep -xv "$TUN_DEV")
fi
shift

set -e

comment="simple_rt"


function nameserver_proxy {
    if [ "$NAMESERVER_IS_LOCALHOST" = "1" ]; then
        if [ ! -x "$(command -v socat)" ]; then
            echo "[ERROR] Program socat not found. Install it or specify public NS server with -n option."
            exit 1
        fi

        socat UDP-LISTEN:53,fork,reuseaddr,ignoreeof,bind=$HOST_ADDR UDP:$NAMESERVER:53 &
        SOCAT_PID=$!
        echo "Socat started, PID is $SOCAT_PID, proxying $HOST_ADDR:53 => $NAMESERVER:53"
    fi
}

function linux_start {
    ifconfig $TUN_DEV $HOST_ADDR/$TUNNEL_CIDR up
    sysctl -w net.ipv4.ip_forward=1 > /dev/null
    iptables -I FORWARD -j ACCEPT -m comment --comment "${comment}"
    for IFACE in $LOCAL_INTERFACES; do
        iptables -t nat -I POSTROUTING -s $TUNNEL_NET/$TUNNEL_CIDR -o $IFACE -j MASQUERADE -m comment --comment "${comment}"
    done

    nameserver_proxy
}

function linux_stop {
    iptables-save | grep -v "${comment}" | iptables-restore
}

function osx_start {
    ifconfig $TUN_DEV $HOST_ADDR 10.1.1.2 netmask 255.255.255.0 up
    route add -net $TUNNEL_NET $HOST_ADDR
    sysctl -w net.inet.ip.forwarding=1
    for IFACE in $LOCAL_INTERFACES; do
        echo "nat on $IFACE from $TUNNEL_NET/$TUNNEL_CIDR to any -> ($IFACE)" > /tmp/nat_rules_rt
    done

    # disable pf
    pfctl -qd 2>&1 > /dev/null || true
    pfctl -qF all 2>&1 > /dev/null || true

    # enable pf with simplert rules
    pfctl -qf /tmp/nat_rules_rt -e

    nameserver_proxy
}

function osx_stop {
    # disable pf
    pfctl -qd 2>&1 > /dev/null || true
    pfctl -qF all 2>&1 > /dev/null || true

    # enable pf with system rules
    pfctl -qf /etc/pf.conf -e
}

if [ "$ACTION" = "start" ]; then
    echo configuring:
    echo ========================================
    echo out interfaces:        $LOCAL_INTERFACES
    echo virtual interface:     $TUN_DEV
    echo network:               $TUNNEL_NET/$TUNNEL_CIDR
    echo host address:          $HOST_ADDR
    echo nameserver:            $([ "$NAMESERVER_IS_LOCALHOST" = "1" ] && echo "$HOST_ADDR (proxying to $NAMESERVER)" || echo $NAMESERVER)
    echo ========================================
fi

for IFACE in $LOCAL_INTERFACES; do
    ifconfig $IFACE > /dev/null
    if [ ! $? -eq 0 ]; then
        echo Supply valid local interface!
        exit 1
    fi
done

cmd="$PLATFORM-$ACTION"

case "$cmd" in
    linux-start)
        linux_start $@
        ;;

    linux-stop)
        linux_stop $@
        ;;

    osx-start)
        osx_start $@
        ;;

    osx-stop)
        osx_stop $@
        ;;

    *)
        echo "Unknown command: $cmd"
        exit 1
esac

exit 0

