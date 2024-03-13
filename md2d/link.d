module md2d.link;

import md2d.util,
std.array,
std.ascii,
std.string;

struct LinkRef {
	string id, url, title;
}

struct Link {
	string text, url, title;
}

@safe:

bool parseLink(ref string str, ref Link dst, in LinkRef[string] linkrefs) pure {
	string pstr = str;
	if (pstr.length < 3)
		return false;
	// ignore img-link prefix
	if (pstr[0] == '!')
		pstr = pstr[1 .. $];

	// parse the text part [text]
	if (pstr[0] != '[')
		return false;
	auto cidx = pstr.matchBracket();
	if (cidx < 1)
		return false;
	string refid;
	dst.text = pstr[1 .. cidx];
	pstr = pstr[cidx + 1 .. $];

	// parse either (link '['"title"']') or '[' ']'[refid]
	if (pstr.length < 2)
		return false;
	if (pstr[0] == '(') {
		cidx = pstr.matchBracket();
		if (cidx < 1)
			return false;
		auto inner = pstr[1 .. cidx];
		immutable qidx = inner.indexOf('"');
		if (qidx > 1 && inner[qidx - 1].isWhite) {
			dst.url = inner[0 .. qidx].stripRight();
			immutable len = inner[qidx .. $].lastIndexOf('"');
			if (len == 0)
				return false;
			assert(len > 0);
			dst.title = inner[qidx + 1 .. qidx + len];
		} else {
			dst.url = inner.stripRight();
			dst.title = null;
		}
		if (dst.url.startsWith('<') && dst.url.endsWith('>'))
			dst.url = dst.url[1 .. $ - 1];
		pstr = pstr[cidx + 1 .. $];
	} else {
		if (pstr[0] == ' ')
			pstr = pstr[1 .. $];
		if (pstr[0] != '[')
			return false;
		pstr = pstr[1 .. $];
		cidx = pstr.indexOf(']');
		if (cidx < 0)
			return false;
		if (cidx == 0)
			refid = dst.text;
		else
			refid = pstr[0 .. cidx];
		pstr = pstr[cidx + 1 .. $];
	}

	if (refid.length) {
		auto pr = refid.toLower in linkrefs;
		if (!pr) {
			// debug if (!__ctfe) logDebug("[LINK REF NOT FOUND: '%s'", refid);
			return false;
		}
		dst.url = pr.url;
		dst.title = pr.title;
	}

	str = pstr;
	return true;
}

unittest {
	void testLink(string s, Link exp, in LinkRef[string] refs) {
		Link link;
		assert(parseLink(s, link, refs), s);
		assert(link == exp);
	}

	LinkRef[string] refs;
	refs["ref"] = LinkRef("ref", "target", "title");

	testLink(`[link](target)`, Link("link", "target"), null);
	testLink(`[link](target "title")`, Link("link", "target", "title"), null);
	testLink(`[link](target  "title")`, Link("link", "target", "title"), null);
	testLink(`[link](target "title" )`, Link("link", "target", "title"), null);

	testLink(`[link](target)`, Link("link", "target"), null);
	testLink(`[link](target "title")`, Link("link", "target", "title"), null);

	testLink(`[link][ref]`, Link("link", "target", "title"), refs);
	testLink(`[ref][]`, Link("ref", "target", "title"), refs);

	testLink(`[link[with brackets]](target)`, Link("link[with brackets]", "target"), null);
	testLink(`[link[with brackets]][ref]`, Link("link[with brackets]", "target", "title"), refs);

	testLink(`[link](/target with spaces)`, Link("link", "/target with spaces"), null);
	testLink(`[link](/target with spaces "title")`, Link("link", "/target with spaces", "title"), null);

	testLink(`[link](white-space  "around title")`, Link("link", "white-space", "around title"), null);
	testLink(`[link](tabs	"around title"	)`, Link("link", "tabs", "around title"), null);

	testLink(`[link](target "")`, Link("link", "target", ""), null);
	testLink(`[link](target-no-title"foo")`, Link("link", "target-no-title\"foo\"", ""), null);

	testLink(`[link](<target>)`, Link("link", "target"), null);

	auto failing = [
		`text`, `[link](target`, `[link]target)`, `[link]`,
		`[link(target)`, `link](target)`, `[link] (target)`,
		`[link][noref]`, `[noref][]`
	];
	Link link;
	foreach (s; failing)
		assert(!parseLink(s, link, refs), s);
}

bool parseAutoLink(ref string str, ref string url) pure {
	string pstr = str;
	if (pstr.length < 3 || pstr[0] != '<')
		return false;
	pstr = pstr[1 .. $];
	auto cidx = pstr.indexOf('>');
	if (cidx < 0)
		return false;
	url = pstr[0 .. cidx];
	if (anyOf(url, " \t") || !anyOf(url, ":@"))
		return false;
	str = pstr[cidx + 1 .. $];
	if (url.indexOf('@') > 0)
		url = "mailto:" ~ url;
	return true;
}

LinkRef[string] scanForReferences(ref string[] lines) pure {
	LinkRef[string] ret;
	bool[size_t] reflines;

	// search for reference definitions:
	//	[refid] link "opt text"
	//	[refid] <link> "opt text"
	//	"opt text", 'opt text', (opt text)
	//	line must not be indented
	foreach (lnidx, ln; lines) {
		if (isLineIndented(ln))
			continue;
		ln = ln.strip;
		if (!ln.startsWith('['))
			continue;
		ln = ln[1 .. $];

		auto idx = ln.indexOf("]:");
		if (idx < 0)
			continue;
		string refid = ln[0 .. idx];
		ln = stripLeft(ln[idx + 2 .. $]);

		string url;
		if (ln.startsWith('<')) {
			idx = ln.indexOf('>');
			if (idx < 0)
				continue;
			url = ln[1 .. idx];
			ln = ln[idx + 1 .. $];
		} else {
			idx = ln.indexOf(' ');
			if (idx > 0) {
				url = ln[0 .. idx];
				ln = ln[idx + 1 .. $];
			} else {
				idx = ln.indexOf('\t');
				if (idx < 0) {
					url = ln;
					ln = ln[$ .. $];
				} else {
					url = ln[0 .. idx];
					ln = ln[idx + 1 .. $];
				}
			}
		}
		ln = stripLeft(ln);

		string title;
		if (ln.length >= 3) {
			if (ln[0] == '(' && ln[$ - 1] == ')' ||
				ln[0] == '\"' && ln[$ - 1] == '\"' ||
				ln[0] == '\'' && ln[$ - 1] == '\'')
				title = ln[1 .. $ - 1];
		}

		ret[refid.toLower] = LinkRef(refid, url, title);
		reflines[lnidx] = true;

		// debug if (!__ctfe) logTrace("[detected ref on line %d]", lnidx+1);
	}

	// remove all lines containing references
	auto nonreflines = appender!(string[]);
	nonreflines.reserve(lines.length);
	foreach (i, ln; lines)
		if (i !in reflines)
			nonreflines ~= ln;
	lines = nonreflines[];

	return ret;
}
