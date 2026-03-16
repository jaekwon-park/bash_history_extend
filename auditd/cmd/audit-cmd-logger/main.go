// audit-cmd-logger: audisp plugin for logging user command executions via auditd
//
// Build (static binary):
//   CGO_ENABLED=0 GOOS=linux go build -ldflags="-extldflags=-static -s -w" -o audit-cmd-logger .
//
// Operation:
//   Reads audit records from stdin (audisp plugin mode) or tails /var/log/audit/audit.log,
//   groups records by serial number, and on EOE emits a formatted log line to
//   /var/log/cmd_history.log for every execve syscall made by a logged-in user.
//
// Log format:
//   TIMESTAMP user=USERNAME(uid=UID,auid=AUID) remote=IP tty=TTY pid=PID ppid=PPID cwd=CWD exit=CODE cmd=CMDLINE
//
// File-change log format (auditd watch events):
//   TIMESTAMP user=USERNAME(uid=UID,auid=AUID) remote=IP FILE_EVENT path=PATH

package main

import (
	"bufio"
	"encoding/hex"
	"flag"
	"fmt"
	"io"
	"log"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode"
)

// ──────────────────────────────────────────────────────────── constants ──

const (
	defaultLogFile   = "/var/log/cmd_history.log"
	defaultAuditLog  = "/var/log/audit/audit.log"
	eventBufMaxSize  = 4096 // max buffered incomplete events
	tailPollInterval = 250 * time.Millisecond
)

// ──────────────────────────────────────────────────────────── globals ──

var (
	logFilePath = flag.String("log", defaultLogFile, "output log file")
	inputMode   = flag.String("mode", "stdin", "input mode: stdin | tail")
	auditLog    = flag.String("audit-log", defaultAuditLog, "audit log path (tail mode)")

	// hostname cached at startup
	systemHostname string

	// sessionMap: ses -> remote_ip  (populated from USER_LOGIN / USER_START)
	sessionMu  sync.RWMutex
	sessionMap = make(map[string]string)

	// eventBuf: serial -> { recordType -> { field -> value } }
	eventMu  sync.Mutex
	eventBuf = make(map[string]map[string]map[string]string)
	// preserve insertion order of record types within an event
	eventOrder = make(map[string][]string)

	// msgRe parses: type=XXX msg=audit(TS:SERIAL): FIELDS
	msgRe = regexp.MustCompile(`^type=(\S+)\s+msg=audit\(\d+\.\d+:(\d+)\):\s*(.*)$`)
)

// ──────────────────────────────────────────────────────────── main ──

// writeLog opens the log file, appends a single formatted line, then closes it.
// This ensures log rotation is handled transparently: after logrotate creates
// a new cmd_history.log, the next call will open and write to the new file.
func writeLog(format string, args ...interface{}) {
	f, err := os.OpenFile(*logFilePath, os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0640)
	if err != nil {
		return
	}
	defer f.Close()
	fmt.Fprintf(f, format+"\n", args...)
}

func main() {
	flag.Parse()

	// cache hostname once
	systemHostname, _ = os.Hostname()
	if systemHostname == "" {
		systemHostname = "localhost"
	}

	switch *inputMode {
	case "stdin":
		readLines(os.Stdin)
	case "tail":
		tailFile(*auditLog)
	default:
		log.Fatalf("unknown mode: %s", *inputMode)
	}
}

// ──────────────────────────────────────────────────────────── input readers ──

func readLines(r io.Reader) {
	scanner := bufio.NewScanner(r)
	scanner.Buffer(make([]byte, 1<<20), 1<<20)
	for scanner.Scan() {
		processLine(scanner.Text())
	}
}

// tailFile follows an audit log file, re-opening on rotation.
func tailFile(path string) {
	var (
		f      *os.File
		offset int64
		err    error
	)

	for {
		if f == nil {
			f, err = os.Open(path)
			if err != nil {
				time.Sleep(tailPollInterval)
				continue
			}
			// seek to end on first open to avoid replaying history
			offset, _ = f.Seek(0, io.SeekEnd)
		}

		buf := make([]byte, 65536)
		n, readErr := f.ReadAt(buf, offset)
		if n > 0 {
			offset += int64(n)
			scanner := bufio.NewScanner(strings.NewReader(string(buf[:n])))
			for scanner.Scan() {
				processLine(scanner.Text())
			}
		}

		if readErr == io.EOF {
			// check for rotation: if file shrank, reopen
			fi, statErr := os.Stat(path)
			if statErr == nil && fi.Size() < offset {
				f.Close()
				f = nil
				offset = 0
			}
			time.Sleep(tailPollInterval)
			continue
		}
		if readErr != nil {
			f.Close()
			f = nil
			time.Sleep(tailPollInterval)
		}
	}
}

// ──────────────────────────────────────────────────────────── line processor ──

