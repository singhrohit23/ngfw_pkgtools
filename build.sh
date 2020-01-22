#! /bin/bash

# Minimalist version of ngfw_pkgtools.git/make-build.sh so TravisCI
# and Jenkins can build packages.
#
# This is meant to be run in a disposable container.

## constants
PKGTOOLS=$(dirname $(readlink -f $0))
PKGTOOLS_VERSION=$(pushd $PKGTOOLS > /dev/null ; git describe --tags --always --long --dirty ; popd > /dev/null)

## env
REPOSITORY=${REPOSITORY:-buster}
DISTRIBUTION=${DISTRIBUTION:-current}
ARCHITECTURE=${ARCHITECTURE:-$(dpkg-architecture -qDEB_BUILD_ARCH)}
BRANCH=${BRANCH:-master}
PACKAGE=${PACKAGE} # empty default means "all"
VERBOSE=${VERBOSE} # empty means "not verbose"
UPLOAD=${UPLOAD} # empty default means "no upload"
FORCE=${FORCE} # emtpy means "do not force build"
DEBUG=${DEBUG} # emtpy means "no debugging"

if [[ -n "$DEBUG" ]] ; then
   set -x
   VERBOSE=1 # also force VERBOSE
fi

## functions
log() {
  echo "=== " $@
}

make-pkgtools() {
  make -f ${PKGTOOLS}/Makefile DISTRIBUTION=${DISTRIBUTION} REPOSITORY=${REPOSITORY} $@
}

wait-for-pid() {
  pid=$1
  delay=1
  delay_msg=30
  i=0
  while ps hp $pid > /dev/null ; do
    let i=i+1
    if [[ $(( $i % $delay_msg )) = 0 ]] ; then
      echo "... still waiting for PID ${pid} every ${delay}s, next message in ${delay_msg}s"
    fi
    sleep $delay
  done
}

install-build-deps() {
  pkg=$1

  if [[ "$pkg" =~ "/linux-" ]] && [[ $ARCHITECTURE != "amd64" ]] ; then
    # when cross-building kernels, build-dep chokes trying to install:
    #   - the native version of python3-sphinx (which is arch-indep)
    #   - the native version of python3 which conflicts with
    #     core/build-essential dependencies
    make -f ../Makefile ARCH=$ARCHITECTURE deps-crossbuild
  else
    apt build-dep -y --host-architecture $ARCHITECTURE .
  fi
}

do-build() {
  pkg=$1
  shift
  dpkg_buildpackage_options="$@"

  # bump version and create source tarball
  if [[ "$pkg" =~ "/linux-" ]] ; then
    # for kernels, the version is manually managed
    dpkg-parsechangelog -S Version > debian/version
    # ... and we don't let dpkg-buildpackage check build-dependencies
    # or build documentation packages
    dpkg_buildpackage_options="$dpkg_buildpackage_options -d --build-profiles=nodoc"
  else
    make-pkgtools version source
  fi
  make-pkgtools create-dest-dir
  version=$(cat debian/version)

  # collect existing versions
  is_present=0
  if [[ -z "$FORCE" ]] ; then
    is_present=1
    for binary_pkg in $(dh_listpackages $pkg) ; do
      output=$(apt-show-versions -p '^'${binary_pkg}'$' -a -R)
      if ! echo "$output" | grep -qP ":(all|${ARCHITECTURE}) ${version//+/.}" ; then
	is_present=0
	break
      fi
    done
  fi

  # ... and build depending on that
  if [[ $is_present == 1 ]] ; then
    # move orig tarball out of the way
    make-pkgtools move-debian-files
    reason="ALREADY-PRESENT"
  else # build it
    reason="SUCCESS"

    # install build dependencies, and build package
    install-build-deps $pkg \
      && dpkg-buildpackage --host-arch $ARCHITECTURE -i.* $dpkg_buildpackage_options --no-sign \
      || reason=FAILURE

    # upload only if needed
    if [[ reason != "FAILURE" && -n "$UPLOAD" && "$UPLOAD" != 0 ]] ; then
      make-pkgtools DPUT_METHOD=${UPLOAD} move-debian-files release || reason="FAILURE"
    fi
  fi

  # clean
  make-pkgtools move-debian-files clean-untangle-files clean-build

  # so it can be extracted by the calling shell when do-build is piped
  # into tee in VERBOSE mode
  echo $reason $version
}

## main

echo "pkgtools version ${PKGTOOLS_VERSION}"

# add mirror targetting REPOSITORY & DISTRIBUTION
echo "deb http://package-server/public/$REPOSITORY $DISTRIBUTION main non-free" > /etc/apt/sources.list.d/${DISTRIBUTION}.list
apt-get update -q

# update apt-show-versions cache
apt-show-versions -i

# main return code
rc=0

# iterate over packages to build
for pkg in $(awk -v repo=$REPOSITORY '$2 ~ repo && ! /^(#|$)/ {print $1}' build-order.txt) ; do
  log "BEGIN $pkg"

  if [[ -n "$PACKAGE" ]] && ! [[ $pkg = $PACKAGE ]] ; then
    log "NO-PKG-MATCH $pkg"
    continue
  fi

  # kernel source tree need to be prepared
  if [[ "$pkg" =~ "/linux-" ]] ; then
    pushd $(dirname "$pkg") > /dev/null
    make patch version control-real
    popd > /dev/null    
  fi

  # to build or not to build, depending on target architecture and
  # package specs
  arches_to_build="${ARCHITECTURE}|any" # always build arch-dep
  if [[ $ARCHITECTURE == "amd64" ]] ; then
    # also build arch-indep packages
    arches_to_build="${arches_to_build}|all"
    # build source *and* binary packages
    DPKG_BUILDPACKAGE_OPTIONS="-sa"
  else
    # only build binary packages
    DPKG_BUILDPACKAGE_OPTIONS="-B"
  fi
  if ! grep -qE "^Architecture:.*(${arches_to_build})" ${pkg}/debian/control ; then
    log "NO-ARCHITECTURE-MATCH $pkg"
    continue
  fi

  pushd $pkg > /dev/null

  logfile=/tmp/${REPOSITORY}-${DISTRIBUTION}-${pkg//\//_}.log

  if [[ -n "$VERBOSE" && "$VERBOSE" != 0 ]] ; then
    do-build $pkg $DPKG_BUILDPACKAGE_OPTIONS 2>&1 | tee $logfile
  else
    do-build $pkg $DPKG_BUILDPACKAGE_OPTIONS > $logfile 2>&1 &
    wait-for-pid $!
  fi

  # always extract reason & version from logfile
  set $(tail -n 1 $logfile)
  reason=$1
  version=$2

  if [[ $reason == "FAILURE" ]] ; then
    let rc=rc+1 # global failure count
    [[ -n "$VERBOSE" && "$VERBOSE" != 0 ]] || cat $logfile
  fi

  rm -f $logfile

  log "$reason $pkg $version"
  popd > /dev/null
done

exit $rc
