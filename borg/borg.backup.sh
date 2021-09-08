#!/usr/bin/env bash

# Run -I first to initialize repository
# There are no automatic repository checks unless -C is given

# turn off all error aborting to not skip out on borg info call on unset repo
set -ETu #-e -o pipefail
trap cleanup SIGINT SIGTERM ERR

cleanup() {
	# script cleanup here
	echo "Some part of the script failed with an error: $? @LINE: $(caller)";
	# unset exported vars
	unset BORG_BASE_DIR BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK BORG_RELOCATED_REPO_ACCESS_IS_OK;
	# end trap
	trap - SIGINT SIGTERM ERR
}
# on exit unset any exported var
trap "unset BORG_BASE_DIR BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK BORG_RELOCATED_REPO_ACCESS_IS_OK" EXIT;

# set last edit date + time
VERSION="20210902-1118";
# default log folder if none are set in config or option
_LOG_FOLDER="/var/log/borg.backup/";
# log file name is set based on BACKUP_FILE, .log is added
LOG_FOLDER="";
# should be there on everything
TEMPDIR="/tmp/";
# creates borg backup based on the include/exclude files
# if base borg folder (backup files) does not exist, it will automatically init it
# base folder
BASE_FOLDER="/usr/local/scripts/borg/";
# include and exclude file
INCLUDE_FILE="borg.backup.include";
EXCLUDE_FILE="borg.backup.exclude";
SETTINGS_FILE="borg.backup.settings";
BACKUP_INIT_CHECK="borg.backup.init";
# debug/verbose
VERBOSE=0;
LIST=0;
DEBUG=0;
DRYRUN=0;
INFO=0;
CHECK=0;
INIT=0;
EXIT=0;
# flags, set to no to disable
_BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK="yes";
_BORG_RELOCATED_REPO_ACCESS_IS_OK="yes";
# other variables
TARGET_SERVER="";
REGEX="";
REGEX_COMMENT="^[\ \t]*#";
REGEX_GLOB='\*';
REGEX_NUMERIC="^[0-9]$";
PRUNE_DEBUG="";
INIT_REPOSITORY=0;
FOLDER_OK=0;
TMP_EXCLUDE_FILE="";
# opt flags
OPT_VERBOSE="";
OPT_PROGRESS="";
OPT_LIST="";
OPT_REMOTE="";
OPT_LOG_FOLDER="";
OPT_EXCLUDE="";
# config variables (will be overwritten from .settings file)
TARGET_USER="";
TARGET_HOST="";
TARGET_PORT="";
TARGET_BORG_PATH="";
TARGET_FOLDER="";
BACKUP_FILE="";
COMPRESSION="zlib";
COMPRESSION_LEVEL="";
ENCRYPTION="none";
FORCE_CHECK="false";
DATE=""; # to be deprecated
BACKUP_SET="";
# default keep 7 days, 4 weeks, 6 months
# if set 0, ignore
# note that for last/hourly it is needed to create a different
# BACKUP SET that includes hour and minute information
# IF BACKUP_SET is empty, this is automatically added
# general keep last, if only this is set only last n will be kept
KEEP_LAST=0;
KEEP_HOURS=0;
KEEP_DAYS=7;
KEEP_WEEKS=4;
KEEP_MONTHS=6;
KEEP_YEARS=1;
# in the format of nY|M|d|h|m|s
KEEP_WITHIN="";

function usage()
{
	cat <<- EOT
	Usage: ${0##/*/} [-c <config folder>] [-v] [-d]

	-c <config folder>: if this is not given, ${BASE_FOLDER} is used
	-L <log folder>: override config set and default log folder
	-C: check if repository exists, if not abort
	-E: exit after check
	-I: init repository (must be run first)
	-v: be verbose
	-i: print out only info
	-l: list files during backup
	-d: debug output all commands
	-n: only do dry run
	-h: this help page

	Version: ${VERSION}
	EOT
}

# set options
while getopts ":c:L:vldniCEIh" opt; do
	case "${opt}" in
		c|config)
			BASE_FOLDER=${OPTARG};
			;;
		L|log)
			OPT_LOG_FOLDER=${OPTARG};
			;;
		C|Check)
			# will check if repo is there and abort if not
			CHECK=1;
			;;
		E|Exit)
			# exit after check
			EXIT=1;
			;;
		I|Init)
			# will check if there is a repo and init it
			# previoous this was default
			CHECK=1;
			INIT=1;
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
		n|dryrun)
			DRYRUN=1;
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
[[ "${BASE_FOLDER}" != */ ]] && BASE_FOLDER=${BASE_FOLDER}"/";
# must have settings file there, if not, abort early
if [ ! -f "${BASE_FOLDER}${SETTINGS_FILE}" ]; then
	echo "No settings file could be found: ${BASE_FOLDER}${SETTINGS_FILE}";
	exit 1;
