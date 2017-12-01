#! /bin/bash

usage() {
  echo "Usage: $0 [-s] [-w]  [-A architecture] [-C <component>] [-T (dsc|udeb|deb)] -r <repository> -f <fromDistribution> -d <toDistribution> -v <version>"
  echo "-s : simulate"
  echo "-w : wipe out <toDistribution> first"
  echo "-C <component>    : only act on component <component>"
  echo "-T (dsc,udeb,deb) : only act on source/udeb/deb packages"
  echo "-A <arch>         : only act on architecture <arch>"
  echo "-r : repository to use"
  echo "-f : source distribution to promote from"
  echo "-d : target distribution to promote to"
  echo "-v : version (needs to be a full x.y.z)"
  exit 1
}

while getopts "A:T:C:shwr:f:d:v:" opt ; do
  case "$opt" in
    s) simulate=1 && EXTRA_ARGS="$EXTRA_ARGS -s" ;;
    r) REPOSITORY=$OPTARG ;;
    C) COMPONENT="$OPTARG" && EXTRA_ARGS="$EXTRA_ARGS -C $COMPONENT" ;;
    A) ARCHITECTURE="$OPTARG" && EXTRA_ARGS="$EXTRA_ARGS -A $ARCHITECTURE" ;;
    T) TYPE="$OPTARG" && EXTRA_ARGS="$EXTRA_ARGS -T $TYPE" ;;
    w) WIPE_OUT_TARGET=1 ;;
    f) FROM_DISTRIBUTION=$OPTARG ;;
    d) TO_DISTRIBUTION=$OPTARG ;;
    v) VERSION=$OPTARG ;;
    h) usage ;;
    \?) usage ;;
  esac
done
shift $(($OPTIND - 1))
if [ ! $# = 0 ] ; then
  usage
fi

[ -z "$REPOSITORY" -o -z "$FROM_DISTRIBUTION" -o -z "$TO_DISTRIBUTION" -o -z "$VERSION" ] && usage && exit 1

##########
# MAIN

# include common variables
. $(dirname $0)/release-constants.sh

# generate changelog
if [ -z "$simulate" ] ; then
  changelog_file=$(mktemp "promotion-$REPOSITORY-$FROM_DISTRIBUTION-to-$TO_DISTRIBUTION_$(date -Iminutes)-XXXXXXX.txt")
  diffCommand="python3 ${PKGTOOLS}/changelog.py --log-level info --version $VERSION --tag-type promotion --create-tags"
  $diffCommand >| $changelog_file
fi

# wipe out target distribution first
[ -n "$WIPE_OUT_TARGET" ] && ${PKGTOOLS}/remove-packages.sh $EXTRA_ARGS -r $REPOSITORY -d $TO_DISTRIBUTION

${PKGTOOLS}/copy-packages.sh $EXTRA_ARGS -r $REPOSITORY $FROM_DISTRIBUTION $TO_DISTRIBUTION

if [ -z "$simulate" ] ; then
  attachments="-a ${changelog_file}"
  mutt -F $MUTT_CONF_FILE $attachments -s "[Distro Promotion] $REPOSITORY: $FROM_DISTRIBUTION promoted to $TO_DISTRIBUTION" -- $RECIPIENT <<EOF
Effective $(date).

Attached is the changelog for this promotion, generated by running
the following command:

    $diffCommand

--ReleaseMaster ($USER@$(hostname)), version $PKGTOOLS_VERSION
EOF
fi

/bin/rm -f ${changelog_file}
