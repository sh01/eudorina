import std.string;

import eudorina.text;
import eudorina.logging;
import eudorina.db.sqlit3;

pragma(lib, "sqlit3");
pragma(lib, "sqlite3");

auto runSql(SqliteConn c, string s) {
	log(20, format("Preparing statement: %s", cescape(s)));
	auto st = c.prepare(s);
	log(20, format("Evaluating: %s", st.step()));
	log(20, format(" Columns: %s", st.columnNames()));
	return st;
}

int main(string[] args) {
	SetupLogging();

	log(20, "Init.");
	log(20, "Opening DB connection.");
	auto c = new SqliteConn(":memory:");

	runSql(c, "CREATE TABLE ta0(a INTEGER PRIMARY KEY, b BLOB);");
	runSql(c, "INSERT INTO ta0(a,b) VALUES (42, \"foo\");");
	//auto s = runSql(c, "SELECT * FROM sqlite_master;");
	auto s = runSql(c, "SELECT a,b FROM ta0;");
	log(20, "Interrogating.");
	long v0;
	char[] v1;
	s.getRow(&v0, &v1);
	log(20, format("Values: %d %s", v0, v1));
	return 0;
}
