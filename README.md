# bash_history_extend

Linux 서버에 로그인한 사용자의 모든 명령어 실행 이력을 로그로 남기는 도구 모음.

두 가지 방식을 제공한다:

| 방식 | 디렉터리 | 의존성 |
|------|----------|--------|
| PROMPT_COMMAND + rsyslog (원본) | 루트 | rsyslog, vim |
| **auditd + audisp plugin (신규)** | `auditd/` | auditd, Go (빌드 시) |

---

## 원본 방식 (PROMPT_COMMAND + rsyslog)

### 동작 원리

```
사용자 셸 → PROMPT_COMMAND → logger → rsyslog(local6.debug) → /var/log/bash_history.log
편집기(vim) → BufWritePost autocmd → editor_logger.sh → diff → /var/log/changed_file/
```

* Bash `PROMPT_COMMAND`에 `logger` 명령을 주입하여 매 명령어 실행 후 syslog로 전송
* `readonly PROMPT_COMMAND`로 사용자가 임의로 해제하지 못하도록 보호
* vim vimrc hook을 통해 파일 수정 전후 diff를 `/var/log/changed_file/`에 저장

### 설치 / 삭제

```bash
chmod +x Installer.sh
sudo ./Installer.sh -i   # 설치
sudo ./Installer.sh -d   # 삭제

# 원라인 설치
curl -s https://raw.githubusercontent.com/jaekwon-park/bash_history_extend/master/Installer.sh | bash -s -- -i
```

### 로그 형식

```
Jan 12 23:50:42 hostname user: root 10.1.1.105 [7604] [/opt/harbor]: ls -alh [0]
```

`시각 호스트 접속계정: 실행계정 원격IP [ShellPID] [현재경로]: 명령어 [종료코드]`

### 파일 구성

| 파일 | 용도 |
|------|------|
| `Installer.sh` | 설치 / 삭제 스크립트 |
| `/etc/profile.d/bash_history_extention.sh` | PROMPT_COMMAND 주입 (설치 후 생성) |
| `/usr/local/bin/editor_logger.sh` | vim 파일 변경 로깅 스크립트 (설치 후 생성) |
| `/etc/rsyslog.d/100-bash_history_extention.conf` | rsyslog local6.debug 라우팅 (설치 후 생성) |
| `/etc/bash_history_extention/config` | 로깅 설정 (LOGGING_FILE_SIZE, SYSLOG_LEVEL) |
| `/var/log/bash_history.log` | 명령어 실행 로그 |
| `/var/log/changed_file/` | vim 파일 변경 diff 저장 디렉터리 |

### 제약 사항

* Bash 전용 — zsh, fish 등 다른 셸에는 동작하지 않음
* `PROMPT_COMMAND`를 직접 `unset` 하거나 `env -i`로 우회 가능
* vim을 통한 파일 수정만 추적 (nano, emacs 등 미지원)
* 셸 재접속 후부터 적용됨

---

## auditd 방식 (신규)

```
사용자 → execve syscall → auditd → audisp → audit-cmd-logger → /var/log/cmd_history.log
파일 수정 → inode write → auditd 감시 → audit-cmd-logger → /var/log/cmd_history.log
```

* 커널 레벨에서 `execve` 시스템 콜을 직접 후킹 → 셸 종류 무관, 우회 불가
* `audisp` (audit dispatcher) 플러그인으로 동작 — 실시간 스트림 처리
* Go 정적 바이너리로 빌드 → 어떤 리눅스 배포판에서도 추가 의존성 없이 동작
* auditd 파일 감시 규칙으로 주요 경로의 쓰기 이벤트도 기록

### 지원 환경

* RHEL / CentOS / Rocky / AlmaLinux 6 / 7 / 8 / 9
* Debian / Ubuntu 16.04+
* auditd 2.x / 3.x 모두 지원

### 설치

```bash
cd auditd/
chmod +x Installer.sh
sudo ./Installer.sh -i   # 설치
sudo ./Installer.sh -d   # 삭제
sudo ./Installer.sh -s   # 상태 확인
```

### 설치 후 확인

설치가 완료되면 아래 경로에 파일이 생성된다.

#### 설치 파일 목록

| 경로 | 설명 |
|------|------|
| `/usr/local/bin/audit-cmd-logger` | audisp 플러그인 바이너리 |
| `/etc/audit/rules.d/audit-cmd-logging.rules` | auditd 감사 규칙 (auditd 2.x) |
| `/etc/audit/audit-cmd-logging.rules` | auditd 감사 규칙 (rules.d 없는 구버전) |
| `/etc/audit/plugins.d/audit-cmd-logger.conf` | audisp 플러그인 설정 (auditd 3.x) |
| `/etc/audisp/plugins.d/audit-cmd-logger.conf` | audisp 플러그인 설정 (auditd 2.x) |
| `/var/log/cmd_history.log` | 명령어 실행 로그 |
| `/var/log/changed_file/` | 파일 수정 diff 저장 디렉터리 |
| `/etc/logrotate.d/cmd_history` | logrotate 설정 |

> `auditd 2.x` vs `3.x` 구분: `auditd --version` 으로 확인. 3.x 이상이면 `/etc/audit/plugins.d/`, 미만이면 `/etc/audisp/plugins.d/` 경로 사용.

