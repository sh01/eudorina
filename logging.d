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

	nothrow log(LogEntry e) @safe {
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

	nothrow log(int severity, string msg, long ts = TS_UNKNOWN, string file = __FILE__, size_t line = __LINE__) @safe {
		auto le = new LogEntry(severity, msg, ts, file, line);
		this.log(le);
	}
}

Logger stdLogger;

void log(Severity severity, string msg, long ts = TS_UNKNOWN, string file = __FILE__, size_t line = __LINE__) @safe {
	stdLogger.log(severity, msg, ts, file, line);
}

class TextFDWriter : LogWriter {
	int fd;
	Severity min_severity;
	this(Severity min_s, int fd) {
		this.fd = fd;
		this.min_severity = min_s;
	}

	string _format(LogEntry e) @trusted {
		auto st = new SysTime(e.ts);
		return format("%04d-%02d-%02d_%02d:%02d:%02d.%04d %02d [%s:%s] %s\n",
		  st.year, st.month, st.day, st.hour, st.minute, st.second, st.fracSec.msecs,
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
