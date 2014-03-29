import core.sys.posix.unistd;
import core.time;
import core.stdc.errno;
import core.sys.posix.signal;

import std.c.process;
import std.c.stdlib: exit;
import std.getopt;
import std.range;
import std.stdio;
import std.string;

import core.sys.posix.signal;

import eudorina.service_aggregation;
import eudorina.logging;
import eudorina.io;
import eudorina.text;

void killself(int s) {
	if (kill(std.c.process.getpid(), s)) {
		throw new Exception(format("kill() -> errno == %d", errno));
	}	
}

void ping(ServiceAggregate sa, bool iofail) {
	static string[] argv = ["ping", "-c", "8", "127.0.0.1"];
	auto sp = new SubProcess();
	sp.Spawn(argv);

	auto fd_o = sa.ed.WrapFD(sp.fd_o, &sa.ed.FailIO, &sa.ed.FailIO);

	auto MakePrintFixed(string s) {
		void PrintFixed() {
			log(20, format("Timer: %s", s));
		}
		return &PrintFixed;
	}

	void Print() {
		char buf[1024];
		auto v = read(fd_o.fd, buf.ptr, 1024);
		if (v == 0) {
			fd_o.close();
			killself(SIGTERM);
			//sa.ed.shutdown = 1;
			return;
		}
		log(20, format("S: %s", cescape(buf[0..v])));
	}

	if (!iofail) fd_o.setCallbacks(&Print, &sa.ed.FailIO);
	fd_o.AddIntent(IOI_READ);

	auto tss = [2000,2200,2400,3000,3200,3400];
	foreach (i; tss) {
		auto d = dur!"msecs"(i);
		auto x = MakePrintFixed(format("+%d", i));
		sa.ed.NewTimer(x, d);
	}
}

int main(string[] args) {
	SetupLogging();
	bool iofail = false;
	getopt(
		args,
		"f|iofail", &iofail
	);

	log(20, "Init.");
	auto sa = new ServiceAggregate();
	sa.setupDefaults();
	killself(SIGHUP);

	ping(sa, iofail);
	sa.ed.Run();
	log(20, "All done.");
	return 0;
}
