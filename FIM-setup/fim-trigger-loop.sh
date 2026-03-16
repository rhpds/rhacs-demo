#!/bin/bash
# Simple loop to trigger FIM violation every ~60 seconds
# Run as root in chroot /host from oc debug node
# Monitors /etc/sudoers (file) - sudoers.d/ is a directory for drop-in configs

COUNT=0
while true; do
    COUNT=$((COUNT + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Touch /etc/sudoers to generate MODIFY event (policy detects unauthorized changes to sudoers file)
    touch /etc/sudoers

    echo "[$TIMESTAMP] Triggered MODIFY on /etc/sudoers (#$COUNT) - check ACS for alert"

    sleep 60  # Adjust to 30 or 120 if you want faster/slower
done
