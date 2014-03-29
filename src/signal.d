module eudorina.signal;

import core.stdc.errno;
import core.stdc.stdlib;
import core.sys.posix.pthread;
import core.sys.posix.signal;
import core.thread;

import std.container;
import std.string;

import eudorina.io;
import eudorina.logging;

class SignalError: Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		super(msg, file, line, next);
	};
}

immutable int COUNT_SIGNALS;

class SignalInfo {
	siginfo_t i;
	override string toString() @trusted {
		return format("SignalInfo(<%d; %d, %d; source %d, %d>)",
			   i.si_signo,
			   i.si_errno, i.si_code,
			   i.si_pid, i.si_uid);
	}
}

alias void delegate(SignalInfo*) td_sig_cb;

class SignalCatcher {
private:
	pthread_mutex_t mut;
	t_fd fd; // signal pipe FDs
	DList!SignalInfo[] signals0, signals1, sx;
	td_sig_cb[] handlers;
public:
	SyncRunner sr;
	shared sigset_t set;
	Thread *catch_thread = null;

	this(SyncRunner sr) {
		if (pthread_mutex_init(&this.mut, null) != 0) {
			throw new SignalError(format("pthread_mutex_init() -> errno == %d", errno));
		};
		this.sr = sr;
		this.signals0.length = COUNT_SIGNALS;
		this.signals1.length = COUNT_SIGNALS;
		this.handlers.length = COUNT_SIGNALS;
		// This should be a reasonable default: Catch everything we possibly can, except for abort which
		// (will get through if raised from abort() in any case and) is not particularly useful to block or re-purpose.
		// Nevertheless, a class user is free to modify this before calling start().
		sigemptyset(cast(sigset_t*)&this.set);
		this.setDefaultHandlers();
	}

	void setHandler(int signal, td_sig_cb handler) {
		this.handlers[signal] = handler;
		sigaddset(cast(sigset_t*)&this.set, signal);
	}

	void _log(SignalInfo *si) {
		log(20, format("Caught signal: %s", *si));
	}

	void setTermHandlers(td_sig_cb cb) {
		foreach (int i; [SIGINT, SIGILL, SIGFPE, SIGPIPE, SIGALRM, SIGTERM]) {
			this.setHandler(i, cb);
		}
	}

	void setDefaultHandlers() {
		foreach (i; [SIGHUP, SIGUSR1, SIGUSR2]) {
			this.setHandler(i, &this._log);
		}
	}

	void start() {
		if (this.catch_thread != null) {
			throw new SignalError("I've already been started.");
		}
		auto rc = pthread_sigmask(SIG_BLOCK, cast(sigset_t*)&this.set, null);
		if (rc != 0) {
			throw new SignalError(format("pthread_sigmask() -> errno == %d", errno));
		}
		auto thread = new Thread(&this._catchForever);
		this.catch_thread = &thread;
		thread.name("signal_catcher");
		thread.isDaemon(true);
		this.catch_thread.start();
	}

	void _runHandlers() {
		{
			pthread_mutex_lock(&this.mut);
			scope(exit) pthread_mutex_unlock(&this.mut);
			sx = signals0;
			signals0 = signals1;
			signals1 = sx;
		}

		int i;
		DList!SignalInfo l;
		td_sig_cb h;
		for (i = 0; i < COUNT_SIGNALS; i++) {
			l = this.signals1[i];
			if (l.empty()) continue;
			h = this.handlers[i];
			foreach (si; l) h(&si);
		}

		{
			pthread_mutex_lock(&this.mut);
			scope(exit) pthread_mutex_unlock(&this.mut);
			sx = signals0;
			signals0 = signals1;
			signals1 = sx;
		}

		for (i = 0; i < COUNT_SIGNALS; i++) {
			l = this.signals1[i];
			if (l.empty()) continue;
			h = this.handlers[i];
			foreach (si; l) h(&si);
		}
	}

	void _catchForever() {
		int rc;
		timespec ts_zero = {0, 0};
		SignalInfo si;

		//si = new SignalInfo();
		while (true) {
			si = new SignalInfo();
			rc = sigwaitinfo(cast(sigset_t*)&this.set, &si.i);
			if (rc < 0) { // Can't happen. Probably.
				abort();
			}
			pthread_mutex_lock(&this.mut);
			scope(exit) pthread_mutex_unlock(&this.mut);
			if (si.i.si_signo >= this.signals0.length) {
				log(20, format("Got out-of-range signal %d.", si.i.si_signo));
				abort();
			}
			auto s = this.signals0[si.i.si_signo];
			this.signals0[si.i.si_signo].insertBack(si);

			// // Potentially silly micro-optimization(?)s commented out for now.
			// // This reads backwards, but is written this way for performance and should be correct.
			// // New si allocation happens just before we need it, and the last allocated and unused one is used for the next outer-loop run.
			// while (true) {
			// 	auto queue = signals[si.i.si_signo];
			// 	queue.insertBack(si);
			// 	si = new SignalInfo();
			// 	rc = sigtimedwait(cast(sigset_t*)&this.set, &si.i, &ts_zero);
			// 	if (rc < 0) {
			// 		if (errno == EAGAIN) break;
			// 		abort(); // Can't happen. Probably.
			// 	}
			// }
			this.sr.add(&this._runHandlers);
		}
	}
}

static int getSignalCount() {
	sigset_t s;
	int i;
	for (i = 1; sigismember(&s, i) >= 0; i++) {};
	return i;
}

shared static this() {
	COUNT_SIGNALS = getSignalCount();
}
