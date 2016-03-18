#!/bin/bash

# AUTHOR: Clemens Schwaighofer
# DATE: 2013/12/13
# DESC: rsync data from one folder to another folder, or to a remote host. Write detailed log of what has been synced plus a control log of start and end time

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} [-d] [-v [-v]] [-x] [-c] [-n] [-e <ssh string options>] [-s <source folder>] [-t <target folder>] [-l <log file>] [-r <run folder>] [-u <exclude file> [-u ...]]

	-d: debug output, shows full rsync command
	-v: verbose output, for use outside scripted runs, Add a second -v to get progress output
	-n: dry run
	-x: add -X and -A rsync flag for extended attributes. Can oops certain kernels.
	-l: log file name, if not set default name is used
	-r: override run folder /var/run/
	-s: source folder, must exist
	-t: target folder, must exist
	-c: do check if source or target folder exist
	-e: turns on -e "ssh", if something is given it assumes it is the pem key and creates -e "ssh -i <key file>". turns off folder checking
	-u: exclude file or folder, can be given multiple times
	EOT
}

# METHOD: convert_time
# PARAMS: timestamp in seconds or with milliseconds (nnnn.nnnn)
# RETURN: formated string with human readable time (d/h/m/s)
# CALL  : var=`convert_time $timestamp`;
# DESC  : converts a timestamp or a timestamp with float milliseconds to a human readable format
#         output is in days/hours/minutes/seconds
function convert_time
{
	# check if we have bc command
	if [ -f "/usr/bin/bc" ];
	then
		BC_OK=1;
	else
		BC_OK=0;
	fi;
	# input time stamp
	timestamp=${1};
	# round to four digits for ms
	timestamp=$(printf "%1.4f" ${timestamp});
	# get the ms part and remove any leading 0
	ms=$(echo ${timestamp} | cut -d "." -f 2 | sed -e 's/^0*//');
	timestamp=$(echo ${timestamp} | cut -d "." -f 1);
	timegroups=(86400 3600 60 1); # day, hour, min, sec
	timenames=("d" "h" "m" "s"); # day, hour, min, sec
	output=( );
	time_string=;
	for timeslice in ${timegroups[@]};
	do
		# floor for the division, push to output
		if [ ${BC_OK} -eq 1 ];
		then
			output[${#output[*]}]=$(echo "${timestamp}/${timeslice}" | bc);
			timestamp=$(echo "${timestamp}%${timeslice}" | bc);
		else
			output[${#output[*]}]=$(awk "BEGIN {printf \"%d\", ${timestamp}/${timeslice}}");
			timestamp=$(awk "BEGIN {printf \"%d\", ${timestamp}%${timeslice}}");
		fi;
	done;

	for ((i=0; i<${#output[@]}; i++));
	do
		if [ ${output[${i}]} -gt 0 ] || [ ! -z "$time_string" ];
		then
			if [ ! -z "${time_string}" ];
			then
				time_string=${time_string}" ";
			fi;
			time_string=${time_string}${output[${i}]}${timenames[${i}]};
		fi;
	done;
	if [ ! -z ${ms} ];
	then
		if [ ${ms} -gt 0 ];
		then
			time_string=${time_string}" "${ms}"ms";
		fi;
	fi;
	# just in case the time is 0
	if [ -z "${time_string}" ];
	then
		time_string="0s";
	fi;
	echo -n "${time_string}";
}

# if no verbose flag is set run, no output
VERBOSE='--partial';
DRY_RUN='';
EXT_ATTRS='';
LOG_FILE="/var/log/rsync/rsync_backup.log";
_LOG_FILE='';
LOG_FILE_CONTROL="/var/log/rsync/rsync_backup.control.log";
_LOG_FILE_CONTROL='';
LOG_FILE_TRANSFER="/var/log/rsync/rsync_backup.transfer.log";
_LOG_FILE_TRANSFER='';
SSH_COMMAND_ON='';
SSH_COMMAND_LINE='';
CHECK=1;
EXCLUDE=();
RUN_FOLDER='/var/run/';
_RUN_FOLDER='';
DEBUG=0;

# set options
while getopts ":dvncxs:t:l:e:r:u:h" opt
do
	case ${opt} in
		d|debug)
			DEBUG=1;
			;;
		v|verbose)
			# verbose flag shows output
			# check level, if --partial only add -vi, if --partial -vi change to -P -vi
			if [ "${VERBOSE}" = "--partial" ];
			then
				VERBOSE='--partial -vi';
			elif [ "${VERBOSE}" = "--partial -vi" ];
			then
				VERBOSE='-P -vi';
			fi;
			;;
		n|dry-run)
			DRY_RUN='-n';
			;;
		x|extattr)
			EXT_ATTRS='-XA';
			;;
		c|check)
			CHECK=0;
			;;
		s|source)
			if [ -z "${SOURCE}" ];
			then
				SOURCE="${OPTARG}";
			fi;
			;;
		t|target)
			if [ -z "${TARGET}" ];
			then
				TARGET="${OPTARG}";
			fi;
			;;
		l|logfile)
			if [ -z "${_LOG_FILE}" ];
			then
				_LOG_FILE="${OPTARG}";
			fi;
			;;
		r|runfolder)
			if [ -z "${_RUN_FOLDER}" ];
			then
				_RUN_FOLDER="${OPTARG}";
				RUN_FOLDER="${_RUN_FOLDER}";
			fi;
			;;
		e|ssh)
			SSH_COMMAND_ON='-e ';
			if [ ! -z "${OPTARG}" ];
			then
				SSH_COMMAND_LINE="ssh -i ${OPTARG}";
			else
				SSH_COMMAND_LINE="ssh";
			fi;
			CHECK=0;
			;;
		u|exclude)
			EXCLUDE+=("${OPTARG}");
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

