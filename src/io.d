module eudorina.io;

import core.stdc.errno;
import core.sys.posix.unistd; // close(), etc.
import core.sys.posix.fcntl;  // O_NONBLOCK

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
import std.c.process;
static import std.process;
import std.stdint;
import std.stdio;
import std.string;

import core.stdc.stdio;

// Local D libs
import eudorina.logging;
import eudorina.text;

// C stuff
// unistd, missed above:
extern (C) int pipe2(int* pipefd, int flags);
extern (C) const char** environ;

// Local D code.
class IoError: Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		super(msg, file, line, next);
	};
}

alias int t_fd;
alias int t_pid;
alias int t_ioi;

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

	void SetCallbacks(td_io_callback cb_read, td_io_callback cb_write) {
		this.ed.SetCallbacks(this.fd, cb_read, cb_write);
	}

	void Close() {
		if (!this.fd < 0) return;
		this.ed.DelFD(this.fd);
		close(this.fd);
		this.fd = -1;
	}
}

class EventDispatcher {
	t_fd fd_epoll;
	t_fd_data[] fd_data;
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

	void SetCallbacks(t_fd fd, td_io_callback cb_read, td_io_callback cb_write) {
		t_fd_data *fdd = &this.fd_data[fd];
		fdd.cb_read = cb_read;
		fdd.cb_write = cb_write;
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

		// Also call read func on EPOLLHUP, so we can use it to detect close conditions.
		immutable uint32_t EV_READ = EPOLLIN | EPOLLHUP;

		int[] fds_close;
		while (!this.shutdown) {
			eret = epoll_wait(this.fd_epoll, &eb_buf[0], eb_size, -1);
			if (eret < 0) {
				if (errno == EINTR) {
					continue;
				}
				throw new IoError(format("epoll_wait() rv: %s.", eret));
			}

			// Non-error case
			for (e = &eb_buf[0], end = e + eret; e < end; e++) {
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
		}
	}

	FD WrapFD(t_fd fd, td_io_callback cb_read, td_io_callback cb_write) {
		this.AddFD(fd, cb_read, cb_write);
		auto rv = new FD(this, fd);
		this.fd_data[fd].cb_errclose = &rv.Close;
		return rv;
	}
}

void makePipe(t_fd *rfd, t_fd *wfd, int flags = O_NONBLOCK) {
	int[2] pipefd;
	if (int ret = pipe2(&pipefd[0], flags)) {
		throw new IoError(format("pipe2() -> %d.", ret));
	}
	*rfd = pipefd[0];
	*wfd = pipefd[1];
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

class SubProcess {
public:
	t_pid pid = -1;

    t_fd fd_i = -1, fd_o = -1, fd_e = -1;
	void Spawn(string[]argv, const char **env = environ) {
		if (this.pid >= 0) {
			throw new IoError("I've already spawned.");
		}

		if (argv.length < 1) {
			throw new IoError(format("Invalid argv %s.", argv));
		}

		int[] fds_close;
		scope(exit) {
			foreach (int fd; fds_close) close(fd);
		}
		t_fd fd_ic, fd_oc, fd_ec;

		if (this.fd_i == -1) {
			makePipe(&fd_ic, &this.fd_i);
			fds_close ~= fd_ic;
			scope(failure) {
				close(this.fd_i);
				this.fd_i = -1;
			}
		} else { fd_ic = this.fd_i; this.fd_i = -1; };

		if (this.fd_o == -1) {
			makePipe(&this.fd_o, &fd_oc);
			fds_close ~= fd_oc;
			scope(failure) {
				close(this.fd_o);
				this.fd_o = -1;
			}
		} else { fd_oc = this.fd_o; this.fd_o = -1; };

		if (this.fd_e == -1) {
			makePipe(&this.fd_e, &fd_ec);
			fds_close ~= fd_ec;
			scope(failure) {
				close(this.fd_e);
				this.fd_e = -1;
			}
		} else { fd_ec = this.fd_e; this.fd_e = -1; };

		t_pid pid = fork();
		
		if (pid == -1) {
			// Error
			int err = errno;
			close(fd_ic);
			close(fd_oc);
			close(fd_ec);
			if (this.fd_i >= 0) close(this.fd_i);
			if (this.fd_o >= 0) close(this.fd_o);
			if (this.fd_e >= 0) close(this.fd_e);
			throw new IoError(format("fork() -> -1 (%d)", err));
		} 

		if (pid == 0) {
			// Child
			if ((dup2(fd_ic, 0) == 1) || (dup2(fd_oc, 1) == -1) || (dup2(fd_ec, 2) == -1)) {
				// Not likely.
				throw new IoError("Post-fork dup2() failed.");
			}
			auto c_argv = toStringzA(argv);
			execvpe(c_argv[0], c_argv.ptr, env);
		}
		// Parent.
		this.pid = pid;
	}
}