import std.string;

import eudorina.text;
import eudorina.logging;
import eudorina.db.sqlit3;

pragma(lib, "sqlit3");
pragma(lib, "sqlite3");

alias void delegate(SqliteStmt s) td_bind;

auto runSql(SqliteConn c, string s, td_bind b) {
	log(20, format("Preparing statement: %s", cescape(s)));
	auto st = c.prepare(s);
	log(20, format("Binding variables."));
	b(st);
	log(20, format("Evaluating: %s", st.step()));
	log(20, format(" Columns: %s", st.columnNames()));
	return st;
}

int main(string[] args) {
	SetupLogging();

	void d_noop(SqliteStmt s) { }
	void d_b0(SqliteStmt st) {
		string s0 = "f\"';oo";
		const(char)[] s1 = "bar";
		st.bind(42, s0, s1);
	}

	log(20, "Init.");
	log(20, "Opening DB connection.");
	auto c = new SqliteConn(":memory:");

	runSql(c, "CREATE TABLE ta0(a INTEGER PRIMARY KEY, b BLOB, c TEXT);", &d_noop);
	runSql(c, "INSERT INTO ta0(a,b,c) VALUES (?,?,?);", &d_b0);
	//auto s = runSql(c, "SELECT * FROM sqlite_master;");
	auto s = runSql(c, "SELECT a,b,c FROM ta0;", &d_noop);
	log(20, "Interrogating.");
	long v0;
	char[] v1;
	string v2;
	s.getRow(&v0, &v1, &v2);
	log(20, format("Values: %d %s %s", v0, v1, v2));
	return 0;
}
