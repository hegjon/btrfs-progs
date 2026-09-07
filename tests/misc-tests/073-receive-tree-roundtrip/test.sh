#!/bin/bash
#
# Receive must reproduce a tree exactly, whichever way it creates the inodes.
# Covers what the receive fast paths rely on: inodes created under their
# final name (regular files, directories, symlinks, hard links, sparse and
# empty files, xattrs), the chown short cut for root-owned inodes (non-root
# owners, root-owned files inside setgid directories), the buffered stream
# reader (a stream delivered in 7-byte pieces, a truncated stream), an
# incremental stream that swaps file and directory types, and a receive that
# must fail on a full filesystem. Each round trip is checked with fssum.

source "$TEST_TOP/common" || exit

check_prereq mkfs.btrfs
check_prereq btrfs
check_prereq fssum
check_global_prereq dd
check_global_prereq setfattr

setup_root_helper
prepare_test_dev

FSSUM_PROG="$INTERNAL_BIN/fssum"
here=$(pwd)
src="$TEST_MNT/src"
recv="$TEST_MNT/recv"

populate() {
	local dir="$1"

	run_check $SUDO_HELPER mkdir -p "$dir/dir/sub/deep" "$dir/private" "$dir/setgid/inner" "$dir/swap/d" "$dir/links"
	# Regular files: inline, one extent, several extents, incompressible
	run_check $SUDO_HELPER dd if=/dev/zero of="$dir/dir/small" bs=1K count=3 status=none
	run_check $SUDO_HELPER dd if=/dev/zero of="$dir/dir/sub/medium" bs=64K count=3 status=none
	run_check $SUDO_HELPER dd if=/dev/zero of="$dir/dir/sub/deep/large" bs=1M count=3 status=none
	run_check $SUDO_HELPER dd if=/dev/urandom of="$dir/dir/random" bs=256K count=2 status=none
	run_check $SUDO_HELPER touch "$dir/dir/empty"
	# Sparse: data, hole, data, and a trailing hole
	run_check $SUDO_HELPER dd if=/dev/urandom of="$dir/dir/sparse" bs=64K count=1 status=none
	run_check $SUDO_HELPER dd if=/dev/urandom of="$dir/dir/sparse" bs=64K count=1 seek=8 conv=notrunc status=none
	run_check $SUDO_HELPER truncate -s 2M "$dir/dir/sparse"
	# Symlinks: relative, absolute, dangling
	run_check $SUDO_HELPER ln -s sub/medium "$dir/dir/rel"
	run_check $SUDO_HELPER ln -s /etc/hostname "$dir/dir/abs"
	run_check $SUDO_HELPER ln -s nowhere "$dir/dir/dangling"
	# Hard links: within a directory and across directories
	run_check $SUDO_HELPER ln "$dir/dir/small" "$dir/dir/small.link"
	run_check $SUDO_HELPER ln "$dir/dir/sub/medium" "$dir/links/medium.link"
	# xattr
	run_check $SUDO_HELPER setfattr -n user.test -v roundtrip "$dir/dir/small"
	# Modes and owners
	run_check $SUDO_HELPER chmod 0700 "$dir/private"
	run_check $SUDO_HELPER touch "$dir/private/secret"
	run_check $SUDO_HELPER chmod 0600 "$dir/private/secret"
	run_check $SUDO_HELPER chmod 4755 "$dir/dir/random"
	run_check $SUDO_HELPER chown 1000:1000 "$dir/dir/empty" "$dir/private"
	run_check $SUDO_HELPER chown 0:1000 "$dir/dir/small"
	# Setgid directory with a non-root group: files created below it get that
	# group unless chowned back, so a receive that skips chown to root:root
	# must know about it
	run_check $SUDO_HELPER chgrp 100 "$dir/setgid" "$dir/setgid/inner"
	run_check $SUDO_HELPER chmod 2775 "$dir/setgid" "$dir/setgid/inner"
	run_check $SUDO_HELPER touch "$dir/setgid/root-owned" "$dir/setgid/inner/root-owned"
	run_check $SUDO_HELPER chown 0:0 "$dir/setgid/root-owned" "$dir/setgid/inner/root-owned"
	run_check $SUDO_HELPER touch "$dir/setgid/group-owned"
	# Things the incremental step will swap
	run_check $SUDO_HELPER touch "$dir/swap/f" "$dir/swap/d/child"
	run_check $SUDO_HELPER ln -s f "$dir/swap/l"
}

