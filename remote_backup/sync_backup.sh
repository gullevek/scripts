#!/bin/bash

# AUTHOR: Clemens Schwaighofer
# DATE: 2013/12/13
# DESC: rsync data from one folder to another folder, or to a remote host. Write detailed log of what has been synced plus a control log of start and end time

function usage ()
{
	cat <<- EOT
	Usage: ${0##/*/} [-d] [-v [-v]] [-p [-p]] [-o <precision>] [-x] [-c] [-n] [-e <ssh string options>] [-s <source folder>] [-t <target folder>] [-l <log file>] [-r <run folder>] [-u <exclude file> [-u ...]] [-f <exclude pattern file>]

	-d: debug output, shows full rsync command
	-v: verbose output. If not given data is only written to log files. -v1 is only stats out, -v2 is also progress info out if -p is given
	-p: do progress calculation, if two -p are given, also percent data is calculated
	-o: change the percent precision from the default two. Must be a valud numeric number from 0 to 9
	-n: dry run
	-x: add -X and -A rsync flag for extended attributes. Can oops certain kernels.
	-l: log file name, if not set default name is used
	-r: override run folder /var/run/
	-s: source folder, must exist
	-t: target folder, must exist
	-c: do check if source or target folder exist
	-e: turns on -e "ssh", if something is given it assumes it is the pem key and creates -e "ssh -i <key file>". turns off folder checking
	-u: exclude file or folder, can be given multiple times
	-f: exclude from file (see rsync for PATTERN description)

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
		output[${#output[*]}]=$(awk "BEGIN {printf \"%d\", ${timestamp}/${timeslice}}");
		timestamp=$(awk "BEGIN {printf \"%d\", ${timestamp}%${timeslice}}");
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

# METHOD: pipe
# PARAMS: string piped into
# RETURN: progress info as string
# CALL  : echo "string" | pipe | ...
# DESC  : if xfer/xfr data is present calcualtes overall progress
#       : if PROGRESS = 1, do progress calc, else just print stats to output
# VARIABLES OUTSIDE:
# set to check to zero for final stats output
STATS=0;
# print a new line before stats
FIRST_STATS=1;
# START METHOD:
function pipe
{
	while read data;
	do
		if [ ${PROGRESS} -ge 1 ];
		then
			case "${data}" in
				*xfer\#*|*xfr\#*)
					# ${string#*=} to get nnn/mmm)
					# $(string%/*} to get nnn [from nnn/mmm)]
					# ${string%/*)} to get mmmm [from nnn/mmm)]
					tmp_data=${data#*#};
					xfer_files=${tmp_data%,*};
					tmp_data=${data#*=};
					to_check=${tmp_data%/*};
					tmp_data=${tmp_data#*/};
					max_check=${tmp_data%)};
					datetime=$(date +"%F %T");
					# do only awk percent calculation if we have two progress flags set
					if [ ${PROGRESS} -eq 2 ];
					then
						percent_done=$(awk "BEGIN {printf \"%.${PRECISION}f\", (($max_check-$to_check)/$max_check) * 100}")"%";
						percent_xfer=$(awk "BEGIN {printf \"%.${PRECISION}f\", (($xfer_files)/$max_check) * 100}")"%";
						string=$(printf "[%s] [%s] Done: %${PRINTF_PRECISION}s (Xfer: %${PRINTF_PRECISION}s) | Checked: %'d, Open to transfer: %'d, Transfered: %'d\n" "${datetime}" ${PID} ${percent_done} ${percent_xfer} ${max_check} ${to_check} ${xfer_files});
					else
						string=$(printf "[%s] [%s] Checked: %'d, Open to transfer: %'d, Transfered: %'d\n" "${datetime}" ${PID} ${max_check} ${to_check} ${xfer_files});
					fi;
					# in case we have two verbose, print to std out
					if [ ${VERBOSE} -ge 2 ];
					then
						echo "${string}" | ${LOG_PROGRESS};
					else
						echo "${string}" | ${LOG_PROGRESS} > /dev/null;
					fi;
				;;
				"Number of files"*)
					STATS=1;
				;;
			esac
		else
			# if no progress is given, just print out stats
			case "${data}" in
				"Number of files"*)
					STATS=1;
				;;
			esac
		fi;
		# output stats to progress part
		if [ ${STATS} -eq 1 ];
		then
			if [ ${FIRST_STATS} -eq 1 ];
			then
				FIRST_STATS=0;
				echo "" | ${LOG_PROGRESS};
			fi;
			echo "${data}" | ${LOG_PROGRESS};
		fi;
	done;
}

# METHOD: output
# PARAMS: string piped into
# RETURN: putput or nothing
# CALL  : echo "string" | output
# DESC  : if verbose is set, print to STDOUT
function output
{
	while read data;
	do
		if [ ${VERBOSE} -ge 1 ];
		then
			echo "${data}" | ${LOG_CONTROL} | ${LOG_TRANSFER} | ${LOG_ERROR} | ${LOG_PROGRESS};
		else
			echo "${data}" | ${LOG_CONTROL} | ${LOG_TRANSFER} | ${LOG_ERROR} | ${LOG_PROGRESS} > /dev/null;
		fi;
	done;
}

# if no verbose flag is set run, no output
VERBOSE=0;
PROGRESS=0;
# always set attribute for rsync
VERBOSE_ATTRS='-P';
# dry run, do not actually copy any data
DRY_RUN='';
# extended attributes for ACL sync (default not set)
EXT_ATTRS='';
# command line given
_LOG_FILE='';
# default log sets
LOG_FILE_RSYNC="/var/log/rsync/rsync_backup.rsync.log"; # log written from rsync
LOG_FILE_CONTROL="/var/log/rsync/rsync_backup.control.log"; # central control log (logs only start/end, is shared between sessions)
LOG_FILE_TRANSFER="/var/log/rsync/rsync_backup.transfer.log"; # rsync output (has percent progress per file, xfr, chk data)
LOG_FILE_ERROR="/var/log/rsync/rsync_backup.error.log"; # STDERR from rsync log
LOG_FILE_PROGRESS="/var/log/rsync/rsync_backup.progress.log" # progress output with stats
# ssh command
SSH_COMMAND_ON='';
SSH_COMMAND_LINE='';
# folder check
CHECK=1;
# rsync exclude folders
EXCLUDE=();
EXCLUDE_FROM='';
# run lock file
RUN_FOLDER='/var/run/';
_RUN_FOLDER='';
# debug flag (prints out rsync command)
DEBUG=0;
# percent precision
PRECISION=2;
_PRECISION='';
# regex check for precision
PRECISION_REGEX="^[0-9]{1}$";

# set options
while getopts ":dvpo:ncxs:t:l:e:r:u:f:h" opt
do
	case ${opt} in
		d|debug)
			DEBUG=1;
			;;
		v|verbose)
			# verbose flag shows output on the command line, each -v increases the verbose
			let VERBOSE=${VERBOSE}+1;
			;;
		p|progress)
			# verbose flag shows output on the command line, each -v increases the verbose
			let PROGRESS=${PROGRESS}+1;
			;;
		o|precision)
			if [ -z "${_PRECISION}" ];
			then
				_PRECISION=${OPTARG};
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
		f|exclude-from-file)
			if [ -z "${EXCLUDE_FROM}" ];
			then
				EXCLUDE_FROM="${OPTARG}";
			fi;
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

