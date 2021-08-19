#!/usr/bin/env bash

# turn off all error aborting to not skip out on borg info call on unset repo
set -ETu #-e -o pipefail
trap cleanup SIGINT SIGTERM ERR

cleanup() {
	# script cleanup here
	echo "Some part of the script failed with an error: $? @LINE: $(caller)";
	# end trap
	trap - SIGINT SIGTERM ERR
}

# set last edit date + time
VERSION="20210819-0901";
# creates borg backup based on the include/exclude files
# if base borg folder (backup files) does not exist, it will automatically init it
# base folder
BASE_FOLDER="/usr/local/scripts/borg/";
# include and exclude file
INCLUDE_FILE="borg.backup.include";
EXCLUDE_FILE="borg.backup.exclude";
SETTINGS_FILE="borg.backup.settings";
# debug/verbose
VERBOSE=0;
LIST=0;
DEBUG=0;
INFO=0;
# other variables
TARGET_SERVER='';
REGEX='';
REGEX_COMMENT="^[\ \t]*#";
REGEX_GLOB='\*';
REGEX_NUMERIC="^[0-9]$";
PRUNE_DEBUG='';
INIT_REPOSITORY=0;
FOLDER_OK=0;
TMP_EXCLUDE_FILE='';
# opt flags
OPT_VERBOSE='';
OPT_PROGRESS='';
OPT_LIST='';
OPT_REMOTE='';
# config variables (will be overwritten from .settings file)
TARGET_USER="";
TARGET_HOST="";
TARGET_PORT="";
TARGET_BORG_PATH="";
TARGET_FOLDER="";
BACKUP_FILE="";
COMPRESSION="";
COMPRESSION_LEVEL="";
ENCRYPTION="none";
DATE=""; # to be deprecated
BACKUP_SET="";
KEEP_DAYS="";
KEEP_WEEKS="";
KEEP_MONTHS="";

function usage()
{
	cat <<- EOT
	Usage: ${0##/*/} [-c <config folder>] [-v] [-d]

	-c <config folder>: if this is not given, ${BASE_FOLDER} is used
	-v: be verbose
	-l: list files during backup
	-d: only do dry run
	-i: print out only info
	-h: this help page

	Version: ${VERSION}
	EOT
}

# set options
while getopts ":c:vldih" opt; do
	case "${opt}" in
		c|config)
			BASE_FOLDER=${OPTARG};
			;;
		v|verbose)
			VERBOSE=1;
			;;
		l|list)
			LIST=1;
			;;
		i|info)
			INFO=1;
			;;
		d|debug)
			DEBUG=1;
			;;
		h|help)
			usage;
			exit;
			;;
		:)
			echo "Option -$OPTARG requires an argument."
			;;
		\?)
			echo -e "\n Option does not exist: ${OPTARG}\n";
			usage;
			exit 1;
			;;
	esac;
done;

# add trailing slasd for base folder
[[ "${BASE_FOLDER}" != */ ]] && BASE_FOLDER="${BASE_FOLDER}/";

if [ ! -f "${BASE_FOLDER}${SETTINGS_FILE}" ]; then
	echo "No settings file could be found: ${BASE_FOLDER}${SETTINGS_FILE}";
	exit 1;
fi;

# verbose & progress
if [ ${VERBOSE} -eq 1 ]; then
	OPT_VERBOSE="-v";
	OPT_PROGRESS="-p";
	echo "Script version: ${VERSION}";
fi;
# list files
if [ ${LIST} -eq 1 ]; then
	OPT_LIST="--list";
fi;

# read config file
. "${BASE_FOLDER}${SETTINGS_FILE}";

# remote borg path
if [ ! -z "${TARGET_BORG_PATH}" ]; then
	OPT_REMOTE="--remote-path "$(printf "%q" "${TARGET_BORG_PATH}");
fi;

if [ -z "${TARGET_FOLDER}" ]; then
	echo "No target folder has been set yet";
	exit 1;
