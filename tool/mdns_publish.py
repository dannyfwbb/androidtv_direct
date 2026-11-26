#!/usr/bin/env python3
# Copyright 2026 The androidtv_direct authors
# SPDX-License-Identifier: Apache-2.0
#
# Based on adb_direct's tool/mdns_publish.py.
"""Publishes one DNS-SD service through the local Avahi daemon (D-Bus, no
root) until stdin closes or it is killed, for the mDNS device test:

    python3 tool/mdns_publish.py <instance> <type> <port> [key=value ...]

Withdrawing it (the process ending) makes Avahi send goodbyes.
"""
import sys
import dbus

def main():
    name, stype, port, *txt = sys.argv[1:]
    bus = dbus.SystemBus()
    server = dbus.Interface(bus.get_object('org.freedesktop.Avahi', '/'),
                            'org.freedesktop.Avahi.Server')
    group = dbus.Interface(bus.get_object('org.freedesktop.Avahi', server.EntryGroupNew()),
                           'org.freedesktop.Avahi.EntryGroup')
    # interface -1 (all), protocol 0 (IPv4), flags 0, domain/host default
    group.AddService(-1, 0, dbus.UInt32(0), name, stype, '', '', dbus.UInt16(int(port)),
                     [dbus.ByteArray(t.encode()) for t in txt])
    group.Commit()
    print('published', flush=True)
    try:
        sys.stdin.read()
    except KeyboardInterrupt:
        pass
    group.Reset()

main()