#### 설치 확인 명령어

```bash
# 바이너리 설치 확인
ls -lh /usr/local/bin/audit-cmd-logger

# auditd 규칙 적용 확인
auditctl -l | grep cmd_logging

# audisp 플러그인 설정 확인 (auditd 버전에 따라 경로 상이)
cat /etc/audit/plugins.d/audit-cmd-logger.conf 2>/dev/null \
  || cat /etc/audisp/plugins.d/audit-cmd-logger.conf

# auditd 서비스 상태 확인
systemctl status auditd

# 로그 실시간 확인
tail -f /var/log/cmd_history.log

# 설치 상태 일괄 확인 (스크립트 내장 명령)
sudo ./Installer.sh -s
```

### 로그 형식

```
2026-03-05T16:08:00+09:00 user=root(uid=0,auid=1000) remote=10.1.1.105 tty=pts0 pid=12345 ppid=12344 cwd=/home/user exit=0 cmd=ls -alh /etc
```

파일 쓰기 이벤트:
```
2026-03-05T16:09:00+09:00 user=root(uid=0,auid=1000) remote=10.1.1.105 FILE_WRITE path=/etc/nginx/nginx.conf (via /usr/bin/vim)
```

### 파일 구성

```
auditd/
├── Installer.sh                        설치 / 삭제 / 상태 확인 스크립트
├── rules/
│   └── audit-cmd-logging.rules         auditd 감사 규칙
│       - execve 시스템 콜 캡처 (cmd_logging key)
│       - 주요 디렉터리 파일 쓰기 감시 (file_changes key)
├── plugins/
│   └── audit-cmd-logger.conf           audisp 플러그인 설정
│       - 플러그인 활성화 (active = yes)
│       - 바이너리 경로 / 포맷(string) 지정
├── logrotate/
│   └── cmd_history                     logrotate 설정
│       - /var/log/cmd_history.log 일별 로테이션, 90일 보관
│       - /var/log/changed_file/ 주별 로테이션, 12주 보관
└── cmd/
    └── audit-cmd-logger/
        ├── go.mod                      Go 모듈 정의
        └── main.go                     audisp 플러그인 메인 소스
```

#### `audit-cmd-logging.rules` 상세

| 규칙 | 설명 |
|------|------|
| `-D` | 기존 규칙 전체 삭제 |
| `-b 16384` | 커널 버퍼 크기 |
| `-f 1` | 실패 모드 (1=printk) |
| `arch=b64 -S execve -F auid!=4294967295 -k cmd_logging` | 64비트 execve, 실 로그인 사용자 |
| `arch=b32 -S execve -F auid!=4294967295 -k cmd_logging` | 32비트 execve |
| `-w /etc -p wa -k file_changes` | /etc 하위 쓰기 감시 |

#### `audit-cmd-logger.conf` 상세

| 항목 | 값 | 설명 |
|------|-----|------|
| `active` | `yes` | 플러그인 활성화 |
| `direction` | `out` | auditd → 플러그인 방향 |
| `path` | `/usr/local/bin/audit-cmd-logger` | 바이너리 경로 |
| `type` | `always` | 장기 실행 데몬으로 구동 |
| `format` | `string` | 텍스트 형식으로 레코드 수신 |

#### `audit-cmd-logger` 바이너리 상세

| 기능 | 설명 |
|------|------|
| stdin 모드 | audisp 플러그인으로 동작, stdin에서 audit 레코드 읽기 |
| tail 모드 | `-mode tail` 플래그로 `/var/log/audit/audit.log` 직접 테일링 |
| 세션 추적 | `USER_LOGIN` 이벤트로 `ses → remote_ip` 매핑 |
| EXECVE 파싱 | 멀티파트 인수(`a0[0]`, `a0[1]` …) 및 hex 인코딩 처리 |
| 정적 빌드 | `CGO_ENABLED=0` — glibc 의존성 없음 |

### 수동 빌드

```bash
cd auditd/cmd/audit-cmd-logger/
CGO_ENABLED=0 GOOS=linux go build -ldflags="-extldflags=-static -s -w" -o audit-cmd-logger .

# 크로스 컴파일 (ARM64)
CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags="-extldflags=-static -s -w" -o audit-cmd-logger-arm64 .
```

### 원본 방식과 비교

| 항목 | PROMPT_COMMAND (원본) | auditd (신규) |
|------|----------------------|----------------|
| 동작 레이어 | 유저스페이스 (셸 레벨) | 커널 레벨 |
| 우회 가능성 | env -i, unset 등 가능 | 사실상 불가 |
| 셸 의존성 | Bash 전용 | 모든 프로그램 |
| 파일 편집 추적 | vim만 | 모든 편집기 |
| 의존성 | rsyslog, vim | auditd |
| 추가 배포 | 설정 파일만 | 정적 Go 바이너리 |
| 성능 영향 | 최소 | execve당 오버헤드 |
| 로그 위치 | /var/log/bash_history.log | /var/log/cmd_history.log |

---

## 문의

jaekwon.park@openstack.computer

## Special Thanks

seowon@hawaii.edu (vim 관련 변경 로그 아이디어 제공)
