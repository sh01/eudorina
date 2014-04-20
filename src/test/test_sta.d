import std.stdio: writef;

import eudorina.text;
import eudorina.structured_text;

void pt0() {
	auto t = new ANSITable();
	writef("== Empty table: %s\n", cescape(t.getStr()));
	writef("== Lines:\n");
	auto l = t.add;
	l.add().fmt(CRed,null,true).add("lred text");
	l.add().fmt(CGreen,null,false,true).add("dgreen text");
	l.add().fmt(CYellow, CBlue, true).add("mixed colors").fmtReset();
	l = t.add();
	l.add().add("C0");
	l.add().add("C1");
	l.add().add("C2");
	l.add().add("C3");
	l.add().add("C4");

	writef("%s", t.getStr());
}

int main(string args[]) {
	pt0();
	return 0;
}
