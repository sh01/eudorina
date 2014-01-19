import std.stdint;
import std.string;
static import object;

// Stuff derived from epoll.h
extern (C) int epoll_create(t_fd size);
extern (C) int epoll_ctl(t_fd epfd, int op, t_fd fd, epoll_event *event);

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

class t_fd_data {
	uint32_t events = 0;
	int flags = 0;
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
	void AddFd(t_fd fd) {
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
	}
    void AddIntent(t_fd fd, t_ioi ioi) {
		auto fdd = &this.fd_data[fd];
		auto ev = fdd.events;
		if (ioi & IOI_READ) ev |= EPOLLIN;
		if (ioi & IOI_WRITE) ev |= EPOLLOUT;
		
		if (ev != fdd.events) {
			auto op = (fdd.events == 0) ? EPOLL_CTL_ADD : EPOLL_CTL_MOD;
			fdd.events = ev;
			epoll_event ee;
			ee.events = ev;
			ee.data.fd = fd;
			epoll_ctl(this.fd_epoll, op, fd, &ee);
		}
	}
}

class FD {
	EventDispatcher *ed;
	t_fd fd;
}

