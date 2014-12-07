module eudorina.io;

import core.stdc.errno;
import core.sys.posix.unistd; // close(), etc.
import core.sys.posix.fcntl;  // O_NONBLOCK
import core.sys.posix.pthread;
import core.sys.posix.stdlib; // pty stuff: posix_openpt, ptsname(), etc.
import core.sys.posix.sys.wait;
public import core.sys.posix.sys.wait: WNOHANG, WUNTRACED;
import core.time;

version (linux) {
	version (Linux) {
	} else {
		static assert(0, "Have 'linux' but not 'Linux' version flag. If compiling with gdc, add '-fversion=Linux'.");
	}
} else {
	static assert(0, "Cowardly refusing to compile linux-specific code without 'linux' version flag.");
}

import core.sys.linux.epoll;  // epoll stuff; need to compile with '-fversion=Linux' for gdc, though

import std.array;
import std.container;
import std.c.process;
static import std.c.stdlib;
static import std.process;
import std.stdint;
import std.string;

import core.stdc.stdio;

// Local D libs
import eudorina.logging;
import eudorina.text;

// C stuff
// unistd, missed above:
extern (C) int pipe2(int* pipefd, int flags);
private extern (C) extern const char** environ;

// Local D code.
class IoError: Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		super(msg, file, line, next);
	};
}

alias close close_;
alias int t_fd;
alias int t_pid;
alias int t_ioi;

alias int_fast64_t t_iots; //Time duration in millseconds

alias void delegate() td_io_callback;

struct t_fd_data {
	uint32_t events = 0;
	int flags = 0;
	td_io_callback cb_read, cb_write, cb_errclose;
}

// FD flag constants
immutable FDF_HAVE = 1;

// IO intent constants
immutable t_ioi IOI_READ = 1;
immutable t_ioi IOI_WRITE = 2;

private td_io_callback makeFail() {
	void FailIO() {
		throw new IoError(format("Invoked ErrorHandler()."));
	}
	return &FailIO;
}

class FD {
	EventDispatcher ed;
	t_fd fd = -1;

	this(EventDispatcher ed, t_fd fd) {
		this.ed = ed;
		this.fd = fd;
	}

	void AddIntent(t_ioi ioi) {
		this.ed.AddIntent(this.fd, ioi);
	}

	void DropIntent(t_ioi ioi) {
		this.ed.DropIntent(this.fd, ioi);
	}

	void setCallbacks(td_io_callback read = null, td_io_callback write = null) {
		this.ed.setCallbacks(this.fd, read, write);
	}

	void close() {
		if (this.fd < 0) return;
		log(20, format("FD(%d).close()", this.fd));
		this.ed.DelFD(this.fd);
		close_(this.fd);
		this.fd = -1;
	}
}

TickDuration _bumpFixedTS(TickDuration now, TickDuration delay) {
	uint_fast64_t fac = (now.to!("nsecs", uint_fast64_t)() / delay.to!("nsecs", uint_fast64_t)());
	return now.from!"nsecs"((fac + 1)*delay.to!("nsecs", uint_fast64_t));
}

class Timer {
	TickDuration fire_ts, delay;
	td_io_callback callback;
	bool active = true, align_, repeat;

	this(EventDispatcher ed, td_io_callback cb, TickDuration delay, TickDuration fire_ts, bool repeat, bool align_) {
		this.repeat = repeat;
		this.align_ = align_;
		this.callback = cb;
		this.delay = delay;
		this.fire_ts = fire_ts;
	}

	void stop() {
		this.active = false;
	}

	void fire() {
		this.callback();
	}

	bool bump() {
		if (!this.repeat) return false;
		auto now = TickDuration.currSystemTick();
		this.fire_ts = this.align_ ? _bumpFixedTS(now, this.delay) : now + this.delay;
		return true;
	}
}

private immutable string __tcmp = "a.fire_ts > b.fire_ts";
private alias BinaryHeap!(Array!(Timer), __tcmp) t_timers;

