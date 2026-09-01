#!/bin/sh
for _s in ge0 ge1; do
	ip link set dev "$_s" nomaster 2>/dev/null || true
done
ip link set bond0 down 2>/dev/null || true
ip link del bond0 2>/dev/null || true
