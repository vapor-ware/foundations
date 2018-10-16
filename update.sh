#!/bin/bash
set -Eeuo pipefail

version="${1:-bionic}"
hostArch="$(dpkg --print-architecture)"
arch="$(cat arch 2>/dev/null || true)"
: ${arch:=$hostArch}

thisTarBase="ubuntu-$version-core-cloudimg-$arch"
thisTar="$thisTarBase-root.tar.gz"
baseUrl="https://partner-images.canonical.com/core/$version"

mkdir -p $version

if \
	wget -q --spider "$baseUrl/current" \
	&& wget -q --spider "$baseUrl/current/$thisTar" \
; then
	baseUrl+='/current'
else
	# appears to be missing a "current" symlink (or $arch doesn't exist in /current/)
	# let's enumerate all the directories and try to find one that's satisfactory
	toAttempt=( $(wget -qO- "$baseUrl/" | awk -F '</?a[^>]*>' '$2 ~ /^[0-9.]+\/$/ { gsub(/\/$/, "", $2); print $2 }' | sort -rn) )
	current=
	for attempt in "${toAttempt[@]}"; do
		if wget -q --spider "$baseUrl/$attempt/$thisTar"; then
			current="$attempt"
			break
		fi
	done
	if [ -z "$current" ]; then
		echo >&2 "warning: cannot find 'current' for $version"
		echo >&2 "  (checked all dirs under $baseUrl/)"
		continue
	fi
	baseUrl+="/$current"
	echo "SERIAL=$current" > "$version/build-info.txt" # this will be overwritten momentarily if this directory has one
fi

wget -qN "$baseUrl/"{{MD5,SHA{1,256}}SUMS{,.gpg},"$thisTarBase.manifest",'unpacked/build-info.txt'} -P $version/ || true
wget -N --progress=dot:giga "$baseUrl/$thisTar" -P $version/

badness=

gpgFingerprint="$(grep -v '^#' gpg-fingerprint 2>/dev/null || true)"
if [ -z "$gpgFingerprint" ]; then
	echo >&2 'warning: missing gpg-fingerprint! skipping PGP verification!'
	badness=1
else
	export GNUPGHOME="$(mktemp -d)"
	trap "rm -r '$GNUPGHOME'" EXIT
	gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$gpgFingerprint"
fi

for sums in sha256 sha1 md5; do
	sumsFile="$version/${sums^^}SUMS" # "SHA256SUMS"
	sumCmd="${sums}sum" # "sha256sum"
	if [ "$gpgFingerprint" ]; then
		if [ ! -f "$sumsFile.gpg" ]; then
			echo >&2 "warning: '$sumsFile.gpg' appears to be missing!"
			badness=1
		else
			( set -x; gpg --batch --verify "$sumsFile.gpg" "$sumsFile" )
		fi
	fi
	if [ -f "$sumsFile" ]; then
		grep " *$thisTar\$" "$sumsFile" | ( set -x; cd $version; "$sumCmd" -c - )
	else
		echo >&2 "warning: missing '$sumsFile'!"
		badness=1
	fi
done

if [ "$badness" ]; then
	false
fi