class EventDispatcher {
private:
	t_fd fd_epoll;
	t_fd_data[] fd_data;
	t_timers timers;
public:
	bool shutdown = false;

	this() {
		this.fd_epoll = epoll_create(1);
		this.fd_data.length = 32;
	}

	void FailIO() {
		throw new IoError(format("Invoked ErrorHandler()."));
	}

	void AddFD(t_fd fd, td_io_callback cb_read, td_io_callback cb_write) {
		auto tlen = this.fd_data.length;
		if (fd < 0) {
			core.stdc.stdlib.abort();
			throw new IoError(format("Attempted to add negative fd %d.", fd));
		}

		if (tlen <= fd) {
			while (tlen <= fd) tlen *= 2;
			this.fd_data.length = tlen;
		};
		t_fd_data *fdd = &this.fd_data[fd];
		if (fdd.flags & FDF_HAVE) {
			throw new IoError(format("Attempted to re-add fd %s.", fd));
		}
		fdd.events = 0;
		fdd.flags = FDF_HAVE;
		fdd.cb_read = cb_read;
		fdd.cb_write = cb_write;
		fdd.cb_errclose = &this.FailIO;
	}

	void setCallbacks(t_fd fd, td_io_callback cb_read = null, td_io_callback cb_write = null) {
		t_fd_data *fdd = &this.fd_data[fd];

		if (cb_read != null) fdd.cb_read = cb_read;
		if (cb_write != null) fdd.cb_write = cb_write;
	}

	void DelFD(t_fd fd) {
		auto fdd = &this.fd_data[fd];
		if (fdd.events) {
			epoll_event ee;
			epoll_ctl(this.fd_epoll, EPOLL_CTL_DEL, fd, &ee);
		}
		fdd.flags = 0;
		fdd.cb_read = &this.FailIO;
		fdd.cb_write = &this.FailIO;
		fdd.cb_errclose = &this.FailIO;
	}

	void AddIntent(t_fd fd, t_ioi ioi) {
		auto fdd = &this.fd_data[fd];
		auto ev = fdd.events;
		if (ioi & IOI_READ) ev |= EPOLLIN;
		if (ioi & IOI_WRITE) ev |= EPOLLOUT;
		
		if (ev == fdd.events) return; // no-op
		auto op = fdd.events ? EPOLL_CTL_MOD : EPOLL_CTL_ADD;
		fdd.events = ev;
		epoll_event ee;
		ee.events = ev;
		ee.data.fd = fd;
		epoll_ctl(this.fd_epoll, op, fd, &ee);
	}

	void DropIntent(t_fd fd, t_ioi ioi) {
		auto fdd = &this.fd_data[fd];
		auto ev = fdd.events;
		if (ioi & IOI_READ) ev &= ~EPOLLIN;
		if (ioi & IOI_WRITE) ev &= ~EPOLLOUT;
		
		if (ev == fdd.events) return; // no-op
		auto op = (ev == 0) ? EPOLL_CTL_DEL : EPOLL_CTL_MOD;
		fdd.events = ev;
		epoll_event ee;
		ee.events = ev;
		ee.data.fd = fd;
		epoll_ctl(this.fd_epoll, op, fd, &ee);
	}

