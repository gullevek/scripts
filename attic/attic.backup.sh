#!/bin/bash

set -e -u -o pipefail

# creates attic backup based on the include/exclude files
# if base attic folder (backup files) does not exist, it will automatically init it

# base folder
BASE_FOLDER="/usr/local/scripts/attic/";
# include and exclude file
INCLUDE_FILE="attic.backup.include";
EXCLUDE_FILE="attic.backup.exclude";
SETTINGS_FILE="attic.backup.settings";
# debug/verbose
VERBOSE=0;
DEBUG=0;
# other variables
TARGET_SERVER='';
REGEX='';
REGEX_COMMENT="^[\ \t]*#";
REGEX_GLOB='\*';
PRUNE_DEBUG='';
INIT_REPOSITORY=0;
FOLDER_OK=0;
TMP_EXCLUDE_FILE='';

function usage()
{
	cat <<- EOT
	Usage: ${0##/*/} [-c <config folder>] [-v] [-d]

	-c <config folder>: if this is not given, ${BASE_FOLDER} is used
	-v: be verbose
	-d: only do dry run
	EOT
}

# set options
while getopts ":c:vdh" opt
do
	case "${opt}" in
		c|config)
			BASE_FOLDER=${OPTARG};
			;;
		v|verbose)
			VERBOSE=1;
			;;
		d|debug)
			DEBUG=1;
			;;
		h|help)
			usage;
			exit 0;
			;;
		\?)
			echo -e "\n Option does not exist: ${OPTARG}\n";
			usage;
			exit 1;
			;;
	esac;
done;

if [ ! -f "${BASE_FOLDER}${SETTINGS_FILE}" ];
then
	echo "No settings file could be found: ${BASE_FOLDER}${SETTINGS_FILE}";
	exit 0;
fi;

if [ ${VERBOSE} -eq 1 ];
then
	OPT_VERBOSE="-v";
else
	OPT_VERBOSE='';
fi;

. "${BASE_FOLDER}${SETTINGS_FILE}";

if [ -z "${TARGET_FOLDER}" ];
then
	echo "No target folder has been set yet";
	exit 0;
else
	# add safety / in case it is missing
	TARGET_FOLDER=${TARGET_FOLDER}"/";
fi;

# if we have user/host then we build the ssh command
TARGET_SERVER='';
if [ ! -z "${TARGET_USER}" ] && [ ! -z "${TARGET_HOST}" ];
then
	TARGET_SERVER=${TARGET_USER}"@"${TARGET_HOST}":";
fi;
REPOSITORY=${TARGET_SERVER}${TARGET_FOLDER}${BACKUP_FILE};

if [ ! -f "${BASE_FOLDER}${INCLUDE_FILE}" ];
then
	echo "The include folder file ${INCLUDE_FILE} is missing";
	exit 0;
fi;

# error if the repository file still has the default name
REGEX="^some\-prefix\-";
if [[ "${BACKUP_FILE}" =~ ${REGEX} ]];
then
	echo "The repository name still has the default prefix: ${BACKUP_FILE}";
	exit 0;
fi;

# home folder, needs to be set if there is eg a HOME=/ in the crontab
if [ ! -w "${HOME}" ] || [ "${HOME}" = '/' ];
then
	HOME=$(eval echo "$(whoami)");
fi;

# if the repository is no there, call init to create it
# if this is user@host, we need to use ssh command to check if the file is there
# else a normal check is ok
if [ ! -z "${TARGET_SERVER}" ];
then
	# remove trailing : for this
	TARGET_SERVER=${TARGET_SERVER/:};
	# use ssh command to check remote existense
	if [ $(ssh "${TARGET_SERVER}" "if [ -d \"${TARGET_FOLDER}${BACKUP_FILE}\" ]; then echo 1; else echo 0; fi;") -eq 0 ];
	then
		INIT_REPOSITORY=1;
	fi;
elif [ ! -d "${REPOSITORY}" ];
then
	INIT_REPOSITORY=1;
fi;
if [ ${INIT_REPOSITORY} -eq 1 ];
then
	if [ ${DEBUG} -eq 1 ];
	then
		echo "attic init ${OPT_VERBOSE} ${REPOSITORY}";
	else
		attic init ${OPT_VERBOSE} ${REPOSITORY}; # should trap and exit properly here
	fi
fi;

