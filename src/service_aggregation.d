module eudorina.service_aggregation;

import std.string;

import eudorina.io;
import eudorina.logging;
import eudorina.signal;


class ServiceAggregate {
public:
	EventDispatcher ed;
	SignalCatcher sc;
	SyncRunner sr;

	void setupED() {
		if (this.ed !is null) return;
		this.ed = new EventDispatcher();
	}
	void setupSR() {
		if (this.sr !is null) return;
		this.sr = new SyncRunner(this.ed);
	}
	void setupSC() {
		if (this.sc !is null) return;
		this.sc = new SignalCatcher(this.sr);
		void shutdown(SignalInfo *si) {
			log(20, format("Shutting down on signal: %s", *si));
			this.ed.shutdown = 1;
		}
		this.sc.setTermHandlers(&shutdown);
		this.sc.start();
		//this.sc._catchForever();
	}
	void setupDefaults() {
		this.setupED();
		this.setupSR();
		this.setupSC();
	}

	void runSync(td_io_callback cb) {
		this.sr.add(cb);
	}
}
