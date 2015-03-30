최초 설치시

아래 명령어로 설치
# sh vihistory 


삭제는 아래 절차에 따라 진행
rm /etc/history_log 
/etc/bashrc (배포판마다 다를수 있음)
/etc/rsyslog.conf (혹은 syslog.conf)
파일에 추가된 항목 수동으로 삭제하여야함


설치후 쉘에 재접속해야 해당 명령어가 로그에 남음
/var/log/bash_history.log 파일에 모든 명령어 및 수정 파일 로그가 남음



