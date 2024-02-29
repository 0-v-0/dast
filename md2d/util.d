/++
	Utility functions for string processing
	Modified from https://github.com/dlang-community/dmarkdown/blob/master/source/dmarkdown/string.d
+/
module md2d.util;

import std.range,
std.string;
import std.algorithm : canFind;
public import std.conv : to;
public import tame.uri : asSlug;

@safe pure:
/++
	Checks if all characters in 'str' are contained in 'chars'.
 +/
bool allOf(S)(S str, S chars) {
	foreach (ch; str)
		if (!chars.canFind(ch))
			return false;
	return true;
}

/++
	Checks if any character in 'str' is contained in 'chars'.
 +/
bool anyOf(S)(S str, S chars) {
	foreach (ch; str)
		if (chars.canFind(ch))
			return true;
	return false;
}

/++
	Finds the closing bracket (works with any of '[', '$(LPAREN)', '<', '{').

	Params:
		str = input string
		nested = whether to skip nested brackets
	Returns:
		The index of the closing bracket or -1 for unbalanced strings
		and strings that don't start with a bracket.
+/
ptrdiff_t matchBracket(string str, bool nested = true) nothrow {
	if (str.length < 2)
		return -1;

	// dfmt off
	char open = str[0], close = void;
	switch (str[0]) {
		case '[': close = ']'; break;
		case '(': close = ')'; break;
		case '<': close = '>'; break;
		case '{': close = '}'; break;
		default: return -1;
	}
// dfmt on

	size_t level = 1;
	foreach (i, c; str[1 .. $]) {
		if (nested && c == open)
			++level;
		else if (c == close)
			--level;
		if (level == 0)
			return i + 1;
	}
	return -1;
}

bool isLineBlank(S)(S ln) => allOf(ln, " \t");

pure @safe:
@nogc {
	bool isLineIndented(S)(S ln) => ln.startsWith('\t') || ln.startsWith("    ");

	string unindentLine(S)(S ln) {
		if (ln.startsWith('\t'))
			return ln[1 .. $];
		if (ln.startsWith("    "))
			return ln[4 .. $];
		return ln;
	}

	bool isAtxHeaderLine(S)(S ln) {
		ln = ln.stripLeft;
		size_t i = 0;
		while (i < ln.length && ln[i] == '#')
			i++;
		if (i < 1 || i > 6 || i >= ln.length)
			return false;
		return ln[i] == ' ';
	}
}

bool isSetextHeaderLine(S)(S ln, char subHeaderChar) {
	ln = ln.stripLeft;
	if (ln.length < 1)
		return false;
	if (ln[0] == '=') {
		while (!ln.empty && ln.front == '=')
			ln.popFront();
		return allOf(ln, " \t");
	}
	if (ln[0] == subHeaderChar) {
		while (!ln.empty && ln.front == subHeaderChar)
			ln.popFront();
		return allOf(ln, " \t");
	}
	return false;
}

bool isHlineLine(S)(S ln) =>
	(allOf(ln, " -") && count(ln, '-') >= 3) ||
	(allOf(ln, " *") && count(ln, '*') >= 3) ||
	(allOf(ln, " _") && count(ln, '_') >= 3);

bool isQuoteLine(S)(S ln) => ln.stripLeft().startsWith(">");

size_t getQuoteLevel(S)(S ln) {
	size_t level;
	ln = stripLeft(ln);
	while (ln.length > 0 && ln[0] == '>') {
		level++;
		ln = stripLeft(ln[1 .. $]);
	}
	return level;
}

bool isUListLine(S)(S ln) {
	ln = ln.stripLeft;
	if (ln.length < 2)
		return false;
	if (!"*+-".canFind(ln[0]))
		return false;
	if (ln[1] != ' ' && ln[1] != '\t')
		return false;
	return true;
}

bool isOListLine(S)(S ln) {
	ln = ln.stripLeft;
	if (!ln.length || ln[0] < '0' || ln[0] > '9')
		return false;
	ln = ln[1 .. $];
	while (ln.length && ln[0] >= '0' && ln[0] <= '9')
		ln = ln[1 .. $];
	if (ln.length < 2)
		return false;
	if (ln[0] != '.')
		return false;
	if (ln[1] != ' ' && ln[1] != '\t')
		return false;
	return true;
}

bool isTableRowLine(bool proper = false)(string ln) {
	static if (proper)
		return ln.indexOf(" | ") >= 0
			&& !ln.isOListLine
			&& !ln.isUListLine
			&& !ln.isAtxHeaderLine;
	else
		return ln.indexOf(" | ") >= 0;
}

bool isCodeBlockDelimiter(S)(S ln) => ln.startsWith("```");
