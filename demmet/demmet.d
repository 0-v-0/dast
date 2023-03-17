/* demmet - D implemention of emmet */
module demmet;

import std.algorithm : canFind;

// dfmt off
import
	std.array,
	std.format,
	std.regex,
	std.string,
	std.traits;

alias
	Map = string[string],
	TagProcFunc = bool function(ref TagProp prop),
	StyleProcFunc = string function(string buffer, string tag, ref string[] attr, ref string[] result);

struct TagProp {
	string tag;
	string[] list;
	string[] attr;
	string content;
	string[] result;
}

TagProcFunc[] tagProcs = [&fabbr];

private:
int toInt(string str) {
	import core.stdc.stdio;

	int result;
	sscanf(str.toStringz, "%d", &result);
	return result;
}

T pop(T)(ref T[] arr) {
	if (!arr.length)
		return T.init;
	T back = arr[$-1];
	arr.popBack();
	return back;
}

enum {
	// default elements
	itags = [
		"audio":"source",
		"colgroup":"col",
		"datalist":"option",
		"details":"summary",
		"dl":"dt",
		"em":"span",
		"fieldset":"legend",
		"figure":"figcaption",
		"frameset":"frame",
		"html":"body",
		"input":"input",
		"label":"input",
		"map":"area",
		"menu":"menuitem",
		"menuitem":"menuitem",
		"ul":"li",
		"ol":"li",
		"picture":"img",
		"optgroup":"option",
		"select":"option",
		"table":"tr",
		"tbody":"tr",
		"thead":"tr",
		"tfoot":"tr",
		"tr":"td",
		"video":"source",
	],
	// tagname abbreviations
	tabbr = [
		"!":"!DOCTYPE html",
		"ab":"abbr",
		"adr":"address",
		"ar":"area",
		"arti":"article",
		"asd":"aside",
		"bq":"blockquote",
		"btn":"button",
		"colg":"colgroup",
		"cap":"caption",
		"cmd":"command",
		"cv":"canvas",
		"dat":"data",
		"datg":"datagrid", "datag":"datagrid",
		"datl":"datalist", "datal":"datalist",
		"det":"details",
		"dlg":"dialog",
		"emb":"embed",
		"fig":"figure",
		"figc":"figcaption",
		"fm":"form",
		"fset":"fieldset",
		"ftr":"footer",
		"hdr":"header",
		"ifr":"iframe",
		"inp":"input",
		"lab":"label",
		"leg":"legend",
		"mk":"mark",
		"obj":"object",
		"opt":"option",
		"optg":"optgroup",
		"out":"output",
		"pic":"picture",
		"pr":"pre",
		"prog":"progress",
		"scr":"script",
		"sect":"section",
		"sel":"select",
		"sm":"samp",
		"summ":"summary",
		"sp":"span",
		"src":"source",
		"str":"strong",
		"sty":"style",
		"tab":"table",
		"tbd":"tbody",
		"tem":"template",
		"tft":"tfoot",
		"thd":"thead",
		"tpl":"template",
		"trk":"track",
		"txa":"textarea",
		"vid":"video",
		"wb":"wbr"
	],
	// attribute abbreviations
	aabbr = [
		"a":"alt",
		"ak":"accesskey",
		"autocap":"autocapitalize",
		"ce":"contenteditable",
		"d":"dir",
		"dr":"draggable",
		"dz":"dropzone",
		"n":"name",
		"h":"height",
		"hid":"hidden",
		"im":"inputmode",
		"l":"lang",
		"s":"style",
		"sc":"spellcheck",
		"t":"type",
		"tt":"title",
		"ti":"tabindex",
		"v":"value",
		"w":"width"
	],
	// extended attributes
	eabbr = [
		"css":` rel="stylesheet"`,
		"print":` rel="stylesheet" media="print"`,
		"favicon":` rel="shortcut icon" type="image/x-icon" href="favicon.ico"`,
		"touch":` rel="apple-touch-icon"`,
		"rss":` rel="alternate" type="application/rss+xml" title="RSS"`,
		"atom":` rel="alternate" type="application/atom+xml" title="Atom"`,
		"import":` rel="import"`,
		"d":` disabled="disabled"`,
		"hidden":` type="hidden"`,
		"search":` type="search"`,
		"email":` type="email"`,
		"url":` type="url"`,
		"pwd":` type="password"`,
		"date":` type="date"`,
		"dateloc":` type="datetime-local"`,
		"tel":` type="tel"`,
		"number":` type="number"`,
		"checkbox":` type="checkbox"`,
		"radio":` type="radio"`,
		"range":` type="range"`,
		"file":` type="file"`,
		"submit":` type="submit"`,
		"img":` type="image"`,
		"button":` type="button"`,
		"btn":` type="button"`,
	]
}
// dfmt on

