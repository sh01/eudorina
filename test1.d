import io;

void ping(EventDispatcher ed) {
	static string[] argv = ["ping", "-c", "8", "127.0.0.1"];
	auto sp = new SubProcess();

	sp.Spawn(argv);
	ed.WrapFD(sp.fd_i, &ed.FailIO, &ed.FailIO);
}

int main() {
	auto ed = new EventDispatcher();
	ping(ed);
	return 0;
}