# use new log file path, if the folder is ok and writeable
if [ ! -z "${_LOG_FILE}" ];
then
	# check if this is valid writeable file
	touch "${_LOG_FILE}";
	if [ -f "${_LOG_FILE}" ];
	then
		LOG_FILE=${_LOG_FILE};
		# set new control log file in the given folder
		LOG_FILE_CONTROL=$(dirname ${LOG_FILE})"/rsync_backup.control.log";
		# set new transfer log file based on main log ilfe
		LOG_FILE_TRANSFER=$(dirname ${LOG_FILE})"/"$(basename ${LOG_FILE})".transfer.log";
	else
		echo "Log file '${_LOG_FILE}' is not writeable, fallback to '${LOG_FILE}'";
	fi;
fi;

if [ ${CHECK} -eq 1 ];
then
	if [[ ! -d "${SOURCE}" || ! -d "${TARGET}" ]];
	then
		echo "Give source and target path.";
		if [ ! -z "${SOURCE}" ] && [ ! -d "${SOURCE]}" ];
		then
			echo "Source folder not found: ${SOURCE}";
		fi;
		if [ ! -z "${TARGET}" ] && [ ! -d "${TARGET}" ];
		then
			echo "Target folder not found: ${TARGET}";
		fi;
		exit;
	fi;
else
	if [[ -z "${SOURCE}" || -z "${TARGET}" ]];
	then
		echo "Give source and target path.";
		exit;
	fi;
fi;

LOG_CONTROL="tee -a ${LOG_FILE_CONTROL}";
LOG_TRANSFER="tee -a ${LOG_FILE_TRANSFER}";
# run lock file, based on source target folder names (/ transformed to _)
if [ -w "${RUN_FOLDER}" ];
then
	run_file=${RUN_FOLDER}"rsync-script_"$(echo "${SOURCE}" | sed -e 's/[\/@\*:]/_/g')'_'$(echo "${TARGET}" | sed -e 's/[\/@\*:]/_/g')'.run';
	exists=0;
	if [ -f "${run_file}" ];
	then
		# check if the pid in the run file exists, if yes, abort
		pid=$(cat "${run_file}");
		while read _ps;
		do
			if [ ${_ps} -eq ${pid} ];
			then
				exists=1;
				echo "Rsync script already running with pid ${pid}";
				break;
			fi;
		done < <(ps xu|sed 1d|awk '{print $2}');
		# not exited, so not running, clean up pid
		if [ ${exists} -eq 0 ];
		then
			rm -f "${run_file}";
		else
			exit 0;
		fi;
	fi;
	echo $$ > "${run_file}";
fi;

# a: archive
# z: compress
# X: extended attributes
# A: ACL
# v: verbose
# hh: human readable in K/M/G/...

# remove -X for nfs sync, it screws up and oops (kernel 3.14-2)
# remove -A for nfs sync, has problems with ACL data

# build the command
cmd=(rsync -az --stats --delete --exclude="lost+found" -hh --log-file="${LOG_FILE}" --log-file-format="%o %i %f%L %l (%b)" ${VERBOSE} ${DRY_RUN} ${EXT_ATTRS});
#basic_params='-azvi --stats --delete --exclude="lost+found" -hh';
# add exclude parameters
for exclude in "${EXCLUDE[@]}";
do
	cmd=("${cmd[@]}" --exclude="${exclude}");
done;
# add SSH command parameters
if [ ! -z "${SSH_COMMAND_ON}" ];
then
	cmd=("${cmd[@]}" --rsh="${SSH_COMMAND_LINE}");
fi;
# final add source and target
cmd=("${cmd[@]}" "${SOURCE}" "${TARGET}");
# debug output
if [ "${DEBUG}" -eq 1 ];
then
	for i in "${cmd[@]}";
	do
		echo "CMD: ${i}";
	done;
fi;
# dry run prefix
if [ ! -z "${DRY_RUN}" ];
then
	_DRY_RUN=' [DRY RUN]';
else
	_DRY_RUN='';
fi;
script_start_time=`date +'%F %T'`;
START=`date +'%s'`;
PID=$$;
echo "==> [${PID}]${_DRY_RUN} Sync '${SOURCE}' to '${TARGET}', start at '${script_start_time}' ..." | ${LOG_CONTROL} | ${LOG_TRANSFER};
"${cmd[@]}" | ${LOG_TRANSFER};
DURATION=$[ $(date +'%s')-${START} ];
echo "<== [${PID}]${_DRY_RUN} Finished rsync copy '${SOURCE}' to '${TARGET}' started at ${script_start_time} and finished at $(date +'%F %T') and run for $(convert_time ${DURATION})." | ${LOG_CONTROL} | ${LOG_TRANSFER};
# remove lock file
rm -f "${run_file}";
