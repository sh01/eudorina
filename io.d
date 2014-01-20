import core.stdc.errno;

import std.stdint;
import std.string;
static import object;

// Stuff derived from epoll.h
// There is also import core.sys.linux.epoll, but we don't get the version->'Linux' declaration from gdc by default.

extern (C) int epoll_create(t_fd size);
extern (C) int epoll_ctl(t_fd epfd, int op, t_fd fd, epoll_event *event);
extern (C) int epoll_wait(int epfd, epoll_event *events, int maxevents, int timeout);

immutable EPOLLIN = 0x001;
immutable EPOLLOUT = 0x004;

immutable EPOLL_CTL_ADD = 1;
immutable EPOLL_CTL_DEL = 2;
immutable EPOLL_CTL_MOD = 3;

// Local D code.
class IoError: object.Error {
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null);
}

union epoll_data_t {
	void	   *ptr;
	int	   fd;
	uint32_t   u32;
	uint64_t   u64;
};

struct epoll_event {
	uint32_t	events;	// Epoll events
	epoll_data_t	data;	// User data variable
};

alias int t_fd;
alias int t_ioi;

alias void delegate() td_io_callback;

class t_fd_data {
	uint32_t events = 0;
	int flags = 0;
	td_io_callback cb_read, cb_write;
}

// FD flag constants
immutable FDF_HAVE = 1;

// IO intent constants
immutable t_ioi IOI_READ = 1;
immutable t_ioi IOI_WRITE = 2;

class EventDispatcher {
	t_fd fd_epoll;
	t_fd_data[] fd_data;
	this() {
		this.fd_epoll = epoll_create(1);
		this.fd_data.length = 32;
	}

	void AddFd(t_fd fd, td_io_callback cb_read, td_io_callback cb_write) {
		auto tlen = this.fd_data.length;
		if (tlen <= fd) {
			while (tlen <= fd) tlen *= 2;
			this.fd_data.length = tlen;
		};
		auto fdd = &this.fd_data[fd];
		if (fdd.flags & FDF_HAVE) {
			throw new IoError(format("Attempted to re-add fd %s.", fd));
		}
		fdd.events = 0;
		fdd.flags = FDF_HAVE;
		fdd.cb_read = cb_read;
		fdd.cb_write = cb_write;
	}

	void AddIntent(t_fd fd, t_ioi ioi) {
		auto fdd = &this.fd_data[fd];
		auto ev = fdd.events;
		if (ioi & IOI_READ) ev |= EPOLLIN;
		if (ioi & IOI_WRITE) ev |= EPOLLOUT;
		
		if (ev == fdd.events) return; // no-op
	   	auto op = (fdd.events == 0) ? EPOLL_CTL_ADD : EPOLL_CTL_MOD;
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
		t_fd_data fdd;
		epoll_event* e, end;
		while (1) {
			eret = epoll_wait(this.fd_epoll, &eb_buf[0], eb_size, -1);
			if (eret < 0) {
				if (errno == EINTR) {
					continue;
				}
				throw new IoError(format("epoll_wait() rv: %s.", eret));
			}

			// Non-error case
			for (e = &eb_buf[0], end = e + eret; e < end; e++) {
				fdd = this.fd_data[e.data.fd];
				if (e.events & EPOLLIN) fdd.cb_read();
				if (e.events & EPOLLOUT) fdd.cb_write();
			}
		}
	}
}

class FD {
	EventDispatcher *ed;
	t_fd fd;
}

