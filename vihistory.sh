#!/bin/bash

if [ -n "$1" ]
then 

# check vim and vi editor. default value is vim 
if [  -z $(whereis vim | awk '{print $2}') ] 
then
	vim=$(whereis vi | awk '{print $2}')
else
	vim=$(whereis vim | awk '{print $2}')
fi


# logging edit history 
if [ -e "$1" ]
then
	if [ $(du -b $1 | cut -f 1) -gt "2048000" ] # except Logging over 2Mbytes File
	then
		$vim $1
		logger -p local6.debug "$(whoami) [$PWD]: Edit on $1"
		logger -p local6.debug "file $1 is bigger then 2Mb. so this file doesn't remain the change log." 
	else
		logger -p local6.debug "$(whoami) [$PWD]: Edit started $1"
		var1=$(mktemp) # make temporay file
		cp -p $1 $var1 # copy original file
		$vim $1
		temp_IFS=$IFS
		IFS=$'\n'
		for i in $( diff -uNr $var1 $1 |  tail -n$(expr $(diff -uNr $var1 $1 | wc -l) - 1) ) 
		do
			logger -p local6.debug "Changed the file $1 : $i"
		done
		IFS=$temp_IFS
		rm $var1 
		logger -p local6.debug "$(whoami) [$PWD]: End of Edit $1"
	fi
else
	$vim $1
	logger -p local6.debug "created New file $1"
fi


fi


if [ ! -e /etc/history_log ]
then
	touch /etc/history_log
	bashrc=$(ls /etc | grep bashrc)
	echo "#!/bin/bash" > /usr/local/bin/vimhistory
	head -n 42  $(basename $0) | tail -n 37  >> /usr/local/bin/vimhistory
	chmod +x /usr/local/bin/vimhistory
	if [ $(ps -ef | grep rsyslog | wc -l ) -lt "2" ]
	then
		log_config=syslog.conf
		log_daemon=syslog
	else
		log_config=rsyslog.conf	
		log_daemon=rsyslog
	fi

	if [ -z $(grep "export PROMPT_COMMAND=" /etc/$bashrc) ]
	then
		echo "export PROMPT_COMMAND='RETRN_VAL=\$?;logger -p local6.debug \"\$(whoami) [\$\$] [\$PWD]: \$(history 1 | sed \"s/^[ ]*[0-9]\+[ ]*//\" ) [\$RETRN_VAL]\"'" >> /etc/$bashrc
		echo "readonly PROMPT_COMMAND" >> /etc/$bashrc
	fi

	if [ -z $(grep /var/log/bash_history.log /etc/$log_config) ]
	then
		echo "local6.debug /var/log/bash_history.log" >> /etc/$log_config
		service $log_daemon restart
	fi
	
	if [ -z $(grep "alias vim='vimhistory'" /etc/$bashrc) ]
	then
		echo "alias vim='vimhistory'" >> /etc/$bashrc
	fi

	if [ -z $(grep "alias vi='vimhistory'" /etc/$bashrc) ]
	then
		echo "alias vi='vimhistory'" >> /etc/$bashrc
	fi

fi
