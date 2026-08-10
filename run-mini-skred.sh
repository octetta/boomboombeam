#!/bin/bash
set -e

echo "Starting Skred standalone UDP Server on port 60440..."
echo "Leave this running in the background, then switch the BoomBoomBeam UI to 'Remote UDP' mode!"
echo "---------------------------------------------------------"

./clib/pulp/bin/mini-skred -p60440