public:

// two fns for counting single line nest tokens (.a>.b^.c)
int countChar(in string input, char c) nothrow {
	int t;
	for (size_t n; n < input.length; n++)
		if (input[n] == c)
			t++;
	return t;
}

int countTokens(string str, char c) {
	enum {
		re1 = ctRegex!(`[^\\]?".+?[^\\]"`),
		re2 = ctRegex!(`[^\\]?'.+?[^\\]'`),
		re3 = ctRegex!(`[^\\]?\{.+?[^\\]\}`)
	}
	return str.replaceAll(re1, "").replaceAll(re2, "").replaceAll(re3, "").countChar(c);
}

int getTabLevel(string e, string indent = "") {
	int i;
	if (indent.length)
		e = e.replace(indent, "\t");
	while (i < e.length && e[i] == '\t')
		i++;
	return i;
}

// make `^>+` out of tabs (normally emmet does nesting like ".a>.b" and unnesting like ".b^.a_sibling", now we can use tabs)
string extractTabs(string input, string indent = "") {
	int r = -1, l;
	auto res = appender!(char[]);
	for (size_t i; i < input.length;) {
		size_t j = i;
		loop: do {
			switch (input[i++]) {
			case '\n':
				if (!l)
					break loop;
				break;
			case '{':
				if (l >= 0)
					l++;
				break;
			case '[':
				if (l < 1)
					l--;
				break;
			case '}':
				if (l > 0)
					l--;
				break;
			case ']':
				if (l < 0)
					l++;
				goto default;
			default:
				break;
			}
		}
		while (i < input.length);
		auto line = input[j .. i];
		int level = getTabLevel(line, indent);
		auto str = line.strip();
		const s = str;
		if (str.length) {
			if (r >= 0) {
				if (level > r || str[0] == '*')
					str = '>' ~ str;
				else if (level == r)
					str = '+' ~ str;
				else if (level < r)
					str = "^".replicate(r - level) ~ str;
			}
			r = level + countTokens(s, '>') - countTokens(s, '^');
		}
		res ~= str;
	}
	return cast(string)res[];
}

unittest {
	auto str = extractTabs(
		`ul
	.
span`);
	assert(str == "ul>.^span", str);
	str = extractTabs(
		`pre{
	.
}`);
	assert(str == `pre{
	.
}`, str);
}

string emmet(S)(S input, S indent = "", StyleProcFunc styleProc = null)
if (isSomeString!S) {
	if (indent.length)
		input = extractTabs(input, indent);
	if (!styleProc)
		styleProc = &defProc;
	return zencode(input, styleProc);
}

