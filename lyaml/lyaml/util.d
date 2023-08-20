module lyaml.util;

import std.conv;

auto toStr(T)(T x) {
	static if (is(T == string))
		return x;
	else
		return x.to!string;
}

// Position in a YAML stream, used for error messages.
struct Mark {
	import std.algorithm;

@safe pure nothrow:
	/// Construct a Mark with specified line and column in the file.
	this(uint line, uint column) @nogc {
		line_ = cast(ushort)min(ushort.max, line);
		// This *will* overflow on extremely wide files but saves CPU time
		// (mark ctor takes ~5% of time)
		column_ = cast(ushort)column;
	}

	/// Get a string representation of the mark.
	string toString() const {
		// Line/column numbers start at zero internally, make them start at 1.
		static string clamped(ushort v) => text(v + 1, v == ushort.max ? " or higher" : "");

		return "line " ~ clamped(line_) ~ ",column " ~ clamped(column_);
	}

package:
	/// Line number.
	ushort line_;
	/// Column number.
	ushort column_;
}

package:

auto strhash(string s) {
	hash_t hash;
	foreach (char c; s)
		hash = (hash << 5) + c;
	return hash;
}

@safe pure nothrow @nogc:
// dfmt off

/// Convert a YAML escape to a dchar.
dchar fromEscape(dchar escape) {
	switch(escape)
	{
	case '0':  return '\0';
	case 'a':  return '\x07';
	case 'b':  return '\x08';
	case 't':
	case '\t': return '\x09';
	case 'n':  return '\x0A';
	case 'v':  return '\x0B';
	case 'f':  return '\x0C';
	case 'r':  return '\x0D';
	case 'e':  return '\x1B';
	case ' ':
	case '"':
	case '\\': return escape;
	case 'N':  return '\x85';
	case '_':  return '\xA0';
	case 'L':  return '\u2028';
	case 'P':  return '\u2029';
	default:   return '\uFFFF';
	}
}

/// Get the length of a hexadecimal number determined by its hex code.
///
/// Need a function as associative arrays don't work with @nogc.
/// (And this may be even faster with a function.)
auto escapeHexLength(dchar hexCode)
{
	switch(hexCode)
	{
	case 'x': return 2;
	case 'u': return 4;
	case 'U': return 8;
	default: return 0;
	}
}