# only check precision if progress is 2
if [ ${PROGRESS} -ge 2 ] && [ ! -s "${_PRECISION}" ];
then
	# check that the precision is in the range from 0 to 9
	if ! [[ "${_PRECISION}" =~ ${PRECISION_REGEX} ]];
	then
		echo "The -o parameter needs to be in the range from 0 to 9.";
		exit 1;
	else
		PRECISION=${_PRECISION};
	fi;
fi;
# set the printf precision for percent output
if [ ${PRECISION} -eq 0 ];
then
	DEFAULT_PRINTF_PRECISION=4;
else
	DEFAULT_PRINTF_PRECISION=5;
fi;
PRINTF_PRECISION=$[ $DEFAULT_PRINTF_PRECISION+$PRECISION ];

# use new log file path, if the folder is ok and writeable
if [ ! -z "${_LOG_FILE}" ];
then
	# check if this is valid writeable file
	touch "${_LOG_FILE}";
	if [ -w "${_LOG_FILE}" ];
	then
		# if the _LOG_FILE is size 0 (just touched), remove it
		if [ ! -s "${_LOG_FILE}" ];
		then
			rm "${_LOG_FILE}";
		fi;
		# set new control log file in the given folder
		LOG_FILE_CONTROL=$(dirname ${_LOG_FILE})"/rsync_backup.control.log";
		# rsync log file
		LOG_FILE_RSYNC=$(dirname ${_LOG_FILE})"/"$(basename ${_LOG_FILE})".rsync.log";
		# transfer log file for direct rsync output
		LOG_FILE_TRANSFER=$(dirname ${_LOG_FILE})"/"$(basename ${_LOG_FILE})".transfer.log";
		# rsync STDERR output
		LOG_FILE_ERROR=$(dirname ${_LOG_FILE})"/"$(basename ${_LOG_FILE})".error.log";
		# progress and stats log file
		LOG_FILE_PROGRESS=$(dirname ${_LOG_FILE})"/"$(basename ${_LOG_FILE})".progress.log";
	else
		echo "Log file '${_LOG_FILE}' is not writeable, fallback to '${LOG_FILE_RSYNC}'";
		# check for log file too
	fi;