func processLine(line string) {
	m := msgRe.FindStringSubmatch(strings.TrimSpace(line))
	if m == nil {
		return
	}
	recType := m[1]
	serial := m[2]
	fields := m[3]

	kvs := parseKVs(fields)

	switch recType {
	case "EOE":
		eventMu.Lock()
		processEvent(serial)
		delete(eventBuf, serial)
		delete(eventOrder, serial)
		eventMu.Unlock()
		return

	case "USER_LOGIN", "USER_START", "USER_AUTH":
		handleLoginEvent(kvs)
		return
	}

	// Buffer record
	eventMu.Lock()
	defer eventMu.Unlock()

	// Evict oldest entry if buffer is too large
	if len(eventBuf) >= eventBufMaxSize {
		for k := range eventBuf {
			delete(eventBuf, k)
			delete(eventOrder, k)
			break
		}
	}

	if _, ok := eventBuf[serial]; !ok {
		eventBuf[serial] = make(map[string]map[string]string)
		eventOrder[serial] = nil
	}
	// If same type arrives twice (e.g. multiple PATH records), merge under a unique key
	key := recType
	if _, exists := eventBuf[serial][key]; exists {
		key = fmt.Sprintf("%s_%d", recType, len(eventOrder[serial]))
	}
	eventBuf[serial][key] = kvs
	eventOrder[serial] = append(eventOrder[serial], key)
}

// ──────────────────────────────────────────────────────────── login tracking ──

func handleLoginEvent(kvs map[string]string) {
	ses := kvs["ses"]
	if ses == "" || ses == "unset" {
		return
	}
	addr := unquote(kvs["addr"])
	if addr == "" || addr == "?" {
		addr = unquote(kvs["hostname"])
	}
	if addr == "" || addr == "?" {
		return
	}
	sessionMu.Lock()
	sessionMap[ses] = addr
	sessionMu.Unlock()
}

func remoteIP(ses string) string {
	sessionMu.RLock()
	ip := sessionMap[ses]
	sessionMu.RUnlock()
	if ip == "" {
		return "localhost"
	}
	return ip
}

// ──────────────────────────────────────────────────────────── event processor ──

func processEvent(serial string) {
	records := eventBuf[serial]
	if records == nil {
		return
	}

	syscall, ok := records["SYSCALL"]
	if !ok {
		return
	}

	key := unquote(syscall["key"])

	switch {
	case key == "cmd_logging":
		emitCommandLog(syscall, records)
	case key == "file_changes":
		emitFileChangeLog(syscall, records)
	}
}

func emitCommandLog(syscall map[string]string, records map[string]map[string]string) {
	uid := syscall["uid"]
	auid := syscall["auid"]
	ses := syscall["ses"]
	shellPID := syscall["ppid"] // parent process = the shell that invoked this command
	exitCode := syscall["exit"]
	tty := unquote(syscall["tty"])

	// Skip kernel threads / unset auid daemons (auid=4294967295)
	if auid == "4294967295" {
		return
	}

	// loginUser: who logged in (auid), execUser: who ran the command (uid)
	loginUser := lookupUID(auid)
	execUser := lookupUID(uid)
	remote := remoteIP(ses)

	// Classify execution context from tty field
	// pts*        : remote interactive session (SSH, etc.)
	// tty*, console: local interactive session (physical/virtual console)
	// (none)      : no controlling terminal → background process (cron, systemd, script)
	// ?, ""       : unknown / unset
	var execType string
	switch {
	case strings.HasPrefix(tty, "pts"):
		execType = "exec=remote_user"
	case tty == "(none)":
		execType = "exec=system"
	case strings.HasPrefix(tty, "tty") || tty == "console":
		execType = "exec=local_user"
	default:
		execType = "exec=unknown"
	}

	// Build command line from EXECVE record
	cmdline := buildCmdline(records)
	if cmdline == "" {
		cmdline = unquote(syscall["exe"])
	}
	if cmdline == "" {
		cmdline = unquote(syscall["comm"])
	}

	// CWD
	cwd := ""
	if cwdRec, ok := records["CWD"]; ok {
		cwd = unquote(cwdRec["cwd"])
	}

	// Format: Jan 12 23:50:42 hostname loginUser: execUser remote [shellPID] [execType] [cwd]: cmd [exit]
	ts := time.Now().Format(time.Stamp)
	writeLog("%s %s %s: %s %s [%s] [%s] [%s]: %s [%s]",
		ts, systemHostname, loginUser, execUser, remote, shellPID, execType, cwd, cmdline, exitCode)
}

