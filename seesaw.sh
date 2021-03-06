#!/bin/bash
#
# Distributed downloading script for FortuneCity.(com|co.uk|es|it|se).
#
# This will get a task from the tracker and download a FortuneCity
# member site or a complete street.
#
# This script will download a user's data to this computer.
# It uploads the data to batcave and deletes it. It will then
# continue with the next user and repeat.
#
# Usage:
#   ./seesaw.sh $YOURNICK
#
# You can set a bwlimit for the rsync upload, e.g.:
#   ./seesaw.sh $YOURNICK 300
#
# To stop the script gracefully,  touch STOP  in the script's
# working directory. The script will then finish the current
# user and stop.
#

# this script needs wget-warc, which you can find on the ArchiveTeam wiki.
# copy the wget executable to this script's working directory and rename
# it to wget-warc

if [ ! -x ./wget-warc ]
then
  echo "wget-warc not found. Download and compile wget-warc and save the"
  echo "executable as ./wget-warc"
  exit 3
fi

youralias="$1"
bwlimit=$2

if [[ ! $youralias =~ ^[-A-Za-z0-9_]+$ ]]
then
  echo "Usage:  $0 {nickname}"
  echo "Run with a nickname with only A-Z, a-z, 0-9, - and _"
  exit 4
fi

if [ -n "$bwlimit" ]
then
  if [[ ! $bwlimit =~ ^[1-9][0-9]*$ ]]
  then
    echo "Invalid bandwidth limit specified."
    echo "Usage:  $0 {nickname} [bwlimit]"
    echo "If bwlimit is specified, it must be a number, meaning kilobytes per second."
    exit 4
  fi
  bwlimit="--bwlimit=${bwlimit}"
fi

initial_stop_mtime='0'
if [ -f STOP ]
then
  initial_stop_mtime=$( ./filemtime-helper.sh STOP )
fi

VERSION=$( grep 'VERSION=' dld-member.sh | grep -oE "[-0-9.]+" )

while [ ! -f STOP ] || [[ $( ./filemtime-helper.sh STOP ) -le $initial_stop_mtime ]]
do
  # request a username
  echo -n "Getting next username from tracker..."
  tracker_no=$(( RANDOM % 3 ))
  tracker_host="focity-${tracker_no}.heroku.com"
  response_file=".seesaw.$$.${tracker_host}_response"
  itemname=$( curl -s -d "{\"downloader\":\"${youralias}\"}" -D ${response_file} http://${tracker_host}/request )

  # HTTP 420 from the tracker indicates global rate-limiting is in effect
  tracker_status=$(head -n 1 ${response_file} | cut -c 10-12)
  if [ "$tracker_status" == "420" ]
  then
    echo
    echo "Tracker rate limiting is in effect."
  fi

  rm $response_file

  # If the response code isn't 200, then something went wrong with the tracker;
  # try again later.
  if [ "$tracker_status" != "200" ]
  then
    echo
    echo "Tracker returned status code $tracker_status.  Will retry in 30 seconds."
    echo
    sleep 30
  elif [ -z $itemname ]
  then
    echo
    echo "No itemname.  Will retry in 30 seconds."
    echo
    sleep 30
  else
    echo " done."

    tld=$( echo "$itemname" | cut -d "/" -f 1 )
    area=$( echo "$itemname" | cut -d "/" -f 2 )
    street=$( echo "$itemname" | cut -d "/" -f 3 )

    if [ $area == member ] || [ $area == members ]
    then
      ./dld-member.sh "$tld" "$street"
      result=$?
    else
      ./dld-street.sh "$tld" "$area" "$street"
      result=$?
    fi

    if [ $result -eq 0 ]
    then
      # complete

      # statistics!
      if [ $area == member ] || [ $area == members ]
      then
        prefix_dir="$tld/members/${street:0:1}/${street:0:2}/${street:0:3}"
        prefix_file="$prefix_dir/$tld-members-$street-"
        bytes=$( ./du-helper.sh -b "data/$prefix_dir/$tld-members-$street-"*".warc.gz" )
        bytes_str="{\"member\":${bytes},\"street\":0}"
      else
        prefix_dir="$tld/$area"
        prefix_file="$prefix_dir/$tld-$area-$street-"
        bytes=$( ./du-helper.sh -b "data/$prefix_dir/$tld-$area-$street-"*".warc.gz" )
        bytes_str="{\"member\":0,\"street\":${bytes}}"
      fi

      success_str="{\"downloader\":\"${youralias}\",\"item\":\"${itemname}\",\"bytes\":${bytes_str},\"version\":\"${VERSION}\",\"id\":\"\"}"

      # upload
      echo "Uploading ${itemname}..."

      cd data
      ls -1 "$prefix_file"*".warc.gz" | \
      rsync -avz \
            --compress-level=9 \
            --progress \
            ${bwlimit} \
            --recursive \
            --remove-source-files \
            --files-from="-" \
            ./ fos.textfiles.com::fortunecity/${youralias}/
      result=$?
      cd ..

      if [ $result -eq 0 ]
      then
        delay=1
        while [ $delay -gt 0 ]
        do
          echo "Telling tracker that '${itemname}' is done."
          tracker_no=$(( RANDOM % 3 ))
          tracker_host="focity-${tracker_no}.heroku.com"
          resp=$( curl -s -f -d "$success_str" http://${tracker_host}/done )
          if [[ "$resp" != "OK" ]]
          then
            echo "ERROR contacting tracker. Could not mark '$itemname' done."
            echo "Sleep and retry."
            sleep $delay
            delay=$(( delay * 2 ))
          else
            delay=0
          fi
        done
        echo
      else
        echo
        echo
        echo "An rsync error. Scary!"
        echo
        exit 1
      fi

    else
      echo "Error downloading '$itemname'." >> errors.log
    fi
  fi
done