# base command
COMMAND="attic create ${OPT_VERBOSE} -s ${REPOSITORY}::${DATE}";
# include list
while read include_folder;
do
	# strip any leading spaces from that folder
	include_folder=$(echo "${include_folder}" | sed -e 's/^[ \t]*//');
	# check that those folders exist, warn on error, but do not exit unless there are no valid folders at all
	# skip folders that are with # in front (comment)
	if [[ "${include_folder}" =~ ${REGEX_COMMENT} ]];
	then
		echo "- [I] Do not include folder '${include_folder}'";
	else
		# skip if it is empty
		if [ ! -z "${include_folder}" ];
		then
			# if this is a glob, do a double check that the base folder actually exists (?)
			if [[ "${include_folder}" =~ $REGEX_GLOB ]];
			then
				# remove last element beyond the last /
				# if there is no path, just allow it (general rule)
				_include_folder=${include_folder%/*};
				if [ ! -d "${_include_folder}" ];
				then
					echo "- [I] Backup folder with glob '${include_folder}' does not exist or is not accessable";
				else
					FOLDER_OK=1;
					COMMAND=${COMMAND}" ${include_folder}";
					echo "+ [I] Backup folder with glob '${include_folder}'";
				fi;
			# normal folder
			elif [ ! -d "${include_folder}" ] && [ ! -e "${include_folder}" ];
			then
				echo "- [I] Backup folder or file '${include_folder}' does not exist or is not accessable";
			else
				FOLDER_OK=1;
				COMMAND=${COMMAND}" ${include_folder}";
				# if it is a folder, remove the last / or the symlink check will not work
				if [ -d "${include_folder}" ];
				then
					_include_folder=${include_folder%/*};
				else
					_include_folder=${include_folder};
				fi;
				# Warn if symlink & folder -> only smylink will be backed up
				if [ -h "${_include_folder}" ];
				then
					echo "~ [I] Target '${include_folder}' is a symbolic link. No real data will be backed up";
				else
					echo "+ [I] Backup folder or file '${include_folder}'";
				fi;
			fi;
		fi;
	fi;
done<"${BASE_FOLDER}${INCLUDE_FILE}";
# exclude list
if [ -f "${BASE_FOLDER}${EXCLUDE_FILE}" ];
then
	# check that the folders in that exclude file are actually valid, remove non valid ones and warn
	TMP_EXCLUDE_FILE=$(mktemp --tmpdir ${EXCLUDE_FILE}.XXXXXXXX);
	while read exclude_folder;
	do
		# strip any leading spaces from that folder
		exclude_folder=$(echo "${exclude_folder}" | sed -e 's/^[ \t]*//');
		# folder or any type of file is ok
		# because of glob files etc, exclude only comments (# start)
		if [[ "${exclude_folder}" =~ ${REGEX_COMMENT} ]];
		then
			echo "- [E] Exclude folder '${exclude_folder}'";
		else
			# skip if it is empty
			if [ ! -z "${exclude_folder}" ];
			then
				# if this is a glob, do a double check that the base folder actually exists (?)
				if [[ "${exclude_folder}" =~ $REGEX_GLOB ]];
				then
					# remove last element beyond the last /
					# if there is no path, just allow it (general rule)
					_exclude_folder=${exclude_folder%/*};
					if [ ! -d "${_exclude_folder}" ];
					then
						echo "- [E] Exclude folder with glob '${exclude_folder}' does not exist or is not accessable";
					else
						echo "${exclude_folder}" >> ${TMP_EXCLUDE_FILE};
						echo "+ [E] Exclude folder with glob '${exclude_folder}'";
					fi;
				# do a warning for a possible invalid folder
				# but we do not a exclude if the data does not exist
				elif [ ! -d "${exclude_folder}" ] && [ ! -e "${exclude_folder}" ];
				then
					echo "- [E] Exclude folder or file '${exclude_folder}' does not exist or is not accessable";
				else
					echo "${exclude_folder}" >> ${TMP_EXCLUDE_FILE};
					# if it is a folder, remove the last / or the symlink check will not work
					if [ -d "${exclude_folder}" ];
					then
						_exclude_folder=${exclude_folder%/*};
					else
						_exclude_folder=${exclude_folder};
					fi;
					# warn if target is symlink folder
					if [ -h "${_exclude_folder}" ];
					then
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

if [ $FOLDER_OK -eq 1 ];
then
	# execute backup command
	if [ ${DEBUG} -eq 1 ];
	then
		echo ${COMMAND};
		PRUNE_DEBUG="--dry-run";
	else
		${COMMAND} || echo "[!] Attic backup aborted.";
	fi;
	# remove the temporary exclude file if it exists
	if [ -f "${TMP_EXCLUDE_FILE}" ];
	then
		rm -f "${TMP_EXCLUDE_FILE}";
	fi;
else
	echo "No folders where set for the backup";
	exit 0;
fi;

# clean up, always verbose
echo "Prune repository with keep daily: ${KEEP_DAYS}, weekly: ${KEEP_WEEKS}, monthly: ${KEEP_MONTHS}";
if [ ${DEBUG} -eq 1 ];
then
	echo "attic prune -v ${PRUNE_DEBUG} ${REPOSITORY} --keep-daily=${KEEP_DAYS} --keep-weekly=${KEEP_WEEKS} --keep-monthly=${KEEP_MONTHS}";
fi;
attic prune -v ${PRUNE_DEBUG} ${REPOSITORY} --keep-daily=${KEEP_DAYS} --keep-weekly=${KEEP_WEEKS} --keep-monthly=${KEEP_MONTHS} || echo "[!] Attic prune aborted";

## END