	void Run(int eb_size = 128) {
		epoll_event[] eb_buf;
		eb_buf.length = eb_size;
		int eret;
		int i;
		t_fd_data *fdd;
		epoll_event* e, end;
		int timeout;
		TickDuration now;

		// Also call read func on EPOLLHUP, so we can use it to detect close conditions.
		immutable uint32_t EV_READ = EPOLLIN | EPOLLHUP;

		int[] fds_close;
		while (!this.shutdown) {
			if (this.timers.empty()) {
				timeout = -1;
			} else {
				now = TickDuration.currSystemTick();
				// This is inelegant, but ...
				// We can only specify a whole number of msecs as a timeout to epoll_wait().
				// Rounding the delay down is likely to result in several poll-only loops, where we specify a timeout of 0,
				// until the remaining fractional millisecond has passed and we can fire the timer.
				// So we add one to the timeout instead to avoid those no-event loop iterations.
				uint_fast64_t delay = (this.timers.front().fire_ts - now).to!("msecs", uint_fast64_t)() + 1;
				if (delay <= 0) {
					timeout = 0;
				} else if (delay > int.max) {
					timeout = int.max;
				} else {
					timeout = cast(int)delay;
				}
			}

			eret = epoll_wait(this.fd_epoll, &eb_buf[0], eb_size, timeout);
			if (eret < 0) {
				if (errno == EINTR) {
					continue;
				}
				throw new IoError(format("epoll_wait() rv: %s.", eret));
			}

			// Non-error case
			for (e = eb_buf.ptr, end = e + eret; e < end; e++) {
				fdd = &this.fd_data[e.data.fd];
				try {
					if (e.events & EV_READ) fdd.cb_read();
					if (e.events & EPOLLOUT) fdd.cb_write();
				} catch (Exception exc) {
					fds_close ~= e.data.fd;
					log(40, format("IO processing error on %s: %s", *fdd, format_exc(exc)));
				}
			}
			foreach (fd; fds_close) {
				fdd = &this.fd_data[fd];
				fdd.cb_errclose();
				if (fdd.flags) {
					log(50, format("cb_errclose ineffectiveness on %s.", fdd));
					throw new IoError("Ineffective cb_errclose.");
				}
			}
			// Timer processing
			now = TickDuration.currSystemTick();
			while (!this.timers.empty()) {
				auto t = this.timers.front();
				// We could update now() here and check again if the first one fails; but mostly that would just decrease efficiency.
				// If we're so starved that one more FD poll iteration will make us fall behind, things have gone to hell already.
				if (t.fire_ts > now) break;

				this.timers.removeFront();
				if (!t.active) continue;

				bool repeat = false;
				try {
					t.fire();
				} catch (Exception exc) {
					log(40, format("Timer fire error: %s; force stopping.", format_exc(exc)));
				}
				if (t.bump()) {
					this.timers.insert(t);
				}
			}
		}
	}

	FD WrapFD(t_fd fd, td_io_callback cb_read = makeFail(), td_io_callback cb_write = makeFail()) {
		this.AddFD(fd, cb_read, cb_write);
		auto rv = new FD(this, fd);
		this.fd_data[fd].cb_errclose = &rv.close;
		return rv;
	}

	void AddTimer(Timer timer) {
		this.timers.insert(timer);
	}

	Timer NewTimer(td_io_callback cb, Duration delay, bool repeat=false, bool align_=false) {
		auto now = TickDuration.currSystemTick();

		auto td = TickDuration.from!"nsecs"(delay.total!"nsecs"());
		auto fire_ts = align_ ? _bumpFixedTS(now, td) : now + td;

		auto rv = new Timer(this, cb, td, fire_ts, repeat, align_);
		this.AddTimer(rv);
		return rv;
	}
}


void makePipe(t_fd *rfd, t_fd *wfd, int flags = 0) {
	int[2] pipefd;
	if (int ret = pipe2(&pipefd[0], flags)) {
		throw new IoError(format("pipe2() -> %d.", ret));
	}
	*rfd = pipefd[0];
	*wfd = pipefd[1];
}

class SyncRunner {
private:
	t_fd fdw;
	FD fdr;
	DList!td_io_callback cbs;
	char[] buf;
	pthread_mutex_t mut;
	
public:
	this(EventDispatcher ed) {
		if (pthread_mutex_init(&this.mut, null) != 0) {
			throw new IoError(format("pthread_mutex_init() -> errno == %d", errno));
		};
		this.buf.length = 65536;
		t_fd fdr;
		makePipe(&fdr, &this.fdw, O_NONBLOCK);
		this.fdr = ed.WrapFD(fdr, &this._handleEvents);
		this.fdr.AddIntent(IOI_READ);
	}
	~this() {
		this.fdr.close();
		this.fdr = null;
		close(this.fdw);
	}
	void _handleEvents() {
		read(this.fdr.fd, this.buf.ptr, this.buf.length);

		DList!td_io_callback cbs;
		{
			pthread_mutex_lock(&this.mut);
			scope(exit) pthread_mutex_unlock(&this.mut);
			cbs = this.cbs;
			this.cbs = DList!td_io_callback();
		}
		foreach (cb; cbs) cb();
	}
	void add(td_io_callback cb) {
		{
			pthread_mutex_lock(&this.mut);
			scope(exit) pthread_mutex_unlock(&this.mut);
			this.cbs.insertBack(cb);
		}
		write(this.fdw, "\x00".ptr, 1);
	}
}