private string zencode(S)(S input, StyleProcFunc styleProc) if (isSomeString!S) {
	static string closeTag(string tag) {
		enum noCloseTags = ctRegex!(
				`^!|^(area|base|br|col|embed|frame|hr|img|input|link|meta|param|source|wbr)\b`, "i");
		if (tag.length && !tag.matchFirst(noCloseTags)) {
			return "</" ~ tag ~ ">";
		}
		return "";
	}

	enum xmlComment = ctRegex!(`<!--[\S\s]*?-->`);

	input = input.replaceAll(xmlComment, "");
	auto s = appender!(string[]);
	string[] taglist, lastgroup, result;
	size_t[2][] grouplist;
	size_t i, len = input.length, g, n;
	int l;
	for (; i < len; i++) {
		const c = input[i];
		switch (c) {
		case '{':
			if (l >= 0)
				l++;
			break;
		case '[':
			if (l < 1)
				l--;
			break;
		case '+':
		case '>':
		case '^':
		case '(':
		case ')':
			if (!l) {
				if (g < n)
					s ~= input[g .. n];
				g = n + 1;
				if (c != '>')
					s ~= input[i .. i + 1];
			}
			break;

		case '*':
			if (g < n && !l) {
				s ~= input[g .. n];
				g = n;
			}
			break;

		case '}':
			if (l > 0)
				l--;
			if (!l && g < n) {
				s ~= input[g .. n + 1];
				g = n + 1;
			}
			break;

		case ']':
			if (l < 0)
				l++;
			break;
		default:
			if (!l && i > 0 && input[i - 1] == '}')
				s ~= "+";
			break;
		}
		n++;
	}
	if (g < len)
		s ~= input[g .. len];
	foreach (set; s[]) {
		string lasttag;
		string[] attr = [""];
		size_t[2] prevg = void;
		enum {
			re1 = ctRegex!(`(\$+)@(-?)(\d*)`),
			re2 = ctRegex!(`\{[\s\S]+\}|\[[\s\S]+?\]|(?:\.|#)?[^\[.#{\s]+(?:(?<=\$)\{[^\}]+\})?`),
			re3 = ctRegex!(`(?:!|\s)[\S\s]*`)
		}
		switch (set[0]) {
		case '^':
			if (result.length) {
				lasttag = result[$ - 1];
				if (lasttag.length < 2 || lasttag[0 .. 2] != "</")
					result ~= closeTag(taglist.pop());
			}
			result ~= closeTag(taglist.pop());
			break;
		case '>':
			break;
		case '+':
			if (result.length) {
				lasttag = result[$ - 1];
				if (lasttag.length < 2 || lasttag[0 .. 2] != "</")
					result ~= closeTag(taglist.pop());
			}
			break;
		case '(':
			grouplist ~= [result.length, taglist.length];
			break;
		case ')':
			prevg = grouplist[$ - 1];
			len = prevg[1];
			for (g = taglist.length; g-- > len;)
				result ~= closeTag(taglist.pop());
			lastgroup = result[prevg[0] .. $];
			break;
		default:
			if (set[0] == '*') {
				string[] tags;
				g = toInt(cast(string)set[1 .. $]);
				if (lastgroup.length) {
					tags = lastgroup;
					result.length = grouplist.pop()[0];
				} else if (result.length) {
					tags ~= result.pop();
					tags ~= closeTag(taglist.pop());
				}
				for (n = 0; n < g; n++)
					foreach (r; tags) {
						result ~= r.replaceAll!((Captures!string c) {
							import std.conv : text;

							string digs = c[1],
							direction = c[2],
							start = c[3];
							int st;
							if (start.length)
								st = start.toInt;
							auto v = text((direction.length ? -n : n) + (st ? st
								: direction.length ? g - 1 : 0));
							for (int d = 0, dlen = cast(int)digs.length - cast(int)v.length;
							d < dlen; d++)
								v = '0' ~ v;
							return v;
						})(re1);
					}
			} else {
				import std.ascii : isWhite;

				string buf = void, tag, content;
				lastgroup.length = 0;
				for (;;) {
					auto t = set.matchFirst(re2);
					if (!t)
						break;
					buf = t[0];
					set = t.post;
					switch (buf[0]) {
					case '.':
						attr[0] ~= buf[1 .. $] ~ ' ';
						break;
					case '#':
						attr ~= `id="` ~ buf[1 .. $] ~ '"';
						break;
					case '[':

						buf = buf[0 .. $ - 1];
						string str;
						for (i = 1; i < buf.length;) {
							size_t j = i;
							do
								if (buf[i] == '=' || buf[i].isWhite)
									break;
							while (++i < buf.length);
							auto key = buf[j .. i];
							str ~= aabbr.get(key, key);
							if (i == buf.length)
								break;
							if (buf[i] == '=') {
								str ~= '=';
								j = ++i;
								for (; i < buf.length; i++)
									if (buf[i].isWhite)
										break;
								auto val = buf[j .. i];
								str ~= j == buf.length || (buf[j] != '"' && buf[j] != '\'') ? '"' ~ val ~ '"'
									: val;
							}
							if (i == buf.length)
								break;
							i++;
							str ~= ' ';
						}
						attr ~= str;
						break;
					case '{':
						content = buf[1 .. $ - 1];
						break;
					default:
						tag = styleProc(buf, tag, attr, result);
					}
				}
				buf = attr[0];
				if (buf.length)
					attr[0] = ` class="` ~ buf.stripRight() ~ '"';
				if (!content.length || tag.length || buf.length || attr.length > 1) {
					auto prop = TagProp(tag, taglist, attr, content, result);
					foreach (tagProc; tagProcs) {
						if (tagProc(prop))
							break;
					}
					tag = prop.tag;
					attr = prop.attr;
					if (tag.length) {
						result ~= "<%r%(%r %)>%r".format(tag, attr, prop.content);
						taglist ~= tag.replaceAll(re3, "");
					}
				} else {
					result ~= content;
					taglist ~= "";
				}
			}
		}
	}
	for (i = taglist.length; i--;)
		result ~= closeTag(taglist[i]);
	return result.join("");
}

