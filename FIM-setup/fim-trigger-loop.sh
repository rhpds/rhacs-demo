#!/bin/bash
# Simple loop to trigger FIM violation every ~60 seconds
# Run as root in chroot /host from oc debug node

COUNT=0
while true; do
    COUNT=$((COUNT + 1))
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Trigger Rule 1: touch /etc/passwd to generate MODIFY event (Rule 1 has no File Operation filter)
    touch /etc/passwd

    echo "[$TIMESTAMP] Triggered MODIFY on /etc/passwd (#$COUNT) - check ACS for alert"

    sleep 60  # Adjust to 30 or 120 if you want faster/slower
done
