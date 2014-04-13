module eudorina.db.sqlite3;

import std.c.string;
public import etc.c.sqlite3;

import std.exception: assumeUnique;
import std.string;

import eudorina.logging;
import eudorina.text;

pragma(lib, "sqlite3");

// manually added sqlite3 defs
private extern (C) int sqlite3_close_v2(sqlite3*);

// Local D code.
class Sqlite3Error: Exception {
	this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null) {
		super(msg, file, line, next);
	};
}

/* This is /quite/ thread-unsafe. Going by the docs, making it safe would require locking out /all/ other sqlite3 function use in the meantime, though. Random internet rumors suggest instead that the memory is managed per-connection, and as long as those are not shared it's safe. For now, we won't add our own locking. */
private string getSqliteErrmsg(sqlite3 *db) {
	const char *c_err = sqlite3_errmsg(db);
	return c_err[0..strlen(c_err)].idup;
}

class SqliteConn {
	const char *fn_c;
	sqlite3 *db = null;

	this(string fn, int flags=SQLITE_OPEN_READWRITE) {
		fn_c = fn.toStringz();

		if (sqlite3_open_v2(fn_c, &db, flags, null) != SQLITE_OK) {
			string err = (db != null) ? getSqliteErrmsg(db) : "?OOM?";
			throw new Sqlite3Error(format("sqlite3_open_v2() failed: '%s'", cescape(err)));
		};
	}

	SqliteStmt prepare(string sql) {
		const char *sqlc = sql.ptr;
		const char *sqlc_end;
		sqlite3_stmt *s;
		if (sqlite3_prepare_v2(this.db, sqlc, cast(int)sql.length, &s, &sqlc_end) != SQLITE_OK)
			throw new Sqlite3Error(format("sqlite3_prepare_v2() failed: %s", cescape(getSqliteErrmsg(this.db))));

		auto rv = new SqliteStmt(this, s);
		if (sqlc_end != sqlc + sql.length)
			throw new Sqlite3Error(format("sqlite3_prepare() failed: %#x != %#x + %d", sqlc_end, sqlc, sql.length));

		return rv;
	}

	~this() {
		if (this.db == null) return;
		sqlite3_close_v2(db);
		db = null;
	}
}

class SqliteStmt {
	SqliteConn c;
	sqlite3_stmt *s;

	this(SqliteConn c, sqlite3_stmt *stmt) {
		this.c = c;
		this.s = stmt;
	}
	void reset() {
		sqlite3_reset(this.s);
	}
	bool step() {
		auto rc = sqlite3_step(this.s);
		switch (rc) {
		  case SQLITE_ROW: return true;
		  case SQLITE_OK: return false;
		  case SQLITE_DONE: return false;
		  default:
			  throw new Sqlite3Error(format("sqlite3_step() failed: %d; %s", rc, getSqliteErrmsg(this.c.db)));
		}
	}
	void getColumn(int col, int *v) {
		*v = sqlite3_column_int(this.s, col);
	}
	void getColumn(int col, long *v) {
		*v = sqlite3_column_int64(this.s, col);
	}
	void getColumn(int col, char[] *v) {
		auto c = cast(char*) sqlite3_column_blob(s, col);
		int l = sqlite3_column_bytes(s, col);
		v.length = l;
		if (l > 0) (*v)[] = c[0..l];
	}
	void getColumn(int col, const(char)[] *v) {
		char []buf;
		auto c = cast(char*) sqlite3_column_blob(s, col);
		int l = sqlite3_column_bytes(s, col);
		buf.length = l;
		if (l > 0) buf[] = c[0..l];
		*v = assumeUnique(buf);
	}
	void getColumn(int col, immutable(char)[] *v) {
		this.getColumn(col, cast(const(char)[]*)v);
	}
	void getRow(P...)(P p) {
		foreach (i, T; P) {
			this.getColumn(i, p[i]);
		}
	}
private:
	int _bindOne(int idx, const(char)[] v) {
		return sqlite3_bind_blob(this.s, idx, cast(void*)v.ptr, cast(int)v.length, SQLITE_TRANSIENT);
	}
	int _bindOne(int idx, int v) {
		return sqlite3_bind_int(this.s, idx, v);
	}
	int _bindOne(int idx, long v) {
		return sqlite3_bind_int64(this.s, idx, v);
	}
public:
	void bindOne(T)(int i, T t) {
		auto rc = this._bindOne(i, t);
		if (rc != SQLITE_OK) throw new Sqlite3Error(format("sqlite3_bind_*(%d...) failed: %d; %s", i, rc, getSqliteErrmsg(this.c.db)));
	}
	void bind(P...)(P p) {
		foreach (i, T; P) {
			this.bindOne(cast(int)i+1, p[i]);
		}
	}
	string[] columnNames() {
		int count = this.columnCount();
		string[] rv = new string[count];
		for (int i = 0; i < count; i++) {
			const char* cp = sqlite3_column_name(this.s, i);	
			rv[i] = cp[0..strlen(cp)].idup;
		}
		return rv;
	}

	int columnCount() {
		return sqlite3_column_count(this.s);
	}
	~this() {
		sqlite3_finalize(this.s);
	}
}
