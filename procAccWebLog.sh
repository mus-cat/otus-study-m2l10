#! /bin/bash

anchorAccFile=/var/log/apache2/lastaccline
procaccfile=/tmp/procaccfile
lockfile=/tmp/webstat.lck
whereFind=/var/log/apache2
awkscr=/tmp/awk.scr
startAccTime=""
endAccTime=""
sortAccFiledLoc=""
sendLines=5

declare -a files


function getSecFromStr() {
 tmp=$(echo "$1" | grep -o '\[[^]]\+\]' | sed -e '{s/\//-/g}' -e '{s/:/\ /}' -e '{s/\]\|\[//g}')
 tmp=$(date --date="$tmp" +%s)
 echo $tmp
}
 
function init() {
 sortAccFieldLoc=$whereFind/access.log
 sortAccFieldLoc=$((${#sortAccFieldLoc} + 2))

 if [ -s $anchorAccFile ]; then
  tmp=$(<$anchorAccFile);
  startAccTime=$(getSecFromStr "$tmp")
 else
  startAccTime=0
 fi

 cat > $awkscr << AWKSCRIPT
BEGIN { FPAT = "([^\"\\\\\\ ]+)|(\\\\\\[[^\"]+\\\\\\])|(\"[^\"]*\")" };

{
 if(\$1 in ips) 
  ips[\$1]++
 else
  ips[\$1] = 1

 if(\$5 in urls) 
  urls[\$5]++
 else
  urls[\$5] = 1

 if(\$6 in httpc) 
  httpc[\$6]++
 else
  httpc[\$6] = 1
}

END {
 for(i in ips)
  print ips[i]" "i | "sort -nr > /tmp/ips.res"

 for(i in urls)
  print urls[i]" "i | "sort -nr > /tmp/urls.res"

 for(i in httpc)
  print httpc[i]" "i | "sort -nr > /tmp/httpc.res"
}
AWKSCRIPT
}

function generateFileList() {
 declare -A info
 lineNum=""

 i=0
 for file in $(ls $whereFind/access.log* 2>/dev/null | sort -n -k 1.$sortAccFieldLoc); do
  prog="cat"
  if [ "${file: -3}" == ".gz" ]; then
   prog="zcat"
   tmp="$(zcat $file | head -n 1)"
   tmp1="$(zcat $file | tail -n 1)"
  else
   tmp="$(head -n 1 $file)"
   tmp1="$(tail -n 1 $file)"
  fi
  fileStartTime=$(getSecFromStr "$tmp")
  fileEndTime=$(getSecFromStr "$tmp1")

  info["fileName"]="$file"
  info["prog"]="$prog"
  info["startPos"]="1"

  if ((startAccTime <= fileEndTime)); then
   if ((startAccTime >= fileStartTime)); then
    lineNum=$($prog "$file" | grep -nFf $anchorAccFile 2>/dev/null | cut -d ':' -f1)
    if [ -n "$lineNum" ]; then
     let lineNum++
     info["startPos"]="$lineNum"
    fi
   fi
   files[$i]="${info[@]}"
  else
   break;
  fi

  
#  files[$i]="${info[@]}"
#  if [ -n "$lineNum" ]; then break; fi
  let i++
 done
}

function generateProcFile() {
 generateFileList

 read -ra info <<< "${files[-1]}"
 lineNum=${info[2]}
 ${info[1]} ${info[0]} | sed -n "$lineNum,\$p" >> "$procaccfile"

 i=${#files[@]}
 let i--

 while ((--i >= 0)); do
   read -ra info <<< "${files[$i]}"
   ${info[1]} ${info[0]} >> "$procaccfile"
  done
}

function fillDateTime() {
 if [ -s $anchorAccFile ]; then
  startAccTime=$(cat $anchorAccFile| cut -d ' ' -f4 | tr -d "[]")
 else
  if [ -s $procaccfile ]; then
   startAccTime=$(head -n 1 $procaccfile | cut -d ' ' -f4 | tr -d "[]")
  else
   startAccTime="Not defined"
  fi
 fi

 if [ -s $procaccfile ]; then
  endAccTime=$(tail -n 1 $procaccfile | cut -d ' ' -f4 | tr -d "[]")
 else
  endAccTime=$(date +%d/%b/%Y:%T)
 fi
}

function clearEnvironment() {
 rm -f "$procaccfile"
 rm -f "$lockfile"
 rm -f "$awkscr"
}

function sendMail() {
 echo "$1" | mail -s "Web Stat" root 
}

function setProcessLine() {
 tail -n 1 $procaccfile > $anchorAccFile
}

#
#Script start here
#
if ! (set -o noclobber; echo "$$" > "$lockfile") 2>/dev/null; then
 if ps -p $(cat $lockfile) 1>/dev/null 2>&1; then
  logger "Already run other instance"
  exit 0
 else
  rm $lockfile
  echo "$$" > "$lockfile"
 fi
fi

set +C
trap 'clearEnvironment; exit 0' TERM EXIT

init
generateProcFile
fillDateTime

if ! [ -s $procaccfile ]; then
 echo "Nothing to process"
 sendMail "$(echo -e Nothing to process. $'\n' TimeRange: $startAccTime - $endAccTime)"
 exit 0
fi

awk -nf $awkscr $procaccfile  2>/dev/null

cont="TimeRange: $startAccTime - $endAccTime"$'\n'
for file in ips.res urls.res httpc.res; do
 cont+="$(head -n $sendLines /tmp/$file)"
 cont+=$'\n'"--------"$'\n'
done
sendMail "$cont"
setProcessLine

