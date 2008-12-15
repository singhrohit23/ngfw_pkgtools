#! /bin/bash

usage() {
  echo "Usage: $0 -r <repository> -d <distribution> [-h host] [a]"
  echo -e "\t-a : all (recurse into subdirectories)"
  exit 1
}

MAX_DEPTH="-maxdepth 1"

while getopts "r:d:ah?" opt ; do
  case "$opt" in
    r) REPOSITORY=$OPTARG ;;
    d) DISTRIBUTION=$OPTARG ;;
    h) HOST=$OPTARG ;;
    a) MAX_DEPTH="" ;;
    h|\?) usage ;;
  esac
done

HOST=${HOST:-mephisto}

[ -z "$REPOSITORY" ] || [ -z "$DISTRIBUTION" ] && usage

DEBS=$(find . $MAX_DEPTH -name "*.deb" | xargs)
UDEBS=$(find . $MAX_DEPTH -name "*.udeb" | xargs)

if [ -n "$DEBS" ] || [ -n "$UDEBS" ] ; then
  for p in $DEBS ; do
    touch ${p/.deb/.${REPOSITORY}_${DISTRIBUTION}.manifest}
  done
  for p in $UDEBS ; do
    touch ${p/.udeb/.${REPOSITORY}_${DISTRIBUTION}.manifest}
  done

  MANIFESTS=$(find . $MAXDEPTH -name "*.manifest" | xargs)

  echo "About to upload: $DEBS $UDEBS"

  lftp -e "set net:max-retries 1 ; cd $REPOSITORY/incoming ; put $DEBS $UDEBS $MANIFESTS ; exit" $HOST
  rm -f $MANIFESTS
fi
