#!/bin/bash

# find a free tcp port on the local machine 
if [[ -z $1 ]]; then
  MYPORT=$(shuf -i 10001-60000 -n 1)
else
  MYPORT=$1
fi
while ss -atwn | grep -q ":${MYPORT}\s"; do
  MYPORT=$(( ${MYPORT} + 1 ))
done
echo "${MYPORT}"
exit $MYPORT

