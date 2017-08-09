#!/bin/bash

# https://github.com/jaekwon-park/bash_history_extend/
# Mail to jaekwon.park@openstack.computer

function rsyslog_set()
{
	for i in "/var/log/messages" "\-/var/log/syslog"
        do
                rsyslog_conf_file=$(grep -R "$i" /etc/rsyslog*  | awk -F: '{print $1}')
                rsyslog_conf=$(grep -R "$i" /etc/rsyslog*  | awk -F: '{print $2}' | awk '{print $1}' | sed "s/;local5.none;local6.none//")
                rsyslog_log_file=$(grep -R "$i" /etc/rsyslog*  | awk -F: '{print $2}' | awk '{print $2}')
        		rsyslog_conf_number=$(grep -Rn "$i" /etc/rsyslog*  | awk -F: '{print $2}')
        done
		sed -i $rsyslog_conf_number"d" $rsyslog_conf_file
		echo $rsyslog_conf";local5.none;local6.none	"$rsyslog_log_file >> $rsyslog_conf_file
}

function register () {
# check the package management tool
rpm_path=$(type -p rpm)
dpkg_path=$(type -p dpkg)

if [ -e "$rpm_path" ]
then
    vim_path=$($rpm_path -ql vim-common | grep ^/etc.*vimrc$)
        # install vim-common package for rhel if vim-common package doesn't Install 
        if [ -z "$vim_path" ] 
        then
            yum -y install vim-common
            vim_path=$($rpm_path -ql vim-common | grep ^/etc.*vimrc$)
        fi
elif [ -e "$dpkg_path" ]
then
    vim_path=$($dpkg_path -L vim-common | grep ^/etc.*vimrc$)
        # install vim-common package for ubuntu if vim-common package doesn't Install   
        if [ -z "$vim_path" ]
        then
            apt-get install -y vim-common
            vim_path=$($dpkg_path -L vim-common | grep ^/etc.*vimrc$)
        fi
else
    echo "can't not find vimrc path"
    exit
fi

echo "local6.debug /var/log/bash_history.log" > /etc/rsyslog.d/100-bash_history_extention.conf
rsyslog_set
service rsyslog restart

mkdir -p /etc/bash_history_extention
echo "LOGGING_FILE_SIZE=2048000" >  /etc/bash_history_extention/config
echo "SYSLOG_LEVEL=$(cat /etc/rsyslog.d/100-bash_history_extention.conf | awk '{print $1}')" >>  /etc/bash_history_extention/config

echo "remoteip=\$(who -m | awk -F\( '{print \$2}' | sed \"s/[()]//g\" )" > /etc/profile.d/bash_history_extention.sh
echo "export PROMPT_COMMAND='RETRN_VAL=\$?;logger -p local6.debug \"\$(whoami) \$remoteip [\$\$] [\$PWD]: \$(history 1 | sed \"s/^[ ]*[0-9]\+[ ]*//\" ) [\$RETRN_VAL]\"'" >> /etc/profile.d/bash_history_extention.sh
echo "readonly PROMPT_COMMAND" >> /etc/profile.d/bash_history_extention.sh
echo "alias vi=vim" >> /etc/profile.d/bash_history_extention.sh

#vimrc backup
cp $vim_path /etc/bash_history_extention/vimrc.backup

# vimrc config
echo "set backup" >> $vim_path
echo "augroup backups" >> $vim_path
echo "  au! " >> $vim_path
echo "autocmd BufWritePost,FileWritePost * !/usr/local/bin/editor_logger.sh <afile> <afile>~" >> $vim_path
echo "augroup END" >> $vim_path

cat << EOF > /usr/local/bin/editor_logger.sh
#!/bin/bash
source  /etc/bash_history_extention/config

# Logging  Edited File history
LOGGING_EDITED_FILE_HISTORY()
{
if [ \$(du -b \$1 | cut -f 1) -gt "\$LOGGING_FILE_SIZE" ]
then
    logger -p \$SYSLOG_LEVEL "\$(whoami) [\$PWD]: Edit on \$1"
    logger -p \$SYSLOG_LEVEL "File \$1 is Biiger then \$LOGGING_FILE_SIZE Bytes. so This file doesn't remain the change log."
else
    # define Logger File Name
    edited_file=\$(echo \$(basename \$1)-\$(openssl rand -hex 16))
    diff -uNr \$2 \$1 > /var/log/changed_file/\$edited_file
    if [ \$(du -b /var/log/changed_file/\$edited_file | cut -f 1) -eq "0" ]
    then
        rm -rf /var/log/changed_file/\$edited_file
    else
        logger -p \$SYSLOG_LEVEL "Changed the file \$1 : /var/log/changed_file/\$edited_file"
    fi
fi
}

LOGGING_EDITED_FILE_HISTORY \$1 \$2
# remove temporary file
rm -rf \$2
EOF
chmod +x /usr/local/bin/editor_logger.sh
mkdir -p /var/log/changed_file/
chmod 773 /var/log/changed_file/
}

function delete () {

if [ -e "/etc/bash_history_extention/config" ]
then
    mv /etc/bash_history_extention/vimrc.backup /etc/vimrc
    rm -rf /etc/bash_history_extention
    rm -rf /etc/profile.d/bash_history_extention.sh
    rm -rf /usr/local/bin/editor_logger.sh
    rm -rf /etc/rsyslog.d/100-bash_history_extention.conf
    service rsyslog restart
    echo "bash history extention delete completed"
else
    echo "bash history extention config doesn't exsit"
    echo "bash history extention delete failed"
fi
}

function usage () {
    echo "Usage: $(basename $0) [-d|-i]"
    echo "	-i : install bash history extention"
    echo " 	-d : delete bash history extention"
    echo ""
    echo ""
    exit $E_BADARGS
}

E_BADARGS=65
index=1

if [ ! -n "$1" ]
then
    usage
fi

for arg in "$@"
do
    let "index+=1"
done

if [ $index != 2 ]
then
    echo "using only one options [-d|-i]"
    usage
fi


case $1 in

-i)
    register
;;

-d)
    delete
;;

*)
    usage

;;

esac