func emitFileChangeLog(syscall map[string]string, records map[string]map[string]string) {
	uid := syscall["uid"]
	auid := syscall["auid"]
	ses := syscall["ses"]

	if auid == "4294967295" {
		return
	}

	loginUser := lookupUID(auid)
	execUser := lookupUID(uid)
	remote := remoteIP(ses)

	// Collect modified paths from PATH records
	paths := []string{}
	for key, rec := range records {
		if strings.HasPrefix(key, "PATH") {
			if nametype := rec["nametype"]; nametype == "NORMAL" || nametype == "CREATE" {
				if p := unquote(rec["name"]); p != "" {
					paths = append(paths, p)
				}
			}
		}
	}

	exe := unquote(syscall["exe"])

	// Format: Jan 12 23:50:42 hostname loginUser: execUser remote [EDIT] [path] (via exe)
	ts := time.Now().Format(time.Stamp)
	for _, p := range paths {
		writeLog("%s %s %s: %s %s [EDIT] [%s] (via %s)",
			ts, systemHostname, loginUser, execUser, remote, p, exe)
	}
}

// ──────────────────────────────────────────────────────────── EXECVE builder ──

func buildCmdline(records map[string]map[string]string) string {
	execve, ok := records["EXECVE"]
	if !ok {
		return ""
	}

	argc, _ := strconv.Atoi(execve["argc"])
	if argc == 0 {
		return ""
	}

	args := make([]string, 0, argc)
	for i := 0; i < argc; i++ {
		base := fmt.Sprintf("a%d", i)

		// Check for multi-part argument (a0[0], a0[1], ...)
		if _, hasPart := execve[base+"[0]"]; hasPart {
			var parts []string
			for j := 0; ; j++ {
				part, ok := execve[fmt.Sprintf("%s[%d]", base, j)]
				if !ok {
					break
				}
				parts = append(parts, decodeAuditValue(part))
			}
			args = append(args, strings.Join(parts, ""))
			continue
		}

		val, ok := execve[base]
		if !ok {
			break
		}
		args = append(args, decodeAuditValue(val))
	}
	return strings.Join(args, " ")
}

// ──────────────────────────────────────────────────────────── KV parser ──

// parseKVs parses audit field string: key=value key="quoted value" key=HEXSTRING ...
func parseKVs(s string) map[string]string {
	result := make(map[string]string)
	i := 0
	for i < len(s) {
		// skip whitespace
		for i < len(s) && s[i] == ' ' {
			i++
		}
		if i >= len(s) {
			break
		}

		// read key (up to '=')
		j := i
		for j < len(s) && s[j] != '=' && s[j] != ' ' {
			j++
		}
		if j >= len(s) || s[j] != '=' {
			break
		}
		key := s[i:j]
		i = j + 1

		// read value
		var val string
		if i < len(s) && s[i] == '"' {
			// quoted string
			i++ // skip opening quote
			start := i
			for i < len(s) {
				if s[i] == '"' {
					break
				}
				if s[i] == '\\' {
					i++ // skip escaped char
				}
				i++
			}
			val = s[start:i]
			val = strings.ReplaceAll(val, `\"`, `"`)
			val = strings.ReplaceAll(val, `\\`, `\`)
			if i < len(s) {
				i++ // skip closing quote
			}
			// store as-is (not re-quoted) so unquote() is not needed
			result[key] = val
		} else {
			// unquoted value – ends at next space
			start := i
			for i < len(s) && s[i] != ' ' {
				i++
			}
			val = s[start:i]
			result[key] = val
		}
	}
	return result
}

// ──────────────────────────────────────────────────────────── value helpers ──

// unquote removes surrounding double-quotes if present and unescapes interior.
// If the string was stored by parseKVs as already-unquoted, this is a no-op.
func unquote(s string) string {
	if len(s) >= 2 && s[0] == '"' && s[len(s)-1] == '"' {
		inner := s[1 : len(s)-1]
		inner = strings.ReplaceAll(inner, `\"`, `"`)
		inner = strings.ReplaceAll(inner, `\\`, `\`)
		return inner
	}
	return s
}

// decodeAuditValue handles hex-encoded values (all hex chars, even length).
func decodeAuditValue(s string) string {
	s = unquote(s)
	if isHexString(s) {
		if b, err := hex.DecodeString(s); err == nil {
			// Replace non-printable bytes with '?'
			for i, c := range b {
				if c == 0 {
					b[i] = ' '
				}
			}
			return strings.TrimRight(string(b), "\x00")
		}
	}
	return s
}

// isHexString returns true if s consists only of hex digits and has even length >= 2.
func isHexString(s string) bool {
	if len(s) < 2 || len(s)%2 != 0 {
		return false
	}
	for _, c := range s {
		if !unicode.Is(unicode.ASCII_Hex_Digit, c) {
			return false
		}
	}
	return true
}

// ──────────────────────────────────────────────────────────── user lookup ──

// lookupUID returns the username for a numeric uid by reading /etc/passwd.
// Falls back to the uid string itself on error.
func lookupUID(uid string) string {
	if uid == "" {
		return "unknown"
	}
	data, err := os.ReadFile("/etc/passwd")
	if err != nil {
		return uid
	}
	for _, line := range strings.Split(string(data), "\n") {
		parts := strings.Split(line, ":")
		if len(parts) >= 3 && parts[2] == uid {
			return parts[0]
		}
	}
	return uid
}