bool fabbr(ref TagProp prop) {
	enum RE = ctRegex!(`[\s>][\S\s]*`);

	auto tag = prop.tag;
	auto list = prop.list;
	auto result = prop.result;
	auto s = tag.split(':');
	string t;
	string* p = void;
	if (s.length) {
		tag = s[0];
		if (tag.length) {
			t = tag.toLower;
			p = t in tabbr;
			while (p && (t = tag.replace(t, *p)) != tag)
				p = (tag = t) in tabbr;
		}
	}
	if (!tag.length) {
		if (list.length)
			tag = list[$ - 1];
		if (tag.length)
			tag = itags.get(tag.toLower, "");
		if (!tag.length) {
			if (result.length)
				tag = result[$ - 1];
			if (tag.length)
				tag = itags.get(tag[1 .. $].replaceFirst(RE, "").toLower, "");
			if (!tag.length)
				tag = "div";
		}
	}
	t = "";
	if (s.length > 1) {
		p = s[1] in eabbr;
		if (p)
			t = *p;
	}
	prop.tag = tag ~ t;
	return false;
}

private string defProc(string buffer, string, ref string[], ref string[]) {
	return buffer;
}

unittest {
	void test(string a, string b) {
		auto str = emmet(a, "\t");
		assert(str == b, a ~ ": " ~ str);
	}

	test("", "");
	test("ul>.>a", "<ul><li><a></a></li></ul>");
	test(`[href=#]a`, `<a href="#"></a>`);
	test(`b[href=#]a`, `<a href="#"></a>`);
	test(`[href=#]b a`, `<a href="#"></a>`);
	test(`a(b)`, `<a><b></b></a>`);
	test(`* single line commet`, ``);
	test(`*{ commet } a(b)`, `<a><b></b></a>`);
	test(`a(b)(a comment)*`, `<a><b></b></a>`);
	test(`a
	{x}
	b{y}
		i{z}
	{0}`, "<a>x<b>y<i>z</i></b>0</a>");
	test(`a[data-a={]{foo{1}}b{bar{2}`, `<a data-a="{">foo{1}</a><b>bar{2</b>`);
	test(`[href=#t$@]a*1 b+s+a*0`, `<a href="#t0"></a><s></s>`);
	test("a[hid]", `<a hidden></a>`);
	test("a[hid=]", `<a hidden=""></a>`);
	test(`a[hid=""]`, `<a hidden=""></a>`);
	test(`pre{
	.
}`, `<pre>
	.
</pre>`);
	test(`a[s="color: red"]`, `<a style="color: red"></a>`);
	test(`ul
	.
span`, "<ul><li></li></ul><span></span>");
	test(
		`!
html
	.
		table
			.
				th{$@3}*3
			(#l_$@
				td{$@-5}*3)*2`, `<!DOCTYPE html><html><body><table><tr><th>3</th><th>4</th><th>5</th></tr><tr id="l_0"><td>5</td><td>4</td><td>3</td></tr><tr id="l_1"><td>5</td><td>4</td><td>3</td></tr></table></body></html>`
	);
	test("{$foo $bar{$baz}", "$foo $bar{$baz");
	test(`{$cond? [}
	a
{]}b`, "$cond? [<a></a>]<b></b>");
	test(
		`{$cond? [}
	a
{] : [}
	b
{]}.`,
		"$cond? [<a></a>] : [<b></b>]<div></div>");
	test(
		`{$map:key val[}
	{$key=$value}
{]}`, "$map:key val[$key=$value]");
	test("{${filename}}b", "${filename}<b></b>");
}