else
	# This does not care for multiple trailing or leading slashes
	# it just makes sure we have at least one set
	# for if we have a single slash, remove it
	TARGET_FOLDER=${TARGET_FOLDER%/}
	TARGET_FOLDER=${TARGET_FOLDER#/}
	# and add slash front and back and escape the path
	TARGET_FOLDER=$(printf "%q" "/${TARGET_FOLDER}/");
fi;

# if we have user/host then we build the ssh command
TARGET_SERVER='';
# allow host only (if full setup in .ssh/config)
# user@host OR ssh://user@host:port/ IF TARGET_PORT is set
# user/host/port
if [ ! -z "${TARGET_USER}" ] && [ ! -z "${TARGET_HOST}" ] && [ ! -z "${TARGET_PORT}" ]; then
	TARGET_SERVER="ssh://"${TARGET_USER}"@"${TARGET_HOST}":"${TARGET_PORT}"/";
# host/port
elif [ ! -z "${TARGET_HOST}" ] && [ ! -z "${TARGET_PORT}" ]; then
	TARGET_SERVER="ssh://"${TARGET_HOST}":"${TARGET_PORT}"/";
# user/host
elif [ ! -z "${TARGET_USER}" ] && [ ! -z "${TARGET_HOST}" ]; then
	TARGET_SERVER=${TARGET_USER}"@"${TARGET_HOST}":";
# host
elif [ ! -z "${TARGET_HOST}" ]; then
	TARGET_SERVER=${TARGET_HOST}":";
fi;
REPOSITORY=${TARGET_SERVER}${TARGET_FOLDER}${BACKUP_FILE};

if [ ! -f "${BASE_FOLDER}${INCLUDE_FILE}" ]; then
	echo "The include folder file ${INCLUDE_FILE} is missing";
	exit 1;
fi;

# error if the repository file still has the default name
REGEX="^some\-prefix\-";
if [[ "${BACKUP_FILE}" =~ ${REGEX} ]]; then
	echo "The repository name still has the default prefix: ${BACKUP_FILE}";
	exit 1;
fi;

# check compression if given is valid and check compression level is valid if given
if [ ! -z "${COMPRESSION}" ]; then
	# valid compress
	if [ "${COMPRESSION}" = "lz4" ] || [ "${COMPRESSION}" = "zlib" ] || [ "${COMPRESSION}" = "lzma" ]; then
		OPT_COMPRESSION="-C ${COMPRESSION}";
		# if COMPRESSION_LEVEL, check it is a valid regex
		# ignore it if this is lz4
		if [ ! -z "${COMPRESSION_LEVEL}" ] && [ "${COMPRESSION}" != "lz4" ]; then
			if ! [[ "${COMPRESSION_LEVEL}" =~ ${REGEX_NUMERIC} ]]; then
				echo "Compression level needs to be a value from 0 to 9: ${COMPRESSION_LEVEL}";
				exit 1;
			else
				OPT_COMPRESSION=${OPT_COMPRESSION}","${COMPRESSION_LEVEL};
			fi;
		fi;
	else
		echo "Compress setting need to be lz4, zlib or lzma. Or empty for no compression: ${COMPRESSION}";
		exit 1;
	fi;
fi;

# home folder, needs to be set if there is eg a HOME=/ in the crontab
if [ ! -w "${HOME}" ] || [ "${HOME}" = '/' ]; then
	HOME=$(eval echo "$(whoami)");
fi;

# set BACKUP_SET if empty, check for for DATE is set
if [ -z "${BACKUP_SET}" ]; then
	# DATE is deprecated and will be removed
	if [ ! -z "${DATE}" ]; then
		echo "DEPRECATED: The use of DATE variable is deprecated, use BACKUP_SET instead";
		BACKUP_SET="${DATE}";
	else
		# default
		BACKUP_SET="{now:%Y-%m-%d}";
	fi;
fi;

# base command
COMMAND="borg create ${OPT_REMOTE} -v ${OPT_LIST} ${OPT_PROGRESS} ${OPT_COMPRESSION} -s ${REPOSITORY}::${BACKUP_SET}";
# include list
while read include_folder; do
	# strip any leading spaces from that folder
	include_folder=$(echo "${include_folder}" | sed -e 's/^[ \t]*//');
	# check that those folders exist, warn on error,
	# but do not exit unless there are no valid folders at all
	# skip folders that are with # in front (comment)
	if [[ "${include_folder}" =~ ${REGEX_COMMENT} ]]; then
		echo "# [C] Comment: '${include_folder}'";
	else
		# skip if it is empty
		if [ ! -z "${include_folder}" ]; then
			# if this is a glob, do a double check that the base folder actually exists (?)
			if [[ "${include_folder}" =~ $REGEX_GLOB ]]; then
				# if this is */ then allow it
				# remove last element beyond the last /
				# if there is no path, just allow it (general rule)
				_include_folder=${include_folder%/*};
				# if still a * inside -> add as is, else check for folder
				if [[ "${include_folder}" =~ $REGEX_GLOB ]]; then
					FOLDER_OK=1;
					echo "+ [I] Backup folder with folder path glob '${include_folder}'";
					# glob (*) would be escape so we replace it with a temp part and then reinsert it
					COMMAND=${COMMAND}" "$(printf "%q" $(echo "${include_folder}" | sed 's/\*/_STARGLOB_/g') | sed 's/_STARGLOB_/\*/g');
				elif [ ! -d "${_include_folder}" ]; then
					echo "- [I] Backup folder with glob '${include_folder}' does not exist or is not accessable";
				else
					FOLDER_OK=1;
					echo "+ [I] Backup folder with glob '${include_folder}'";
					COMMAND=${COMMAND}" "$(printf "%q" ${include_folder});
				fi;
			# normal folder
			elif [ ! -d "${include_folder}" ] && [ ! -e "${include_folder}" ]; then
				echo "- [I] Backup folder or file '${include_folder}' does not exist or is not accessable";
			else
				FOLDER_OK=1;
				# if it is a folder, remove the last / or the symlink check will not work
				if [ -d "${include_folder}" ]; then
					_include_folder=${include_folder%/*};
				else
					_include_folder=${include_folder};
				fi;
				# Warn if symlink & folder -> only smylink will be backed up
				if [ -h "${_include_folder}" ]; then
					echo "~ [I] Target '${include_folder}' is a symbolic link. No real data will be backed up";
				else
					echo "+ [I] Backup folder or file '${include_folder}'";
				fi;
				COMMAND=${COMMAND}" "$(printf "%q" ${include_folder});
			fi;
		fi;
	fi;
done<"${BASE_FOLDER}${INCLUDE_FILE}";
# exclude list
if [ -f "${BASE_FOLDER}${EXCLUDE_FILE}" ]; then
	# check that the folders in that exclude file are actually valid, remove non valid ones and warn
	#TMP_EXCLUDE_FILE=$(mktemp --tmpdir ${EXCLUDE_FILE}.XXXXXXXX); #non mac
	TMP_EXCLUDE_FILE=$(mktemp ${BASE_FOLDER}${EXCLUDE_FILE}.XXXXXXXX);
	while read exclude_folder; do
		# strip any leading spaces from that folder
		exclude_folder=$(echo "${exclude_folder}" | sed -e 's/^[ \t]*//');
		# folder or any type of file is ok
		# because of glob files etc, exclude only comments (# start)
		if [[ "${exclude_folder}" =~ ${REGEX_COMMENT} ]]; then
			echo "# [C] Comment: '${exclude_folder}'";
		else
			# skip if it is empty
			if [ ! -z "${exclude_folder}" ]; then
				# if it DOES NOT start with a / we assume free folder and add as is
				if [[ "${exclude_folder}" != /* ]]; then
					echo "${exclude_folder}" >> ${TMP_EXCLUDE_FILE};
					echo "+ [E] General exclude: '${exclude_folder}'";
				# if this is a glob, do a double check that the base folder actually exists (?)
				elif [[ "${exclude_folder}" =~ $REGEX_GLOB ]]; then
					# remove last element beyond the last /
					# if there is no path, just allow it (general rule)
					_exclude_folder=${exclude_folder%/*};
					if [ ! -d "${_exclude_folder}" ]; then
						echo "- [E] Exclude folder with glob '${exclude_folder}' does not exist or is not accessable";
					else
						echo "${exclude_folder}" >> ${TMP_EXCLUDE_FILE};
						echo "+ [E] Exclude folder with glob '${exclude_folder}'";
					fi;
				# do a warning for a possible invalid folder
				# but we do not a exclude if the data does not exist
				elif [ ! -d "${exclude_folder}" ] && [ ! -e "${exclude_folder}" ]; then
					echo "- [E] Exclude folder or file '${exclude_folder}' does not exist or is not accessable";
				else
					echo "${exclude_folder}" >> ${TMP_EXCLUDE_FILE};
					# if it is a folder, remove the last / or the symlink check will not work
					if [ -d "${exclude_folder}" ]; then
						_exclude_folder=${exclude_folder%/*};
					else
						_exclude_folder=${exclude_folder};
					fi;
					# warn if target is symlink folder
					if [ -h "${_exclude_folder}" ]; then
						echo "~ [I] Target '${exclude_folder}' is a symbolic link. No real data will be excluded from backup";
					else
						echo "+ [E] Exclude folder or file '${exclude_folder}'";
					fi;
				fi;
			fi;
		fi;
	done<"${BASE_FOLDER}${EXCLUDE_FILE}";
	COMMAND=${COMMAND}" --exclude-from ${TMP_EXCLUDE_FILE}";
fi;

# if info print info and then abort run
if [ ${INFO} -eq 1 ]; then
	echo "Script version: ${VERSION}";
	echo "borg info ${OPT_REMOTE} ${REPOSITORY}";
	echo "Run command: ";
	echo "${COMMAND}";
	# remove the temporary exclude file if it exists
	if [ -f "${TMP_EXCLUDE_FILE}" ]; then
		rm -f "${TMP_EXCLUDE_FILE}";
	fi;
	exit;
fi;

if [ $FOLDER_OK -eq 1 ]; then
	# if the repository is no there, call init to create it
	# if this is user@host, we need to use ssh command to check if the file is there
	# else a normal check is ok
	if [ ! -z "${TARGET_SERVER}" ]; then
		if [ ${DEBUG} -eq 1 ]; then
			echo "borg info ${OPT_REMOTE} ${REPOSITORY} 2>&1|grep \"Repository ID:\"";
		fi;
		# use borg info and check if it returns "Repository ID:" in the first line
		REPO_CHECK=$(borg info ${OPT_REMOTE} ${REPOSITORY} 2>&1|grep "Repository ID:");
		# this is currently a hack to work round the error code in borg info
		# this checks if REPO_CHECK holds this error message and then starts init
		regex="^Some part of the script failed with an error:";
		if [[ -z "${REPO_CHECK}" ]] || [[ "${REPO_CHECK}" =~ ${regex} ]]; then
			INIT_REPOSITORY=1;
		fi;
	elif [ ! -d "${REPOSITORY}" ]; then
		INIT_REPOSITORY=1;
	fi;
	if [ ${INIT_REPOSITORY} -eq 1 ]; then
		if [ ${DEBUG} -eq 1 ]; then
			echo "borg init ${OPT_REMOTE} -e ${ENCRYPTION} ${OPT_VERBOSE} ${REPOSITORY}";
		else
			# should trap and exit properly here
			borg init ${OPT_REMOTE} -e ${ENCRYPTION} ${OPT_VERBOSE} ${REPOSITORY};
		fi
	fi;
	# execute backup command
	if [ ${DEBUG} -eq 1 ]; then
		echo ${COMMAND};
		PRUNE_DEBUG="--dry-run";
	else
		# need to redirect std error to std out so all data is printed to the correct pipe
		${COMMAND} 2>&1 || echo "[!] Attic backup aborted.";
	fi;
	# remove the temporary exclude file if it exists
	if [ -f "${TMP_EXCLUDE_FILE}" ]; then
		rm -f "${TMP_EXCLUDE_FILE}";
	fi;
else
	echo "No folders where set for the backup";
	exit 1;
fi;

# clean up, always verbose
echo "Prune repository with keep daily: ${KEEP_DAYS}, weekly: ${KEEP_WEEKS}, monthly: ${KEEP_MONTHS}";
if [ ${DEBUG} -eq 1 ]; then
	echo "borg prune ${OPT_REMOTE} -v -s --list ${PRUNE_DEBUG} ${REPOSITORY} --keep-daily=${KEEP_DAYS} --keep-weekly=${KEEP_WEEKS} --keep-monthly=${KEEP_MONTHS}";
fi;
borg prune ${OPT_REMOTE} -v -s --list ${PRUNE_DEBUG} ${REPOSITORY} --keep-daily=${KEEP_DAYS} --keep-weekly=${KEEP_WEEKS} --keep-monthly=${KEEP_MONTHS} 2>&1 || echo "[!] Attic prune aborted";

## END