class BufferWriter {
private:
	auto bufs = DList!(const(char)[])();
public:
	FD fd;
	this(FD fd) {
		this.fd = fd;
	}
	this (EventDispatcher ed, t_fd fd, td_io_callback cb_read = makeFail()) {
		if (cb_read == null) cb_read = &ed.FailIO;
		this.fd = ed.WrapFD(fd, cb_read, &this.handleWritability);
	}

	// Attempt to push buffered data out through FD.
	void push() {
		while (!this.bufs.empty()) {
			auto buf = this.bufs.front();
			ssize_t count = core.sys.posix.unistd.write(this.fd.fd, buf.ptr, buf.length);
			if (count == -1) {
				// Didn't write anything. Check if this was just a nonblocking can't-write return:
				// D is very silly here, refusing switch cases with duplicated aliased match-values, so we can't just throw EAGAIN and EWOULDBLOCK in one. We should look into its compile-time execution features instead.
				if ((errno == EAGAIN) || (errno == EWOULDBLOCK)) {
					break;
				}
				throw new IoError(format("BufferWriter(%d)::push() -> %d", this.fd.fd, errno));
			}
			// Otherwise, don't read from exactly the same buffer again.
			this.bufs.removeFront();
			if (buf.length < count) {
				// Partial write. Resize buffer we read from, reinsert it, and break.
				this.bufs.insertFront(buf[count..buf.length]);
				break;
			}
			// Full write; continue with next element.
		}
	}

	void handleWritability() {
		this.push();
		if (this.bufs.empty()) {
			// Out of stuff to write for now; record this so we don't immediately get called again.
			this.fd.DropIntent(IOI_WRITE);
		}
	}

	void write(const(char)[] buf) {
		bool was_empty = this.bufs.empty();
		this.bufs.insertBack(buf);
		if (was_empty) {
			// Try to write it immediately; there might be enough space in the kernel buffer for it to suceed, and if so we don't need to do the FD EPOLLOUT register/unregister dance.
			this.push();
			if (!this.bufs.empty()) this.fd.AddIntent(IOI_WRITE);
		}
	}
}

char*[] toStringzA(string[] data) {
	char*[] rv = uninitializedArray!(char*[])(data.length+1);

	size_t i = 0;
	foreach (s; data) {
		rv[i++] = cast(char*)toStringz(s);
	}
	rv[i] = cast(char*)0;
	return rv;
}

private void checkErr(bool err, string msg,) {
	if (!err) return;
	throw new IoError(format(msg, errno));
}

enum StdFd {
	IN = 1,
	OUT = 2,
	ERR = 4
};

class SubProcess {
public:
	t_pid pid = -1;

	t_fd fd_i = -1, fd_o = -1, fd_e = -1;
	t_fd[] fds_close;

	private void checkUnspawned() {
		if (this.pid >= 0) {
			throw new IoError("I've already spawned.");
		}
	}

	int waitPid(int *out_ = null, int options = 0) {
		return core.sys.posix.sys.wait.waitpid(this.pid, out_, options);
	}
	void kill(int signal=15) {
		core.sys.posix.signal.kill(this.pid, signal);
	}