fi;
if [ ! -w "${BASE_FOLDER}" ]; then
	echo "Cannot write to BASE_FOLDER ${BASE_FOLDER}";
	exit 1;
fi;

# info -i && -C/-I cannot be run together
if [ ${CHECK} -eq 1 ] || [ ${INIT} -eq 1 ] && [ ${INFO} -eq 1 ]; then
	echo "Cannot have -i info option and -C check or -I initialized option at the same time";
	exit 1;
fi;

# verbose & progress
if [ ${VERBOSE} -eq 1 ]; then
	OPT_VERBOSE="-v";
	OPT_PROGRESS="-p";
fi;
# list files
if [ ${LIST} -eq 1 ]; then
	OPT_LIST="--list";
fi;

# read config file
. "${BASE_FOLDER}${SETTINGS_FILE}";

# check LOG_FOLDER, TARGET_BORG_PATH, TARGET_FOLDER must have no ~/ as start position
if [[ ${LOG_FOLDER} =~ ^~\/ ]]; then
	echo "LOG_FOLDER path cannot start with ~/. Path must be absolute: ${LOG_FOLDER}";
	exit 1;
fi;
if [[ ${TARGET_BORG_PATH} =~ ^~\/ ]]; then
	echo "TARGET_BORG_PATH path cannot start with ~/. Path must be absolute: ${TARGET_BORG_PATH}";
	exit 1;
fi;
if [[ ${TARGET_FOLDER} =~ ^~\/ ]]; then
	echo "TARGET_FOLDER path cannot start with ~/. Path must be absolute: ${TARGET_FOLDER}";
	exit 1;
fi;

# backup file must be set
if [ -z "${BACKUP_FILE}" ]; then
	echo "No BACKUP_FILE set";
	exit;
fi;
# backup file (folder) must end as .borg
# REGEX="\.borg$";
# if ! [[ "${BACKUP_FILE}" =~ ${REGEX} ]]; then
# 	echo "BACKUP_FILE ${BACKUP_FILE} must end with .borg";
# 	exit 1;
# fi;
# BACKUP FILE also cannot start with / or have / inside or start with ~
# valid file name check, alphanumeric, -,._ ...
if ! [[ "${BACKUP_FILE}" =~ ^[A-Za-z0-9,._-]+\.borg$ ]]; then
	echo "BACKUP_FILE ${BACKUP_FILE} can only contain A-Z a-z 0-9 , . _ - chracters and must end with .borg";
	exit 1;
fi;
# error if the repository file still has the default name
# This is just for old sets
REGEX="^some\-prefix\-";
if [[ "${BACKUP_FILE}" =~ ${REGEX} ]]; then
	echo "[DEPRECATED] The repository name still has the default prefix: ${BACKUP_FILE}";
	exit 1;
fi;

# log file set and check
# option folder overrides all other folders
if [ ! -z "${OPT_LOG_FOLDER}" ]; then
	LOG_FOLDER="${OPT_LOG_FOLDER}";
fi;
# if empty folder set to default folder
if [ -z "${LOG_FOLDER}" ]; then
	LOG_FOLDER="${_LOG_FOLDER}";
fi;
# if folder does not exists create it
if [ ! -d "${LOG_FOLDER}" ]; then
	mkdir "${LOG_FOLDER}";
fi;
# set the output log folder
# LOG=$(printf "%q" "${LOG_FOLDER}/${BACKUP_FILE}.log");
LOG="${LOG_FOLDER}/${BACKUP_FILE}.log";
# fail if not writeable to folder or file
if [[ -f "${LOG}" && ! -w "${LOG}" ]] || [[ ! -f "${LOG}" && ! -w "${LOG_FOLDER}" ]]; then
	echo "Log folder or log file is not writeable: ${LOG}";
	exit 1;
