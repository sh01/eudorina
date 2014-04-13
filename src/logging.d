module eudorina.logging;

import core.sys.posix.unistd;

import std.datetime;
import std.stdio;
import std.string;

immutable long TS_UNKNOWN = 0x7FFFFFFFFFFFFFFFL;

alias int Severity;

class LogEntry {
	Severity severity;
	long ts; // StdTime in hnsecs since DE
	string file;
	size_t line;
	string msg;
	nothrow this(Severity s, string msg, long ts = TS_UNKNOWN, string file = __FILE__, size_t line = __LINE__) @safe {
		if (ts == TS_UNKNOWN) {
			try {
				ts = Clock.currStdTime();
			} catch (Exception e) { }
		}
		this.severity = s;
		this.msg = msg;
		this.file = file;
		this.line = line;
		this.ts = ts;
	}
}

interface LogWriter {
	void write(LogEntry e) @safe;
}

class Logger {
	long lost_entries = 0;
	LogWriter writers[];

	void add_writer(LogWriter w) {
		this.writers ~= w;
		this.log(20, format("Added LogWriter %s. Lost %d log entries before now.", w, this.lost_entries));
	}

	nothrow void log(LogEntry e) @safe {
		auto succ = false;
		foreach (w; this.writers) {
			try {
				w.write(e);
			} catch (Exception e) {
				continue;
			}
			succ = true;
		}
		if (!succ) {
			lost_entries += 1;
		}
	}

	nothrow void log(int severity, string msg, long ts = TS_UNKNOWN, string file = __FILE__, size_t line = __LINE__) @safe {
		auto le = new LogEntry(severity, msg, ts, file, line);
		this.log(le);
	}
	void logf(Severity, string, Args...)(int severity, string fmt, Args args) {
		auto le = new LogEntry(severity, format(fmt, args));
		this.log(le);
	}
}

__gshared Logger stdLogger;

void log(Severity severity, string msg, long ts = TS_UNKNOWN, string file = __FILE__, size_t line = __LINE__) @trusted {
	stdLogger.log(severity, msg, ts, file, line);
}
void logf(Severity, string, Args...) (Severity severity, string fmt, Args args) {
	stdLogger.logf!(Severity, string, Args)(severity, fmt, args);
}

class TextFDWriter : LogWriter {
	int fd;
	Severity min_severity;
	immutable(TimeZone) *tz;

	this(Severity min_s, int fd, immutable(TimeZone) *tz = null) {
		this.fd = fd;
		this.min_severity = min_s;
		if (tz == null) {
			immutable(TimeZone) tz_ = LocalTime();
			tz = &tz_;
		}
		this.tz = tz;
	}

	string _format(LogEntry e) @trusted {
		// SysTime does a /etc/localtime stat for any access to its .year .second .fracSec etc. members.
		// To reduce the number of syscalls for a log message, instead of using those members we convert it to a TM here and rip its fractional seconds out separetly.
		// auto st = new SysTime(e.ts, *this.tz); -- doesn't work. Why?
		auto st = new SysTime(e.ts);
		auto tm = st.toTM();
		auto hnusec = (st.stdTime()/1000) % 10000;
		return format("%04d-%02d-%02d_%02d:%02d:%02d.%04d %02d [%s:%s] %s\n",
		  tm.tm_year, tm.tm_mon, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, hnusec,
		  e.severity, e.file, e.line, e.msg);
	}

	void write(LogEntry e) @trusted {
		auto l = this._format(e);
		long rc = core.sys.posix.unistd.write(this.fd, l.ptr, l.length);
		if (rc != l.length) throw new Exception(format("write() -> %d != %d", rc, l.length));
	}
}

void SetupLogging(Severity min_s = 10, int fd = 2) {
	stdLogger.add_writer(new TextFDWriter(min_s, fd));
}

shared static this() {
	stdLogger = new Logger();
}