	void Spawn(string[]argv, const char **env = environ) {
		this.checkUnspawned();

		if (argv.length < 1) {
			throw new IoError(format("Invalid argv %s.", argv));
		}

		int[] fds_close;
		scope(exit) {
			foreach (int fd; fds_close) close(fd);
			foreach (int fd; this.fds_close) close(fd);
			this.fds_close.length = 0;
		}
		t_fd fd_ic, fd_oc, fd_ec;

		if (this.fd_i == -1) {
			makePipe(&fd_ic, &this.fd_i);
			fcntl(this.fd_i, F_SETFL, O_NONBLOCK);
			fds_close ~= fd_ic;
		} else { fd_ic = this.fd_i; this.fd_i = -1; };

		if (this.fd_o == -1) {
			makePipe(&this.fd_o, &fd_oc);
			fcntl(this.fd_o, F_SETFL, O_NONBLOCK);
			fds_close ~= fd_oc;
		} else { fd_oc = this.fd_o; this.fd_o = -1; };

		if (this.fd_e == -1) {
			makePipe(&this.fd_e, &fd_ec);
			fcntl(this.fd_e, F_SETFL, O_NONBLOCK);
			fds_close ~= fd_ec;
		} else { fd_ec = this.fd_e; this.fd_e = -1; };

		t_pid pid = fork();
		
		if (pid == -1) {
			// Error
			int err = errno;
			close(fd_ic);
			close(fd_oc);
			close(fd_ec);
			if (this.fd_i >= 0) {
				close(this.fd_i);
				this.fd_i = -1;
			}
			if (this.fd_o >= 0) {
				close(this.fd_o);
				this.fd_o = -1;
			}
			if (this.fd_e >= 0) {
				close(this.fd_e);
				this.fd_e = -1;
			}
			throw new IoError(format("fork() -> -1 (%d)", err));
		}

		if (pid == 0) {
			// Child
			if ((dup2(fd_ic, 0) == 1) || (dup2(fd_oc, 1) == -1) || (dup2(fd_ec, 2) == -1)) {
				// Not likely.
				throw new IoError("Post-fork dup2() failed.");
			}

			auto c_argv = toStringzA(argv);
			int rc = execvpe(c_argv[0], c_argv.ptr, env);
			perror("execvpe");
			std.c.stdlib.exit(100);
		}
		// Parent.
		this.pid = pid;
	}

	t_fd*[] getFds(int fdmask) @safe {
		t_fd*[] rv;
		if (fdmask & StdFd.IN) rv ~= &this.fd_i;
		if (fdmask & StdFd.OUT) rv ~= &this.fd_o;
		if (fdmask & StdFd.ERR) rv ~= &this.fd_e;
		return rv;
	}

	// Create a new master/slave pty pair, setting the slave side up for the subprocess's stdout and stdin.
	//  Returns the fd for the (new) master side on success.
	//  Else throws IoError.
	t_fd setupPty(int fdmask, int flags = O_NOCTTY) {
		this.checkUnspawned();
		auto fds = this.getFds(fdmask);
		if (fds.length == 0) throw new IoError("No-op.");

		foreach (fd; fds) {
			if (*fd != -1) throw new IoError("Target FDs are not free.");
		}

		t_fd fd_master, fd_slave;
		makePty(&fd_master, &fd_slave, flags);
		scope (failure) {
			close(fd_master);
			close(fd_slave);
		}
		foreach (fd; fds) {
			*fd = fd_slave;
		}
		this.fds_close ~= fd_slave;
		return fd_master;
	}
}

void makePty(t_fd *master, t_fd *slave, int flags) {
	*master = posix_openpt(O_RDWR|flags);
	checkErr(*master < 0, "PTY master open failed: %d");
	scope (failure) {
		close(*master);
	}
	checkErr(grantpt(*master) != 0, "grantpt() failed: %d");
	checkErr(unlockpt(*master) != 0, "unlockpt() failed:%d");
	// Not threadsafe. I think we'll live.
	char *slave_fn = ptsname(*master);
	checkErr(slave_fn == null, "ptsname() failed: %d");
	*slave = open(slave_fn, O_RDWR);
	checkErr(*slave < 0, "PTY slave open failed: %d");	
}