fi;
# start logging from here
exec &> >(tee -a "${LOG}");
echo "=== [START : $(date +'%F %T')] ===========================================>";
# show info for version always
echo "Script version: ${VERSION}";
# show base folder always
echo "Base folder   : ${BASE_FOLDER}";

# if ENCRYPTION is empty or not in the valid list fall back to none
if [ -z "${ENCRYPTION}" ]; then
	ENCRYPTION="none";
#else
	# TODO check for invalid encryption string
fi;

# if force check is true set CHECK to 1unless INFO is 1
# Needs bash 4.0 at lesat for this
if [ "${FORCE_CHECK,,}" = "true" ] && [ ${INFO} -eq 0 ]; then
	CHECK=1;
	if [ ${DEBUG} -eq 1 ]; then
		echo "Force repository check";
	fi;
fi;

# remote borg path
if [ ! -z "${TARGET_BORG_PATH}" ]; then
	if [[ "${TARGET_BORG_PATH}" =~ \ |\' ]]; then
		echo "Space found in ${TARGET_BORG_PATH}. Aborting";
		echo "There are issues with passing on paths with spaces"
		echo "as parameters"
		exit;
	fi;
	OPT_REMOTE="--remote-path="$(printf "%q" "${TARGET_BORG_PATH}");
fi;

if [ -z "${TARGET_FOLDER}" ]; then
	echo "[! $(date +'%F %T')] No target folder has been set yet";
	exit 1;
else
	# There are big issues with TARGET FOLDERS with spaces
	# we should abort anything with this
	if [[ "${TARGET_FOLDER}" =~ \ |\' ]]; then
		echo "Space found in ${TARGET_FOLDER}. Aborting";
		echo "There is some problem with passing paths with spaces as";
		echo "repository base folder"
		exit;
	fi;

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
	TARGET_SERVER="ssh://${TARGET_USER}@${TARGET_HOST}:${TARGET_PORT}/";
# host/port
elif [ ! -z "${TARGET_HOST}" ] && [ ! -z "${TARGET_PORT}" ]; then
	TARGET_SERVER="ssh://${TARGET_HOST}:${TARGET_PORT}/";
# user/host
elif [ ! -z "${TARGET_USER}" ] && [ ! -z "${TARGET_HOST}" ]; then
	TARGET_SERVER="${TARGET_USER}@${TARGET_HOST}:";
# host
elif [ ! -z "${TARGET_HOST}" ]; then
	TARGET_SERVER="${TARGET_HOST}:";
fi;
# we dont allow special characters, so we don't need to special escape it
REPOSITORY="${TARGET_SERVER}${TARGET_FOLDER}${BACKUP_FILE}";

if [ ! -f "${BASE_FOLDER}${INCLUDE_FILE}" ]; then
	echo "[! $(date +'%F %T')] The include folder file ${INCLUDE_FILE} is missing";
	exit 1;
fi;

# check compression if given is valid and check compression level is valid if given
if [ ! -z "${COMPRESSION}" ]; then
	# valid compress
	if [ "${COMPRESSION}" = "lz4" ] || [ "${COMPRESSION}" = "zlib" ] || [ "${COMPRESSION}" = "lzma" ]; then
		OPT_COMPRESSION="-C=${COMPRESSION}";
		# if COMPRESSION_LEVEL, check it is a valid regex
		# ignore it if this is lz4
		if [ ! -z "${COMPRESSION_LEVEL}" ] && [ "${COMPRESSION}" != "lz4" ]; then
			if ! [[ "${COMPRESSION_LEVEL}" =~ ${REGEX_NUMERIC} ]]; then
				echo "[! $(date +'%F %T')] Compression level needs to be a value from 0 to 9: ${COMPRESSION_LEVEL}";
				exit 1;
			else
				OPT_COMPRESSION=${OPT_COMPRESSION}","${COMPRESSION_LEVEL};
			fi;
		fi;
	else
		echo "[! $(date +'%F %T')] Compress setting need to be lz4, zlib or lzma. Or empty for no compression: ${COMPRESSION}";
		exit 1;
	fi;
fi;

# home folder, needs to be set if there is eg a HOME=/ in the crontab
if [ ! -w "${HOME}" ] || [ "${HOME}" = '/' ]; then
	HOME=$(eval echo "$(whoami)");
fi;

# build options and info string,
# also flag BACKUP_SET check if hourly is set
KEEP_OPTIONS=();
KEEP_INFO="";
BACKUP_SET_CHECK=0;
if [ ${KEEP_LAST} -gt 0 ]; then
	KEEP_OPTIONS+=("--keep-last=${KEEP_LAST}");
	KEEP_INFO="${KEEP_INFO}, last: ${KEEP_LAST}";
fi;
if [ ${KEEP_HOURS} -gt 0 ]; then
	KEEP_OPTIONS+=("--keep-hourly=${KEEP_HOURS}");
	KEEP_INFO="${KEEP_INFO}, hourly: ${KEEP_HOURS}";
	BACKUP_SET_CHECK=1;
fi;
if [ ${KEEP_DAYS} -gt 0 ]; then
	KEEP_OPTIONS+=("--keep-daily=${KEEP_DAYS}");
	KEEP_INFO="${KEEP_INFO}, daily: ${KEEP_DAYS}";
fi;
if [ ${KEEP_WEEKS} -gt 0 ]; then
	KEEP_OPTIONS+=("--keep-weekly=${KEEP_WEEKS}");
	KEEP_INFO="${KEEP_INFO}, weekly: ${KEEP_WEEKS}";
fi;
if [ ${KEEP_MONTHS} -gt 0 ]; then
	KEEP_OPTIONS+=("--keep-monthly=${KEEP_MONTHS}");
	KEEP_INFO="${KEEP_INFO}, monthly: ${KEEP_MONTHS}";
fi;
if [ ${KEEP_YEARS} -gt 0 ]; then
	KEEP_OPTIONS+=("--keep-yearly=${KEEP_YEARS}");
	KEEP_INFO="${KEEP_INFO}, yearly: ${KEEP_YEARS}";
fi;
if [ ! -z "${KEEP_WITHIN}" ]; then
	# check for invalid string. can only be number + H|d|w|m|y
	if [[ "${KEEP_WITHIN}" =~ ^[0-9]+[Hdwmy]{1}$ ]]; then
		KEEP_OPTIONS+=("--keep-within=${KEEP_WITHIN}");
		KEEP_INFO="${KEEP_INFO}, within: ${KEEP_WITHIN}";
		if [[ "${KEEP_WITHIN}" == *"H"* ]]; then
			BACKUP_SET_CHECK=1;
		fi;
	else
		echo "[! $(date +'%F %T')] KEEP_WITHIN has invalid string.";
		exit 1;
	fi;
fi;
# abort if KEEP_OPTIONS is empty
if [ -z "${KEEP_OPTIONS}" ]; then
	echo "[! $(date +'%F %T')] It seems no KEEP_* entries where set in a valid format.";
	exit 1;
fi;
# set BACKUP_SET if empty, check for for DATE is set
if [ -z "${BACKUP_SET}" ]; then
	# DATE is deprecated and will be removed
	if [ ! -z "${DATE}" ]; then
		echo "[!] DEPRECATED: The use of DATE variable is deprecated, use BACKUP_SET instead";
		BACKUP_SET="${DATE}";
	else
		# default
		BACKUP_SET="{now:%Y-%m-%d}";
	fi;
fi;
# backup set check, and there is no hour entry (%H) in the archive string
# we add T%H:%M:%S in this case, before the last }
if [ ${BACKUP_SET_CHECK} -eq 1 ] && [[ "${BACKUP_SET}" != *"%H"* ]]; then
	BACKUP_SET=$(echo "${BACKUP_SET}" | sed -e "s/}/T%H:%M:%S}/");
fi;

# for folders list split set to "#" and keep the old setting as is
_IFS=${IFS};
IFS="#";
# general borg settings
# set base path to config directory to keep cache/config separated
export BORG_BASE_DIR="${BASE_FOLDER}";
# ignore non encrypted access
export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=${_BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK};
# ignore moved repo access
export BORG_RELOCATED_REPO_ACCESS_IS_OK=${_BORG_RELOCATED_REPO_ACCESS_IS_OK};
# and for debug print that tout
if [ ${DEBUG} -eq 1 ]; then
	echo "export BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK=${_BORG_UNKNOWN_UNENCRYPTED_REPO_ACCESS_IS_OK};";
	echo "export BORG_RELOCATED_REPO_ACCESS_IS_OK=${_BORG_RELOCATED_REPO_ACCESS_IS_OK};";
	echo "export BORG_BASE_DIR=\"${BASE_FOLDER}\";";
fi;
# prepare debug commands only
COMMAND_EXPORT="export BORG_BASE_DIR=\"${BASE_FOLDER}\";"
COMMAND_INFO="${COMMAND_EXPORT}borg info ${OPT_REMOTE} ${REPOSITORY}";
# if the is not there, call init to create it
# if this is user@host, we need to use ssh command to check if the file is there
# else a normal check is ok
# unless explicit given, check is skipped
if [ ${CHECK} -eq 1 ] || [ ${INIT} -eq 1 ]; then
	echo "--- [CHECK : $(date +'%F %T')] ------------------------------------------->";
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
	# if check but no init and repo is there but init file is missing set it
	if [ ${CHECK} -eq 1 ] && [ ${INIT} -eq 0 ] && [ ${INIT_REPOSITORY} -eq 0 ] &&
		[ ! -f "${BASE_FOLDER}${BACKUP_INIT_CHECK}" ]; then
		# write init file
		echo "[!] Add missing init check file";
		echo "$(date +%s)" > "${BASE_FOLDER}${BACKUP_INIT_CHECK}";
	fi;
	# end if checked but repository is not here
	if [ ${CHECK} -eq 1 ] && [ ${INIT} -eq 0 ] && [ ${INIT_REPOSITORY} -eq 1 ]; then
		echo "[! $(date +'%F %T')] No repository. Please run with -I flag to initialze repository";
		exit 1;
	fi;
	if [ ${EXIT} -eq 1 ] && [ ${CHECK} -eq 1 ] && [ ${INIT} -eq 0 ]; then
		echo "Repository exists";
		echo "For more information run:"
		echo "${COMMAND_INFO}";
		echo "=== [END  : $(date +'%F %T')] ============================================>";
		exit;
	fi;
fi;
if [ ${INIT} -eq 1 ] && [ ${INIT_REPOSITORY} -eq 1 ]; then
	echo "--- [INIT  : $(date +'%F %T')] ------------------------------------------->";
	if [ ${DEBUG} -eq 1 ]; then
		echo "borg init ${OPT_REMOTE} -e ${ENCRYPTION} ${OPT_VERBOSE} ${REPOSITORY}";
	elif [ ${DRYRUN} -eq 0 ]; then
		# should trap and exit properly here
		borg init ${OPT_REMOTE} -e ${ENCRYPTION} ${OPT_VERBOSE} ${REPOSITORY};
		# write init file
		echo "$(date +%s)" > "${BASE_FOLDER}${BACKUP_INIT_CHECK}";
		echo "Repository initialized";
		echo "For more information run:"
		echo "${COMMAND_INFO}";
	fi
	echo "=== [END  : $(date +'%F %T')] ============================================>";
	# exit after init
	exit;
elif [ ${INIT} -eq 1 ] && [ ${INIT_REPOSITORY} -eq 0 ]; then
	echo "[! $(date +'%F %T')] Repository already initialized";
	echo "For more information run:"
	echo "${COMMAND_INFO}";
	exit 1;
fi;

# check for init file
if [ ! -f "${BASE_FOLDER}${BACKUP_INIT_CHECK}" ]; then
	echo "[! $(date +'%F %T')] It seems the repository has never been initialized."
	echo "Please run -I to initialize or if already initialzed run with -C for init update."
	exit 1;
fi;

# folders to backup
FOLDERS=();
# this if for debug output with quoted folders
FOLDERS_Q=();
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
					FOLDERS_Q+=($(printf "%q" "$(echo "${include_folder}" | sed 's/\*/_STARGLOB_/g')" | sed 's/_STARGLOB_/\*/g'));
					FOLDERS+=("${include_folder}");
				elif [ ! -d "${_include_folder}" ]; then
					echo "- [I] Backup folder with glob '${include_folder}' does not exist or is not accessable";
				else
					FOLDER_OK=1;
					echo "+ [I] Backup folder with glob '${include_folder}'";
					# we need glob fix
					FOLDERS_Q+=($(printf "%q" "$(echo "${include_folder}" | sed 's/\*/_STARGLOB_/g')" | sed 's/_STARGLOB_/\*/g'));
					FOLDERS+=("${include_folder}");
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
				FOLDERS_Q+=($(printf "%q" "${include_folder}"));
				FOLDERS+=("${include_folder}");
			fi;
		fi;
	fi;
done<"${BASE_FOLDER}${INCLUDE_FILE}";

# exclude list
if [ -f "${BASE_FOLDER}${EXCLUDE_FILE}" ]; then
	# check that the folders in that exclude file are actually valid,
	# remove non valid ones and warn
	#TMP_EXCLUDE_FILE=$(mktemp --tmpdir ${EXCLUDE_FILE}.XXXXXXXX); # non mac
	TMP_EXCLUDE_FILE=$(mktemp "${TEMPDIR}${EXCLUDE_FILE}".XXXXXXXX);
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
	# avoid blank file add by checking if the tmp file has a size >0
	if [ -s "${BASE_FOLDER}${EXCLUDE_FILE}" ]; then
		OPT_EXCLUDE="--exclude-from=${TMP_EXCLUDE_FILE}";
	fi;
fi;
# add the repository set before we add the folders
# base command
COMMAND="borg create -v ${OPT_LIST} ${OPT_PROGRESS} ${OPT_COMPRESSION} -s ${OPT_REMOTE} ${OPT_EXCLUDE} ";
# add repoistory, after that the folders will be added on call
COMMAND=${COMMAND}${REPOSITORY}::${BACKUP_SET};
# if info print info and then abort run
if [ ${INFO} -eq 1 ]; then
	echo "--- [INFO  : $(date +'%F %T')] ------------------------------------------->";
	# show command on debug or dry run
	if [ ${DEBUG} -eq 1 ] || [ ${DRYRUN} -eq 1 ]; then
		echo "export BORG_BASE_DIR=\"${BASE_FOLDER}\";borg info ${OPT_REMOTE} ${REPOSITORY}";
	fi;
	# run info command if not a dry drun
	if [ ${DRYRUN} -eq 0 ]; then
		borg info ${OPT_REMOTE} ${REPOSITORY};
	fi;
	if [ $FOLDER_OK -eq 1 ]; then
		echo "--- [Run command]:";
		#IFS="#";
		echo "export BORG_BASE_DIR=\"${BASE_FOLDER}\";${COMMAND} "${FOLDERS_Q[*]};
	else
		echo "[!] No folders where set for the backup";
	fi;
	# remove the temporary exclude file if it exists
	if [ -f "${TMP_EXCLUDE_FILE}" ]; then
		rm -f "${TMP_EXCLUDE_FILE}";
	fi;
	echo "=== [END  : $(date +'%F %T')] ============================================>";
	exit;
fi;

if [ $FOLDER_OK -eq 1 ]; then
	echo "--- [BACKUP: $(date +'%F %T')] ------------------------------------------->";
	# show command
	if [ ${DEBUG} -eq 1 ]; then
		echo $(echo ${COMMAND} | sed -e 's/[ ][ ]*/ /g') ${FOLDERS_Q[*]};
	fi;
	# execute backup command
	if [ ${DRYRUN} -eq 1 ]; then
		PRUNE_DEBUG="--dry-run";
	else
		# need to redirect std error to std out so all data is printed to the correct pipe
		# for the IFS="#" to work we need to replace options spaces with exactly ONE #
		$(echo "${COMMAND}" | sed -e 's/[ ][ ]*/#/g') ${FOLDERS[*]} 2>&1 || echo "[!] Attic backup aborted.";
	fi;
	# remove the temporary exclude file if it exists
	if [ -f "${TMP_EXCLUDE_FILE}" ]; then
		rm -f "${TMP_EXCLUDE_FILE}";
	fi;
else
	echo "[! $(date +'%F %T')] No folders where set for the backup";
	exit 1;
fi;

# clean up, always verbose
echo "--- [PRUNE : $(date +'%F %T')] ------------------------------------------->";
# build command
COMMAND="borg prune ${OPT_REMOTE} -v -s --list ${PRUNE_DEBUG} ${KEEP_OPTIONS[*]} ${REPOSITORY}";
echo "Prune repository with keep${KEEP_INFO:1}";
if [ ${DEBUG} -eq 1 ]; then
	echo "${COMMAND//#/ }" | sed -e 's/[ ][ ]*/ /g';
fi;
# for the IFS="#" to work we need to replace options spaces with exactly ONE #
$(echo "${COMMAND}" | sed -e 's/[ ][ ]*/#/g') 2>&1 || echo "[!] Attic prune aborted";

echo "=== [END  : $(date +'%F %T')] ============================================>";

## END
