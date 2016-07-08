#!/bin/bash

if [[ -z ${CONSUL} ]]; then
  fatal "Missing CONSUL environment variable"
  exit 1
fi

zkAddrs() {
  CONFIGDIR="/opt/kafka-manager/conf/"
  $(consul-template -consul $CONSUL:8500 -template "${CONFIGDIR}zkconnect.ctmpl:${CONFIGDIR}zkconnect.txt" -once)
  ADDR_PORT="[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\:[0-9]+\:[0-9]+"
  export ZKADDRS=$(grep -E -o $ADDR_PORT ${CONFIGDIR}zkconnect.txt | awk -F":" '{print $1":2181"}' | paste -s -d, -)
}


generateConfig() {
  debug "Generating config"

  # generate list of addrs, put them into config
  zkAddrs

  # generate the configuration file 
  search='%%ZKADDRS%%'
  sed "s/${search}/${ZKADDRS}/g"  $DEFAULTCONFIG > $CONFIGFILE

  debug "----------------- Configuration -----------------"
  debug $(cat $CONFIGFILE)
  debug "-----------------------------------------------------"
}

reload() {
  current_config=$(cat $CONFIGFILE)

  generateConfig

  new_config=$(cat $CONFIGFILE)

  if [ "$current_config" != "$new_config" ]; then
    info "******* Rebooting kafka-manager *******"
    debug "******* myid:$(cat $KAFKAPIDFILE) ******* "

    if [ -f $KAFKAPIDFILE ]; then
      kill -SIGTERM $(cat $KAFKAPIDFILE)
    fi
  else
    debug "Configs are identical. No need to reload."
  fi
}

health() {
  # curl localhost:9000
  ISDOWN=$(curl -s localhost:8999 -o /dev/null || echo "down")
  # if ISDOWN is empty, we're good
  if [ -z "$ISDOWN" ]; then
    return 1
  else
    return 0
  fi

}

start() {
  info "Bootstrapping kafka-manager..."
  generateConfig

  # kafka-manager doesn't have a hot-reload mechanism.
  # This hackery allows us to restart kafka without killing the container.
  # The `/bin/manage.sh reload` function will kill kafka-manager if it detects new configuration.
  while true; do

    # check if zookeeper is already running
    pid=$(pgrep 'java')

    # If it's not running then start it
    if [ -z "$pid" ]; then

      info "******* Starting kafka-manager *******"

      /kafka-manager-$KM_VERSION/bin/kafka-manager -Dconfig.file=${CONFIGFILE} &
      sleep 3s
      echo $(pgrep 'java') > $KAFKAPIDFILE
      info "******* writing $KAFKAPIDFILE : $(cat $KAFKAPIDFILE) *******"
      exitcode=$?
      if [ $exitcode -gt 0 ]; then
        exit $exitcode
      fi
    fi

    sleep 1s
  done
}

debug() {
  if [ ! -z "$DEBUG" ]; then
    echo "=======> DEBUG: $@"
  fi
}

info() {
  echo "=======> INFO: $@"
}

fatal() {
  echo "=======> FATAL: $@"
}

# make variables available for all processes/sub-processes called from manage
# get my external (within the datacenter....) IP_ADDRESS
export IP_ADDRESS=$(/sbin/ip addr show eth0 | grep -o '[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}\.[0-9]\{1,3\}')
export CONFIGFILE="/kafka-manager-${KM_VERSION}/conf/application.conf"
export DEFAULTCONFIG="/kafka-manager-${KM_VERSION}/conf/default.application.conf"
export KAFKAPIDFILE="/opt/kafka-manager/server.pid"


export DEBUG=true

# do whatever the arg is
$1