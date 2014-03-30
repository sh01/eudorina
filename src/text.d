module eudorina.text;

import std.conv;
import std.exception;
import std.string;
import std.uni;

string cescape(const char[] s) @trusted {
	char rv[];
	size_t idx = 0;

	rv ~= "\"";

	void add_esc(dchar c) {
		if (c <= 0x7F) {
			rv ~= format("\\x%02x", c);
			return;
		}
		rv ~= format("\\u%04x", c);
	}

	foreach (c; s) {
		switch (c) {
		  case '\n':
		      rv ~= "\\n";
		      break;
		  case '\t':
	          rv ~= "\t";
		      break;
		  case ' ':
		      rv ~= ' ';
		      break;
		  case '"':
		      rv ~= "\"";
		      break;
		  default:
			  if (isGraphical(c) && !isWhite(c)) {
				  rv ~= c;
			  } else {
				  add_esc(c);
			  }
		}
	}
	rv ~= '"';
	return assumeUnique(rv);
}

string format_exc(Throwable e) {
	return format("[%s:%d]:%s  %s", e.file, e.line, cescape(to!(char[])(e.msg)), cescape(to!(char[])(e.info)));
}
