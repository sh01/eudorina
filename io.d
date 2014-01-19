import std.stdint;

union epoll_data_t {
	void        *ptr;
	int          fd;
	uint32_t     u32;
	uint64_t     u64;
};

struct epoll_event {
       uint32_t     events;      /* Epoll events */
       epoll_data_t data;        /* User data variable */
};

alias int t_fd;

extern (C) int epoll_create(t_fd size);
extern (C) int epoll_ctl(t_fd epfd, int op, t_fd fd, epoll_event *event);

