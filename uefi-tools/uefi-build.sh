#!/bin/bash

#
# Board Configuration Section
# ===========================
#
# Board configuration moved to parse-platforms.py and platforms.config.
#
# No need to edit below unless you are changing script functionality.
#

unset WORKSPACE EDK_TOOLS_DIR MAKEFLAGS

TOOLS_DIR="`dirname $0`"
export TOOLS_DIR
. "$TOOLS_DIR"/common-functions
PLATFORM_CONFIG=""
VERBOSE=0
ATF_DIR=
TOS_DIR=
TOOLCHAIN=
OPENSSL_CONFIGURED=FALSE

# Number of threads to use for build
export NUM_THREADS=$((`getconf _NPROCESSORS_ONLN` + 1))

function do_build
{
	PLATFORM_NAME="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o longname`"
	PLATFORM_PREBUILD_CMDS="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o prebuild_cmds`"
	PLATFORM_BUILDFLAGS="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o buildflags`"
	PLATFORM_BUILDFLAGS="$PLATFORM_BUILDFLAGS ${EXTRA_OPTIONS[@]}"
	PLATFORM_BUILDCMD="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o buildcmd`"
	PLATFORM_DSC="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o dsc`"
	PLATFORM_PACKAGES_PATH="$PWD"
	COMPONENT_INF="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o inf`"

	PLATFORM_ARCH="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o arch`"
	if [ -n "$PLATFORM_ARCH" ]; then
		if [ -n "$DEFAULT_PLATFORM_ARCH" -a "$DEFAULT_PLATFORM_ARCH" != "$PLATFORM_ARCH" ]; then
			echo "Command line specified architecture '$DEFAULT_PLATFORM_ARCH'" >&2
			echo "differs from config file specified '$PLATFORM_ARCH'" >&2
			return 1
		fi
	else
		if [ ! -n "$DEFAULT_PLATFORM_ARCH" ]; then
			echo "Unknown target architecture - aborting!" >&2
			return 1
		fi
		PLATFORM_ARCH="$DEFAULT_PLATFORM_ARCH"
	fi
	TEMP_PACKAGES_PATH="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o packages_path`"
	if [ -n "$TEMP_PACKAGES_PATH" ]; then
		IFS=:
		for path in "$TEMP_PACKAGES_PATH"; do
			case "$path" in
				/*)
					PLATFORM_PACKAGES_PATH="$PLATFORM_PACKAGES_PATH:$path"
				;;
				*)
					PLATFORM_PACKAGES_PATH="$PLATFORM_PACKAGES_PATH:$PWD/$path"
				;;
		        esac
		done
		unset IFS
	fi
	if [ $VERBOSE -eq 1 ]; then
		echo "Setting build parallellism to $NUM_THREADS processes\n"
		echo "PLATFORM_NAME=$PLATFORM_NAME"
		echo "PLATFORM_PREBUILD_CMDS=$PLATFORM_PREBUILD_CMDS"
		echo "PLATFORM_BUILDFLAGS=$PLATFORM_BUILDFLAGS"
		echo "PLATFORM_BUILDCMD=$PLATFORM_BUILDCMD"
		echo "PLATFORM_DSC=$PLATFORM_DSC"
		echo "PLATFORM_ARCH=$PLATFORM_ARCH"
		echo "PLATFORM_PACKAGES_PATH=$PLATFORM_PACKAGES_PATH"
	fi

	if [[ "${PLATFORM_BUILDFLAGS}" =~ "SECURE_BOOT_ENABLE=TRUE" ]]; then
	    import_openssl
	fi

	if [ -n "$CROSS_COMPILE_64" -a "$PLATFORM_ARCH" == "AARCH64" ]; then
		TEMP_CROSS_COMPILE="$CROSS_COMPILE_64"
	elif [ -n "$CROSS_COMPILE_32" -a "$PLATFORM_ARCH" == "ARM" ]; then
		TEMP_CROSS_COMPILE="$CROSS_COMPILE_32"
	else
		set_cross_compile
	fi

	CROSS_COMPILE="$TEMP_CROSS_COMPILE"

	echo "Building $PLATFORM_NAME - $PLATFORM_ARCH"
	echo "CROSS_COMPILE=\"$TEMP_CROSS_COMPILE\""
	echo "$board"_BUILDFLAGS="'$PLATFORM_BUILDFLAGS'"

	if [ "$TARGETS" == "" ]; then
		TARGETS=( RELEASE )
	fi

	case $TOOLCHAIN in
		"gcc")
			TOOLCHAIN=`get_gcc_version "$CROSS_COMPILE"gcc`
			if [ $? -ne 0 ]; then
				echo "${CROSS_COMPILE}gcc not found!" >&2
				return 1
			fi
			;;
		"clang")
			TOOLCHAIN=`get_clang_version clang`
			if [ $? -ne 0 ]; then
				return 1
			fi
			;;
	esac
	export TOOLCHAIN
	echo "TOOLCHAIN is ${TOOLCHAIN}"

	export ${TOOLCHAIN}_${PLATFORM_ARCH}_PREFIX=$CROSS_COMPILE
	echo "Toolchain prefix: ${TOOLCHAIN}_${PLATFORM_ARCH}_PREFIX=$CROSS_COMPILE"

	export PACKAGES_PATH="$PLATFORM_PACKAGES_PATH"
	for target in "${TARGETS[@]}" ; do
		if [ X"$PLATFORM_PREBUILD_CMDS" != X"" ]; then
			echo "Run pre build commands"
			eval ${PLATFORM_PREBUILD_CMDS}
		fi

		if [ -n "$COMPONENT_INF" ]; then
			# Build a standalone component
			build -n $NUM_THREADS -a "$PLATFORM_ARCH" -t ${TOOLCHAIN} -p "$PLATFORM_DSC" \
				-m "$COMPONENT_INF" -b "$target" ${PLATFORM_BUILDFLAGS}
		else
			# Build a platform
			build -n $NUM_THREADS -a "$PLATFORM_ARCH" -t ${TOOLCHAIN} -p "$PLATFORM_DSC" \
				-b "$target" ${PLATFORM_BUILDFLAGS}
		fi

		RESULT=$?
		if [ $RESULT -eq 0 ]; then
			if [ X"$TOS_DIR" != X"" ]; then
				pushd $TOS_DIR >/dev/null
				if [ $VERBOSE -eq 1 ]; then
					echo "$TOOLS_DIR/tos-build.sh -e "$EDK2_DIR" -t "$target"_${TOOLCHAIN} $board"
				fi
				$TOOLS_DIR/tos-build.sh -e "$EDK2_DIR" -t "$target"_${TOOLCHAIN} $board
				RESULT=$?
				popd >/dev/null
			fi
		fi
		if [ $RESULT -eq 0 ]; then
			if [ X"$ATF_DIR" != X"" ]; then
				pushd $ATF_DIR >/dev/null
				if [ $VERBOSE -eq 1 ]; then
					echo "$TOOLS_DIR/atf-build.sh -e "$EDK2_DIR" -t "$target"_${TOOLCHAIN} $board"
				fi
				$TOOLS_DIR/atf-build.sh -e "$EDK2_DIR" -t "$target"_${TOOLCHAIN} $board
				RESULT=$?
				popd >/dev/null
			fi
		fi
		result_log $RESULT "$PLATFORM_NAME $target"
	done
	unset PACKAGES_PATH
}


function clearcache
{
  CONF_FILES="build_rule target tools_def"
  if [ -z "$EDK_TOOLS_PATH" ]
  then
    TEMPLATE_PATH=./BaseTools/Conf/
  else
    TEMPLATE_PATH="$EDK_TOOLS_PATH/Conf/"
  fi

  for File in $CONF_FILES
  do
    TEMPLATE_FILE="$TEMPLATE_PATH/$File.template"
    CACHE_FILE="Conf/$File.txt"
    if [ -e "$CACHE_FILE" -a "$TEMPLATE_FILE" -nt "$CACHE_FILE" ]
    then
      echo "Removing outdated '$CACHE_FILE'."
      rm "$CACHE_FILE"
    fi
  done

  unset TEMPLATE_PATH TEMPLATE_FILE CACHE_FILE
}


function uefishell
{
	BUILD_ARCH=`uname -m`
	case $BUILD_ARCH in
		arm*)
			ARCH=ARM
			;;
		aarch64)
			ARCH=AARCH64
			;;
		*)
			unset ARCH
			;;
	esac
	export ARCH
	export EDK_TOOLS_PATH=`pwd`/BaseTools
	clearcache
	. edksetup.sh BaseTools
	if [ $VERBOSE -eq 1 ]; then
		echo "Building BaseTools"
	fi
	make -C $EDK_TOOLS_PATH
	if [ $? -ne 0 ]; then
		echo " !!! UEFI BaseTools failed to build !!! " >&2
		exit 1
	fi
}


function usage
{
	echo "usage:"
	echo -n "uefi-build.sh [-b DEBUG | RELEASE] [ all "
	for board in "${boards[@]}" ; do
	    echo -n "| $board "
	done
	echo "]"
	printf "%8s\tbuild %s\n" "all" "all supported platforms"
	for board in "${boards[@]}" ; do
		PLATFORM_NAME="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG -p $board get -o longname`"
		printf "%8s\tbuild %s\n" "$board" "${PLATFORM_NAME}"
	done
}

#
# Since we do a command line validation on whether specified platforms exist or
# not, do a first pass of command line to see if there is an explicit config
# file there to read valid platforms from.
#
commandline=( "$@" )
i=0
for arg;
do
	if [ $arg == "-c" ]; then
		FILE_ARG=${commandline[i + 1]}
		if [ ! -f "$FILE_ARG" ]; then
			echo "ERROR: configuration file '$FILE_ARG' not found" >&2
			exit 1
		fi
		case "$FILE_ARG" in
			/*)
				PLATFORM_CONFIG="-c $FILE_ARG"
			;;
			*)
				PLATFORM_CONFIG="-c `readlink -f \"$FILE_ARG\"`"
			;;
		esac
		echo "Platform config file: '$FILE_ARG'"
		export PLATFORM_CONFIG
	fi
	i=$(($i + 1))
done

builds=()
boards=()
boardlist="`$TOOLS_DIR/parse-platforms.py $PLATFORM_CONFIG shortlist`"
for board in $boardlist; do
    boards=(${boards[@]} $board)
done

NUM_TARGETS=0

while [ "$1" != "" ]; do
	case $1 in
		all )
			builds=(${boards[@]})
			NUM_TARGETS=$(($NUM_TARGETS + 1))
			;;
		"/h" | "/?" | "-?" | "-h" | "--help" )
			usage
			exit
			;;
		"-v" )
			VERBOSE=1
			;;
		"-a" )
			shift
			ATF_DIR="$1"
			;;
		"-A" )
			shift
			DEFAULT_PLATFORM_ARCH="$1"
			;;
		"-c" )
			# Already parsed above - skip this + option
			shift
			;;
		"-s" )
			shift
			export TOS_DIR="$1"
			;;
		"-b" | "--build" )
			shift
			echo "Adding Build profile: $1"
			TARGETS=( ${TARGETS[@]} $1 )
			;;
		"-D" )
			shift
			echo "Adding option: -D $1"
			EXTRA_OPTIONS=( ${EXTRA_OPTIONS[@]} "-D" $1 )
			;;
		"-T" )
			shift
			echo "Setting toolchain to '$1'"
			TOOLCHAIN="$1"
			;;
		"-1" )
			NUM_THREADS=1
			;;
		* )
			MATCH=0
			for board in "${boards[@]}" ; do
				if [ "$1" == $board ]; then
					MATCH=1
					builds=(${builds[@]} "$board")
					break
				fi
			done

			if [ $MATCH -eq 0 ]; then
				echo "unknown arg $1"
				usage
				exit 1
			fi
			NUM_TARGETS=$(($NUM_TARGETS + 1))
			;;
	esac
	shift
done

# If there were no args, use a menu to select a single board / all boards to build
if [ $NUM_TARGETS -eq 0 ]
then
	read -p "$(
			f=0
			for board in "${boards[@]}" ; do
					echo "$((++f)): $board"
			done
			echo $((++f)): all

			echo -ne '> '
	)" selection

	if [ "$selection" -eq $((${#boards[@]} + 1)) ]; then
		builds=(${boards[@]})
	else
		builds="${boards[$((selection-1))]}"
	fi
fi

# Check to see if we are in a UEFI repository
# refuse to continue if we aren't
if [ ! -e BaseTools ]
then
	echo "ERROR: we aren't in the UEFI directory."
	echo "       I can tell because I can't see the BaseTools directory"
	exit 1
fi

EDK2_DIR="$PWD"
export VERBOSE

if [[ "${EXTRA_OPTIONS[@]}" != *"FIRMWARE_VER"* ]]; then
	if test -d .git && head=`git rev-parse --verify --short HEAD 2>/dev/null`; then
		FIRMWARE_VER=`git rev-parse --short HEAD`
		if ! git diff-index --quiet HEAD --; then
			FIRMWARE_VER="${FIRMWARE_VER}-dirty"
		fi
		EXTRA_OPTIONS=( ${EXTRA_OPTIONS[@]} "-D" FIRMWARE_VER=$FIRMWARE_VER )
		if [ $VERBOSE -eq 1 ]; then
			echo "FIRMWARE_VER=$FIRMWARE_VER"
			echo "EXTRA_OPTIONS=$EXTRA_OPTIONS"
		fi
	fi
fi

uefishell

if [ X"$TOOLCHAIN" = X"" ]; then
	TOOLCHAIN=gcc
fi

for board in "${builds[@]}" ; do
	do_build
done

result_print
