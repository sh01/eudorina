import core.sys.posix.unistd;
import std.range;
import std.stdio;
import std.string;

import eudorina.logging;
import eudorina.io;
import eudorina.text;

void ping(EventDispatcher ed) {
	static string[] argv = ["ping", "-c", "8", "127.0.0.1"];
	auto sp = new SubProcess();

	sp.Spawn(argv);
	auto fd_o = ed.WrapFD(sp.fd_o, &ed.FailIO, &ed.FailIO);

	void Print() {
		char buf[1024];
		auto v = read(fd_o.fd, buf.ptr, 1024);
		if (v == 0) {
			fd_o.Close();
			ed.shutdown = true;
			return;
		}
		log(20, format("S: %s", cescape(buf[0..v])));
	}
	fd_o.SetCallbacks(&Print, &ed.FailIO);

	fd_o.AddIntent(IOI_READ);
}

int main() {
	SetupLogging();
	log(20, "Init.");
	auto ed = new EventDispatcher();
	ping(ed);
	ed.Run();
	log(20, "All done.");
	return 0;
}
