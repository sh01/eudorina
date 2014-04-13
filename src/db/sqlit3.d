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

private {
	// Column readers
	alias void function(sqlite3_stmt*, int, void*) tf_colr;
	void colr_int(sqlite3_stmt *s, int col, void *v){
		*cast(int*)v = sqlite3_column_int(s, col);
	}
	void colr_int64(sqlite3_stmt *s, int col, void *v){
		*cast(long*)v = sqlite3_column_int64(s, col);
	}
	// void colr_val(sqlite3_stmt *s, int col, void *v) {
	// 	*cast(sqlite3_value**)v = sqlite3_column_value(s, col);
	// }
	void colr_blob(sqlite3_stmt *s, int col, void *v) {
		auto val = cast(char[]*)v;
	    auto c = cast(char*) sqlite3_column_blob(s, col);
		int l = sqlite3_column_bytes(s, col);
		(*val).length = l;
		if (l > 0) (*val)[] = c[0..l];
	}
	void colr_string(sqlite3_stmt *s, int col, void *v) {
		char []val;
		auto c = cast(char*) sqlite3_column_blob(s, col);
		int l = sqlite3_column_bytes(s, col);
		val.length = l;
		if (l > 0) val[] = c[0..l];
		*(cast(string*)v) = assumeUnique(val);
	}
	immutable tf_colr[TypeInfo] columnrs;
}

class SqliteStmt {
	SqliteConn c;
	sqlite3_stmt *s;

	this(SqliteConn c, sqlite3_stmt *stmt) {
		this.c = c;
		this.s = stmt;
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
	void getRow(P...)(P p) {
		foreach (i, T; P) {
			tf_colr cr = columnrs[typeid(T)];
			cr(this.s, i, cast(void*)p[i]);
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

shared static this() {
    tf_colr[TypeInfo] cr;
	cr[typeid(int*)] = &colr_int;
	cr[typeid(long*)] = &colr_int64;
	//cr[typeid(sqlite3_value*)] = &colr_val;
	cr[typeid(char[]*)] = &colr_blob;
	cr[typeid(string*)] = &colr_string;
	cr.rehash();
	columnrs = assumeUnique(cr);
}