# Second version of the tree for the incremental stream: file <-> directory
# <-> symlink swaps, a rename over an existing name, changed content and owner
modify() {
	local dir="$1"

	run_check $SUDO_HELPER rm "$dir/swap/f"
	run_check $SUDO_HELPER mkdir "$dir/swap/f"
	run_check $SUDO_HELPER touch "$dir/swap/f/child"
	run_check $SUDO_HELPER rm -r "$dir/swap/d"
	run_check $SUDO_HELPER touch "$dir/swap/d"
	run_check $SUDO_HELPER rm "$dir/swap/l"
	run_check $SUDO_HELPER touch "$dir/swap/l"
	run_check $SUDO_HELPER mv -T "$dir/dir/sub/medium" "$dir/dir/small"
	run_check $SUDO_HELPER dd if=/dev/urandom of="$dir/dir/sub/deep/large" bs=1M count=1 seek=1 conv=notrunc status=none
	run_check $SUDO_HELPER chown 1000:100 "$dir/setgid/root-owned"
	run_check $SUDO_HELPER touch "$dir/setgid/inner/new-root-owned"
	run_check $SUDO_HELPER chown 0:0 "$dir/setgid/inner/new-root-owned"
}

checksum() {
	run_check $FSSUM_PROG -A -f -w "$here/$1.fssum" "$2"
}

verify() {
	run_check $FSSUM_PROG -r "$here/$1.fssum" "$2"
}

run_check_mkfs_test_dev
run_check_mount_test_dev
run_check $SUDO_HELPER "$TOP/btrfs" subvolume create "$src"
populate "$src"
run_check $SUDO_HELPER "$TOP/btrfs" subvolume snapshot -r "$src" "$TEST_MNT/snap1"
checksum snap1 "$TEST_MNT/snap1"
modify "$src"
run_check $SUDO_HELPER "$TOP/btrfs" subvolume snapshot -r "$src" "$TEST_MNT/snap2"
checksum snap2 "$TEST_MNT/snap2"

_mktemp_local full.stream
_mktemp_local incr.stream
run_check $SUDO_HELPER "$TOP/btrfs" send -q --compressed-data -f "$here/full.stream" "$TEST_MNT/snap1"
run_check $SUDO_HELPER "$TOP/btrfs" send -q --compressed-data -p "$TEST_MNT/snap1" -f "$here/incr.stream" "$TEST_MNT/snap2"

# Plain round trip, then the incremental on top of it
run_check $SUDO_HELPER mkdir "$recv"
run_check $SUDO_HELPER "$TOP/btrfs" receive -q -f "$here/full.stream" "$recv"
verify snap1 "$recv/snap1"
run_check $SUDO_HELPER "$TOP/btrfs" receive -q -f "$here/incr.stream" "$recv"
verify snap2 "$recv/snap2"

# The stream arriving in small pieces must not change the result
run_check $SUDO_HELPER mkdir "$recv-chunked"
run_check $SUDO_HELPER bash -c "dd if='$here/full.stream' bs=7 status=none | '$TOP/btrfs' receive -q '$recv-chunked'"
verify snap1 "$recv-chunked/snap1"

# A truncated stream must fail, not pass as a shorter tree
_mktemp_local trunc.stream
run_check bash -c "head -c \$(( \$(stat -c %s '$here/full.stream') * 2 / 3 )) '$here/full.stream' > '$here/trunc.stream'"
run_check $SUDO_HELPER mkdir "$recv-trunc"
run_mustfail "truncated stream accepted" $SUDO_HELPER "$TOP/btrfs" receive -q -f "$here/trunc.stream" "$recv-trunc"

run_check_umount_test_dev

# A stream that does not fit: the receive must exit non-zero
run_check_mkfs_test_dev
run_check_mount_test_dev
run_check $SUDO_HELPER "$TOP/btrfs" subvolume create "$src"
run_check $SUDO_HELPER dd if=/dev/urandom of="$src/big" bs=1M count=200 status=none
run_check $SUDO_HELPER "$TOP/btrfs" subvolume snapshot -r "$src" "$TEST_MNT/snap"
_mktemp_local big.stream
run_check $SUDO_HELPER "$TOP/btrfs" send -q -f "$here/big.stream" "$TEST_MNT/snap"
run_check_umount_test_dev
run_check_mkfs_test_dev -b 256M
run_check_mount_test_dev
run_check $SUDO_HELPER mkdir "$recv"
run_mustfail "receive succeeded on a filesystem too small for the stream" \
	$SUDO_HELPER "$TOP/btrfs" receive -q -f "$here/big.stream" "$recv"
run_check_umount_test_dev

rm -f -- "$here"/*.fssum "$here"/*.stream
