#!/bin/bash
# Copyright 2018 Zuse Institute Berlin
#
#    Licensed under the Apache License, Version 2.0 (the "License");
#    you may not use this file except in compliance with the License.
#    You may obtain a copy of the License at
#
#        http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS,
#    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#    See the License for the specific language governing permissions and
#    limitations under the License.

RINGSIZE=4

SCALARIS_UNITTEST_PORT=${SCALARIS_UNITTEST_PORT-"14195"}
SCALARIS_UNITTEST_YAWS_PORT=${SCALARIS_UNITTEST_YAWS_PORT-"8000"}

#SESSIONKEY=`cat /dev/urandom | env LC_CTYPE=C tr -dc 'a-z' | fold -w 32 | head -n 1`

usage(){
    echo "usage: setup-ring [options] <cmd>"
    echo " options:"
    echo "    --help                  - show this text"
    echo "    --ring-size <number>    - the number of nodes (default: 4)"
    echo "    --session-key <number>  - the session's key (mandatory)"
    echo " <cmd>:"
    echo "    start       - start a ring"
    echo "    stop        - stop a ring"
    echo "    kill        - kill a node"
    exit $1
}

start_ring(){
    KEYS=`./bin/scalarisctl -t client -e "-noinput -eval \"io:format('\n%~p', [api_rt:escaped_list_of_keys(api_rt:get_evenly_spaced_keys($RINGSIZE))]), halt(0)\"" start | grep % | cut -c 3- | rev | cut -c 2- | rev`

    export SCALARIS_ADDITIONAL_PARAMETERS="-scalaris mgmt_server {{127,0,0,1},$SCALARIS_UNITTEST_PORT,mgmt_server} -scalaris known_hosts [{{127,0,0,1},$SCALARIS_UNITTEST_PORT,service_per_vm}] -scalaris verbatim $SESSIONKEY"
    idx=0
    for key in $KEYS; do
        let idx+=1

        STARTTYPE=null
        if [ "x$idx" == x1 ]
        then
            STARTTYPE="first -m"
            TESTPORT=$SCALARIS_UNITTEST_PORT
            YAWSPORT=$SCALARIS_UNITTEST_YAWS_PORT
        else
            STARTTYPE="joining"
            let TESTPORT=$SCALARIS_UNITTEST_PORT+$idx-1
            let YAWSPORT=$SCALARIS_UNITTEST_YAWS_PORT+$idx-1
        fi

        ./bin/scalarisctl -d -k $key -p $TESTPORT -y $YAWSPORT -t $STARTTYPE start

    done

    let TESTPORT=$SCALARIS_UNITTEST_PORT+$RINGSIZE
    let YAWSPORT=$SCALARIS_UNITTEST_YAWS_PORT+$RINGSIZE

    ./bin/jsonclient -p $SCALARIS_UNITTEST_YAWS_PORT -r $RINGSIZE waitforringsize
}

stop_ring(){
    ps aux | grep beam.smp | grep "verbatim $SESSIONKEY" | awk '{print $2}'  | xargs -n1 kill -9
}

kill_node(){
    ps aux | grep beam.smp | grep "verbatim $SESSIONKEY" | grep -v "join_at 0" | awk '{print $2}' | head -n1 | xargs -n1 kill -9
}

MANDATORY=false

until [ -z "$1" ]; do
    OPTIND=1
    case $1 in
        "--help")
            shift
            usage 0;;
        "--ring-size")
            shift
            RINGSIZE=$1
            shift;;
        "--session-key")
            shift
            SESSIONKEY=$1
            MANDATORY=true
            shift;;
        start | stop)
            cmd="$1"
            shift;;
        kill)
            cmd="$1"
            shift;;
        *)
            echo "Unknown parameter: $1."
            shift
            usage 1
    esac
done

if [ "x$MANDATORY" == xfalse ]
then
   echo "Mandatory --session-key parameter is missing"
   usage 1
fi

case $cmd in
    start)
        start_ring;;
    stop)
        stop_ring;;
    kill)
        kill_node;;
    *)
        echo "Unknown command: $cmd."
        usage 1;;
esac