else
	# do check if we can write to log global
	touch "${LOG_FILE_RSYNC}";
	if [ ! -w "${LOG_FILE_RSYNC}" ];
	then
		echo "Cannot write to log file ${LOG_FILE_RSYNC}.";
		exit;
	fi;
fi;

# if check is enabled, check that both folders are directories
if [ ${CHECK} -eq 1 ];
then
	if [[ ! -d "${SOURCE}" || ! -d "${TARGET}" ]];
	then
		echo "Give source and target path.";
		if [ ! -z "${SOURCE}" ] && [ ! -d "${SOURCE}" ];
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

# check that the exclude from file is readable
if [ ! -z "${EXCLUDE_FROM}" ] && [ ! -f "${EXCLUDE_FROM}" ];
then
	echo "Cannot read the exclude from file: ${EXCLUDE_FROM}.";
	exit;
fi;
# check that EXCLUDE & EXCLUDE_FROM are not both set
if [ ! -z "${EXCLUDE_FROM}" ] && [ ${#EXCLUDE[*]} -ne 0 ];
then
	echo "-u (exculude) and -f (exclude from file) cannot be set at the same time.";
	exit;
fi;

# check that we can write to the run folder
if [ ! -w "${RUN_FOLDER}" ];
then
	echo "Cannot write to ${RUN_FOLDER} and will not create lock file.";
	echo "Waiting 5 seconds for abort: ";
	for ((i=5;i>=1;i--));
	do
		echo -n $i" ";
		sleep 1;
	done;
	echo " ";
fi;

LOG_CONTROL="tee -a ${LOG_FILE_CONTROL}";
LOG_TRANSFER="tee -a ${LOG_FILE_TRANSFER}";
LOG_ERROR="tee -a ${LOG_FILE_ERROR}";
LOG_PROGRESS="tee -a ${LOG_FILE_PROGRESS}";
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
# log format: Operation, Info of transfer, [permissions, user, group], file transfered, symlink/hardlink info, [file size in bytes & human readable, bytes transfered & humand readable]
cmd=(rsync -az --stats --delete --exclude="lost+found" -hh --log-file="${LOG_FILE_RSYNC}" --log-file-format="%o %i [%B:%4U:%4G] %f%L %'l [--> {%''l} => %'b {%''b}]" ${VERBOSE_ATTRS} ${DRY_RUN} ${EXT_ATTRS});
#basic_params='-azvi --stats --delete --exclude="lost+found" -hh';
# add exclude parameters
for exclude in "${EXCLUDE[@]}";
do
	cmd=("${cmd[@]}" --exclude="${exclude}");
done;
if [ ! -z "${EXCLUDE_FROM}" ];
then
	cmd=("${cmd[@]}" --exclude-from="${EXCLUDE_FROM}");
fi;
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
		echo "CMD: ${i}" | ${LOG_TRANSFER} | ${LOG_PROGRESS};
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
echo "==> [${PID}]${_DRY_RUN} Sync '${SOURCE}' to '${TARGET}', start at ${script_start_time} ..." | output;
# output of overall progress if verbose is set to 1
# if verbose is set to 2 it is also printed to console
# 2: only stats
# 3: stats and progress
# 4: stats and progress with percent
if [ ${VERBOSE} -ge 1 ];
then
	# stdout to transfer log & pipe and then to stdout, error to error log and to null unless verbose is set to three
	if [ ${VERBOSE} -ge 3 ];
	then
		"${cmd[@]}" > >(${LOG_TRANSFER} | pipe) 2> >(${LOG_ERROR} >&2);
	else
		"${cmd[@]}" > >(${LOG_TRANSFER} | pipe) 2> >(${LOG_ERROR} >/dev/null);
	fi;
else
	# if no verbose is given, just write to transfer log and that is it
	# all stdout/stderr is to dev null
	"${cmd[@]}" > >(${LOG_TRANSFER} | pipe >/dev/null) 2> >(${LOG_ERROR} >/dev/null);

fi;
DURATION=$[ $(date +'%s')-${START} ];
echo "<== [${PID}]${_DRY_RUN} Finished rsync copy '${SOURCE}' to '${TARGET}' started at ${script_start_time} and finished at $(date +'%F %T') and run for $(convert_time ${DURATION})." | output;
# remove lock file
if [ -f "${run_file}" ];
then
	rm -f "${run_file}";
fi;
