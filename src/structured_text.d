import std.array: Appender, appender, join;
import std.exception: assumeUnique;
import std.format: to;
import std.string;


class TextFormat {
	const Color fg, bg;
	bool fg_b, reset;
	this(const Color fg, const Color bg = null, bool fg_b = false, bool reset = false) {
		this.fg = fg;
		this.bg = bg;
		this.fg_b = fg_b;
		this.reset = reset;
	}
	string asANSI() {
		char[][] codes = ["\x1b[".dup];
		if (this.reset) codes ~= "0".dup;
		if (this.fg_b) codes ~= "1".dup;
		if (this.fg !is null) codes ~= to!(char[])(30 + this.fg.code);
		if (this.bg !is null) codes ~= to!(char[])(40 + this.bg.code);

		char []cseq;
		if (codes.length > 1) {
			cseq = join(codes, ";");
			cseq ~= "m";
		}
		return assumeUnique(cseq);
	}
}

private class ANSICell {
	string[] text;
	size_t width;
	int colspan;
	this(int colspan = 1) {
		this.colspan = colspan;
	}
	ANSICell add(string text, size_t width = -1) {
		if (width == cast(size_t)-1) width=text.length;
		this.text ~= text;
		this.width += width;
		return this; // convenience: allow chaining
	}
	ANSICell add(S)(S text, size_t width = -1) {
		if (width == cast(size_t)-1) width = text.length;
		return this.add(to!string(text), width);
	}
	ANSICell addf(A...)(string fmt, A a) {
		string text = format(fmt, a);
		return this.add(text);
	}
	ANSICell setFmt(TextFormat fmt) {
		this.text ~= fmt.asANSI();
		return this; // convenience: allow chaning
	}
	ANSICell setFmt(A...)(A args) {
		auto fmt = new TextFormat(args);
		return this.setFmt(fmt);
	}
	ANSICell resetFmt() {
		return this.setFmt(null,null,false,true);
	}
}

private class PlainCell: ANSICell {
	this(A...)(A a) { super (a); }
	override ANSICell setFmt(TextFormat fmt) { return this; }
}

class ANSILine {
	int colspan;
	ANSICell[] cells;
	this() { }
	ANSICell add(CT, A...)(A a) {
		auto rv = new CT(a);
		this.cells ~= rv;
		return rv;
	}
	ANSICell add(int colspan = 1) {
		return this.add!ANSICell(colspan);
	}
}

private class PlainLine: ANSILine {
	override ANSICell add(int colspan = 1) {
		return ANSILine.add!(PlainCell)(colspan);
	}
}

import std.stdio;
class ANSITable {
	ANSILine[] lines;
	protected ANSILine _newLine() { return new ANSILine(); }
	ANSILine add() {
		ANSILine rv = _newLine;
		this.lines ~= rv;
		return rv;
	}
	void add(ANSILine l) {
		this.lines ~= l;
	}
	string[] getLines(string prefix = "", string infix = " ", string suffix = "") {
		size_t[] widths;
		int idx;
		foreach (l; this.lines) {
			idx = 0;
			foreach(c; l.cells) {
				if (widths.length <= idx+c.colspan) widths.length = idx+c.colspan+1;
				if ((c.colspan == 1) && (widths[idx] < c.width)) widths[idx] = c.width; // colspan widths are hard; ignoring this issue for now.
				idx += c.colspan;
			}
		}
		Appender!(string[]) table_text;
		Appender!(string[]) line_text;
		size_t w = 0;
		foreach (l; this.lines) {
			idx = 0;
			line_text = appender(cast(string[])[]);
			foreach(c; l.cells) {
				w = 0;
				int end = idx + c.colspan;
				for (; idx < end; idx++) w += widths[idx];
				if (c.width < w) line_text ~= format("%*s", w-c.width,"");
				line_text ~= c.text;
				line_text ~= infix;
			}
			line_text.shrinkTo(line_text.data.length-1); // Drop trailing infix
			table_text ~= prefix;
			table_text ~= line_text.data;
			table_text ~= suffix;
		}
		return table_text.data;
	}
	string getStr(string prefix = "", string infix = " ", string suffix = "\n") {
		return join(this.getLines(prefix, infix, suffix));
	}
}

class PlainTable: ANSITable {
	override protected ANSILine _newLine() { return new PlainLine(); }
}

//---------------------------------------------------------------- Color defs
alias static immutable(string[]) t_CM;

static class Color {
	int code;
	string name;
	t_CM CM = ["CBlack","CRed","CGreen","CYellow","CBlue","CMagenta","CCyan","CWhite"];
	this(int code) {
		this.code = code;
		this.name = this.CM[code];
	}
	override const string toString() {
		return this.name;
	}
}

static immutable(Color) _mc(int code) {
	return cast(immutable(Color))new Color(code);
};

immutable Color CBlack, CRed, CGreen, CYellow, CBlue, CMagenta, CCyan, CWhite;

static this() {
	CBlack = _mc(0);
	CRed = _mc(1);
	CGreen = _mc(2);
	CYellow = _mc(3);
	CBlue = _mc(4);
	CMagenta = _mc(5);
	CCyan = _mc(6);
	CWhite = _mc(7);
}

